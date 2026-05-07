import Foundation
import AppKit

final class IPCServer {
    private var listenerFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var commandHandler: ((String) -> String)?
    private weak var manager: WindowManager?
    private var configProvider: (() -> I3Config)?
    private static let magic = "i3-ipc"

    func bind(commandHandler: @escaping (String) -> String, manager: WindowManager, config: @escaping () -> I3Config) {
        self.commandHandler = commandHandler
        self.manager = manager
        self.configProvider = config
    }

    var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["I3SOCK"], !env.isEmpty { return env }
        return "/tmp/i3wm-osx-\(NSUserName()).sock"
    }

    func start() {
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Logger.warn("IPC socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in pathBytes.enumerated() where i < 104 { dst[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard ok == 0 else {
            Logger.warn("IPC bind() failed: \(String(cString: strerror(errno)))")
            close(fd); return
        }
        guard listen(fd, 8) == 0 else {
            Logger.warn("IPC listen() failed"); close(fd); return
        }
        listenerFD = fd
        let q = DispatchQueue(label: "i3wm-osx.ipc")
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var caddr = sockaddr_un()
            var clen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(self.listenerFD, sa, &clen)
                }
            }
            if cfd >= 0 { self.handleClient(cfd) }
        }
        src.resume()
        self.source = src
        Logger.info("IPC listening on \(path)")
    }

    private func handleClient(_ fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { close(fd) }
            guard let self else { return }
            while true {
                guard let (type, payload) = self.readMessage(fd) else { return }
                let reply = self.dispatch(type: type, payload: payload)
                self.writeMessage(fd, type: type, payload: reply)
            }
        }
    }

    private func readMessage(_ fd: Int32) -> (UInt32, Data)? {
        var hdr = [UInt8](repeating: 0, count: 14)
        var got = 0
        while got < 14 {
            let n = read(fd, &hdr[got], 14 - got)
            if n <= 0 { return nil }
            got += n
        }
        let magic = String(bytes: hdr.prefix(6), encoding: .utf8) ?? ""
        guard magic == IPCServer.magic else { return nil }
        let len = UInt32(hdr[6]) | UInt32(hdr[7]) << 8 | UInt32(hdr[8]) << 16 | UInt32(hdr[9]) << 24
        let tp = UInt32(hdr[10]) | UInt32(hdr[11]) << 8 | UInt32(hdr[12]) << 16 | UInt32(hdr[13]) << 24
        var body = Data(count: Int(len))
        if len > 0 {
            var off = 0
            body.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                while off < Int(len) {
                    let n = read(fd, base.advanced(by: off), Int(len) - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        return (tp, body)
    }

    private func writeMessage(_ fd: Int32, type: UInt32, payload: String) {
        var data = Data()
        data.append(contentsOf: IPCServer.magic.utf8)
        var len = UInt32(payload.utf8.count).littleEndian
        var tp = type.littleEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &tp) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    private func dispatch(type: UInt32, payload: Data) -> String {
        let body = String(data: payload, encoding: .utf8) ?? ""
        switch type {
        case 0:
            return DispatchQueue.main.sync {
                commandHandler?(body) ?? "[]"
            }
        case 1:
            return DispatchQueue.main.sync { workspacesJSON() }
        case 3:
            return DispatchQueue.main.sync { outputsJSON() }
        case 4:
            return DispatchQueue.main.sync { treeJSON() }
        case 5:
            return "[]"
        case 7:
            return versionJSON()
        case 8:
            return DispatchQueue.main.sync { bindingModesJSON() }
        case 9:
            return DispatchQueue.main.sync { configJSON() }
        default:
            return "{}"
        }
    }

    private func workspacesJSON() -> String {
        guard let mgr = manager else { return "[]" }
        var arr: [[String: Any]] = []
        for ws in mgr.ledger.workspaces {
            let visible = ws.output?.activeWorkspace === ws
            let focused = mgr.ledger.current === ws
            let r = ws.output?.frame ?? .zero
            arr.append([
                "num": ws.number ?? -1,
                "name": ws.name,
                "visible": visible,
                "focused": focused,
                "rect": ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height],
                "output": ws.output?.name ?? "",
                "urgent": false,
            ])
        }
        return jsonString(arr)
    }

    private func outputsJSON() -> String {
        guard let mgr = manager else { return "[]" }
        var arr: [[String: Any]] = []
        for out in mgr.outputs {
            let r = out.frame
            arr.append([
                "name": out.name,
                "active": true,
                "primary": out.id == 1,
                "rect": ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height],
                "current_workspace": out.activeWorkspace?.name ?? NSNull(),
            ])
        }
        return jsonString(arr)
    }

    private func treeJSON() -> String {
        guard let mgr = manager else { return "{}" }
        let root: [String: Any] = [
            "id": 1,
            "type": "root",
            "name": "root",
            "layout": "splith",
            "nodes": mgr.outputs.map { encodeOutput($0) },
        ]
        return jsonString(root)
    }

    private func encodeOutput(_ out: Output) -> [String: Any] {
        let r = out.frame
        return [
            "id": out.id,
            "type": "output",
            "name": out.name,
            "rect": ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height],
            "nodes": out.workspaces.map { encodeWorkspace($0) },
        ]
    }

    private func encodeWorkspace(_ ws: Workspace) -> [String: Any] {
        return [
            "id": ws.tree.id,
            "type": "workspace",
            "name": ws.name,
            "num": ws.number ?? -1,
            "layout": ws.tree.layout.rawValue,
            "nodes": ws.tree.children.map { encodeContainer($0) },
        ]
    }

    private func encodeContainer(_ c: Container) -> [String: Any] {
        var dict: [String: Any] = [
            "id": c.id,
            "layout": c.layout.rawValue,
            "rect": ["x": c.rect.minX, "y": c.rect.minY, "width": c.rect.width, "height": c.rect.height],
        ]
        if let w = c.window {
            dict["type"] = "con"
            dict["name"] = w.title
            dict["window_class"] = w.appName
            dict["window"] = Int(w.id)
        } else {
            dict["type"] = "con"
            dict["nodes"] = c.children.map { encodeContainer($0) }
        }
        return dict
    }

    private func versionJSON() -> String {
        return jsonString([
            "major": 0, "minor": 1, "patch": 0,
            "human_readable": "i3wm-osx 0.1.0",
            "loaded_config_file_name": configProvider?().sourcePath ?? "",
        ])
    }

    private func bindingModesJSON() -> String {
        guard let cfg = configProvider?() else { return "[\"default\"]" }
        var modes = ["default"]
        modes.append(contentsOf: cfg.modes.map { $0.name })
        return jsonString(modes)
    }

    private func configJSON() -> String {
        guard let cfg = configProvider?() else { return "{}" }
        return jsonString(["config": cfg.rawText])
    }

    private func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
