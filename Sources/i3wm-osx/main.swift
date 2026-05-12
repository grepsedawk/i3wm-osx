import AppKit
import Foundation

let args = ProcessInfo.processInfo.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    i3wm-osx - tiling window manager for macOS

    USAGE:
      i3wm-osx                  start the window manager
      i3wm-osx -c <path>        load config from path
      i3wm-osx --check          parse config and exit
      i3wm-osx --version

    Default config search order:
      1. -c <path>
      2. $XDG_CONFIG_HOME/i3wm-osx/config (or ~/.config/i3wm-osx/config)
      3. ~/.i3wm-osx/config

    The config syntax is i3-compatible but the file is intentionally separate
    from your Linux i3 config — modifier defaults and available commands
    differ. Start from examples/config-macos.

    """)
    exit(0)
}

if args.contains("--version") {
    print("i3wm-osx 0.2.0")
    exit(0)
}

let configPath: String = {
    if let i = args.firstIndex(of: "-c"), i + 1 < args.count { return args[i + 1] }
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let xdg = env["XDG_CONFIG_HOME"].map { $0.isEmpty ? "\(home)/.config" : $0 } ?? "\(home)/.config"
    let candidates = [
        "\(xdg)/i3wm-osx/config",
        "\(home)/.i3wm-osx/config",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
}()

if args.contains("--check") {
    do {
        let raw = try String(contentsOfFile: configPath, encoding: .utf8)
        let cfg = try I3Config.parse(raw)
        print("OK: \(cfg.bindings.count) bindings, \(cfg.modes.count) modes, \(cfg.execs.count) execs, \(cfg.forWindow.count) for_window rules")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
        exit(1)
    }
}

let restoreStatePath: String? = {
    if let i = args.firstIndex(of: "--restore-state"), i + 1 < args.count { return args[i + 1] }
    return nil
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let coordinator = I3App(configPath: configPath, restoreStatePath: restoreStatePath)
coordinator.start()
app.run()
