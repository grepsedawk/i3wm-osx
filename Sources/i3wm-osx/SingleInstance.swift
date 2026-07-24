import Darwin
import Foundation

enum SingleInstanceLockError: Error, CustomStringConvertible {
    case alreadyRunning(pid: pid_t?)
    case invalidInheritedLock(path: String)
    case systemCall(operation: String, path: String?, code: Int32)

    var description: String {
        switch self {
        case .alreadyRunning(let pid):
            if let pid {
                return "another i3wm-osx instance is already running (pid \(pid))"
            }
            return "another i3wm-osx instance is already running"
        case .invalidInheritedLock(let path):
            return "inherited instance lock does not match \(path)"
        case .systemCall(let operation, let path, let code):
            let target = path.map { " \($0)" } ?? ""
            return "\(operation)\(target) failed: \(String(cString: strerror(code)))"
        }
    }
}

final class SingleInstanceLock {
    let fileDescriptor: Int32
    let path: String

    private init(fileDescriptor: Int32, path: String) {
        self.fileDescriptor = fileDescriptor
        self.path = path
    }

    deinit {
        close(fileDescriptor)
    }

    static func acquire(at path: String? = nil, inheriting fileDescriptor: Int32? = nil) throws -> SingleInstanceLock {
        let lockPath = try path ?? defaultPath()

        if let fileDescriptor {
            var inheritedStatus = stat()
            guard fstat(fileDescriptor, &inheritedStatus) == 0 else {
                throw SingleInstanceLockError.systemCall(
                    operation: "adopt instance lock",
                    path: lockPath,
                    code: errno
                )
            }
            var lockPathStatus = stat()
            guard
                stat(lockPath, &lockPathStatus) == 0,
                inheritedStatus.st_dev == lockPathStatus.st_dev,
                inheritedStatus.st_ino == lockPathStatus.st_ino
            else {
                throw SingleInstanceLockError.invalidInheritedLock(path: lockPath)
            }
            guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw SingleInstanceLockError.systemCall(
                    operation: "adopt instance lock",
                    path: lockPath,
                    code: errno
                )
            }
            try setCloseOnExec(true, for: fileDescriptor, path: lockPath)
            return SingleInstanceLock(fileDescriptor: fileDescriptor, path: lockPath)
        }

        let fileDescriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw SingleInstanceLockError.systemCall(
                operation: "open instance lock",
                path: lockPath,
                code: errno
            )
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            if code == EWOULDBLOCK {
                throw SingleInstanceLockError.alreadyRunning(pid: ownerPID(at: lockPath))
            }
            throw SingleInstanceLockError.systemCall(
                operation: "lock instance",
                path: lockPath,
                code: code
            )
        }

        let pidLine = "\(getpid())\n"
        guard ftruncate(fileDescriptor, 0) == 0 else {
            let code = errno
            close(fileDescriptor)
            throw SingleInstanceLockError.systemCall(
                operation: "truncate instance lock",
                path: lockPath,
                code: code
            )
        }
        let bytesWritten = pidLine.withCString {
            write(fileDescriptor, $0, strlen($0))
        }
        guard bytesWritten == pidLine.utf8.count else {
            let code = bytesWritten < 0 ? errno : EIO
            close(fileDescriptor)
            throw SingleInstanceLockError.systemCall(
                operation: "write instance lock owner",
                path: lockPath,
                code: code
            )
        }

        return SingleInstanceLock(fileDescriptor: fileDescriptor, path: lockPath)
    }

    func prepareForExec() throws {
        try Self.setCloseOnExec(false, for: fileDescriptor, path: path)
    }

    func cancelExec() {
        try? Self.setCloseOnExec(true, for: fileDescriptor, path: path)
    }

    private static func defaultPath() throws -> String {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("i3wm-osx", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("instance.lock").path
    }

    private static func setCloseOnExec(_ enabled: Bool, for fileDescriptor: Int32, path: String) throws {
        let flags = fcntl(fileDescriptor, F_GETFD)
        guard flags >= 0 else {
            throw SingleInstanceLockError.systemCall(
                operation: "read instance lock flags",
                path: path,
                code: errno
            )
        }

        let updatedFlags = enabled ? flags | FD_CLOEXEC : flags & ~FD_CLOEXEC
        guard fcntl(fileDescriptor, F_SETFD, updatedFlags) == 0 else {
            throw SingleInstanceLockError.systemCall(
                operation: "write instance lock flags",
                path: path,
                code: errno
            )
        }
    }

    private static func ownerPID(at path: String) -> pid_t? {
        guard
            let raw = try? String(contentsOfFile: path, encoding: .utf8),
            let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }
}
