import Darwin
import Foundation
import XCTest
@testable import i3wm_osx

final class SingleInstanceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("i3wm-osx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSecondInstanceCannotAcquireLock() throws {
        let path = temporaryDirectory.appendingPathComponent("instance.lock").path
        var first: SingleInstanceLock? = try SingleInstanceLock.acquire(at: path)

        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: path)) { error in
            guard case SingleInstanceLockError.alreadyRunning(let pid) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(pid, getpid())
        }

        first = nil
        XCTAssertNoThrow(try SingleInstanceLock.acquire(at: path))
    }

    func testLockDoesNotLeakIntoChildProcesses() throws {
        let path = temporaryDirectory.appendingPathComponent("instance.lock").path
        let lock = try SingleInstanceLock.acquire(at: path)

        XCTAssertNotEqual(fcntl(lock.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testInheritedLockIsAdoptedAndMadeCloseOnExec() throws {
        let path = temporaryDirectory.appendingPathComponent("instance.lock").path
        let original = try SingleInstanceLock.acquire(at: path)
        let inheritedFileDescriptor = dup(original.fileDescriptor)
        XCTAssertGreaterThanOrEqual(inheritedFileDescriptor, 0)

        let adopted = try SingleInstanceLock.acquire(
            at: path,
            inheriting: inheritedFileDescriptor
        )

        XCTAssertNotEqual(fcntl(adopted.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: path))
    }

    func testRestartArgumentsReplaceInternalState() {
        let arguments = restartArguments(
            currentArguments: [
                "/path/i3wm-osx",
                "-c",
                "/tmp/config",
                "--restore-state",
                "/tmp/old-state",
                "--instance-lock-fd",
                "7",
            ],
            restoreStatePath: "/tmp/new-state",
            inheritedLockFileDescriptor: 11
        )

        XCTAssertEqual(arguments, [
            "-c",
            "/tmp/config",
            "--restore-state",
            "/tmp/new-state",
            "--instance-lock-fd",
            "11",
        ])
    }
}
