import Foundation

enum MsgType: UInt32 {
    case runCommand = 0
    case getWorkspaces = 1
    case subscribe = 2
    case getOutputs = 3
    case getTree = 4
    case getMarks = 5
    case getBarConfig = 6
    case getVersion = 7
    case getBindingModes = 8
    case getConfig = 9
    case sendTick = 10
}

let magic = "i3-ipc"

func socketPath() -> String {
    if let env = ProcessInfo.processInfo.environment["I3SOCK"], !env.isEmpty { return env }
    return "/tmp/i3wm-osx-\(NSUserName()).sock"
}

func send(type: MsgType, payload: String) -> (UInt32, Data)? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath()
    let pathBytes = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in pathBytes.enumerated() where i < 104 { dst[i] = b }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, len)
        }
    }
    guard connectResult == 0 else {
        FileHandle.standardError.write(Data("could not connect to i3wm-osx at \(path) (is it running?)\n".utf8))
        return nil
    }

    var header = Data()
    header.append(contentsOf: magic.utf8)
    var payloadLen = UInt32(payload.utf8.count).littleEndian
    var typeRaw = type.rawValue.littleEndian
    withUnsafeBytes(of: &payloadLen) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: &typeRaw) { header.append(contentsOf: $0) }
    var allData = header
    allData.append(contentsOf: payload.utf8)
    _ = allData.withUnsafeBytes { write(fd, $0.baseAddress, allData.count) }

    var hdr = [UInt8](repeating: 0, count: 14)
    var got = 0
    while got < 14 {
        let n = read(fd, &hdr[got], 14 - got)
        if n <= 0 { return nil }
        got += n
    }
    let lo = UInt32(hdr[6]) | UInt32(hdr[7]) << 8 | UInt32(hdr[8]) << 16 | UInt32(hdr[9]) << 24
    let tp = UInt32(hdr[10]) | UInt32(hdr[11]) << 8 | UInt32(hdr[12]) << 16 | UInt32(hdr[13]) << 24
    var body = Data(count: Int(lo))
    var off = 0
    body.withUnsafeMutableBytes { rawBuf in
        guard let base = rawBuf.baseAddress else { return }
        while off < Int(lo) {
            let n = read(fd, base.advanced(by: off), Int(lo) - off)
            if n <= 0 { break }
            off += n
        }
    }
    return (tp, body)
}

let args = ProcessInfo.processInfo.arguments
var msgType: MsgType = .runCommand
var payload = ""
var i = 1
while i < args.count {
    switch args[i] {
    case "-t":
        i += 1
        if i < args.count {
            switch args[i] {
            case "command", "run_command": msgType = .runCommand
            case "get_workspaces": msgType = .getWorkspaces
            case "get_outputs": msgType = .getOutputs
            case "get_tree": msgType = .getTree
            case "get_version": msgType = .getVersion
            case "get_binding_modes": msgType = .getBindingModes
            case "get_config": msgType = .getConfig
            default:
                FileHandle.standardError.write(Data("unknown type: \(args[i])\n".utf8))
                exit(2)
            }
        }
    default:
        if !payload.isEmpty { payload += " " }
        payload += args[i]
    }
    i += 1
}

guard let (_, body) = send(type: msgType, payload: payload) else { exit(1) }
if let s = String(data: body, encoding: .utf8) { print(s) }
