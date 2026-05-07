import AppKit
import Foundation

final class I3App {
    let configPath: String
    var config: I3Config = I3Config()
    let manager: WindowManager
    let hotkeys: HotkeyManager
    let ipc: IPCServer
    let bar: BarController

    init(configPath: String) {
        self.configPath = configPath
        self.manager = WindowManager()
        self.hotkeys = HotkeyManager()
        self.ipc = IPCServer()
        self.bar = BarController()
    }

    private var trustWatcher: DispatchSourceTimer?
    private var lastTrust: Bool = false

    func start() {
        Logger.info("starting i3wm-osx pid=\(getpid()), config: \(configPath)")
        Logger.info("bundle path: \(Bundle.main.bundlePath)")
        Logger.info("running from: \(ProcessInfo.processInfo.arguments[0])")
        let trusted = AX.ensureTrusted(prompt: true)
        lastTrust = trusted
        Logger.info("Accessibility trust: \(trusted ? "GRANTED" : "DENIED")")
        if !trusted {
            Logger.warn("Accessibility permission not granted — System Settings > Privacy & Security > Accessibility. We will retry automatically once granted.")
        }
        loadConfig()
        Logger.info("screens: \(NSScreen.screens.count) — \(NSScreen.screens.map { $0.localizedName }.joined(separator: ", "))")
        manager.bind(config: config, bar: bar)
        manager.bootstrap()
        Logger.info("bootstrap complete — outputs=\(manager.outputs.count) windows=\(manager.windowsByID.count) workspaces=\(manager.ledger.workspaces.count)")
        hotkeys.bind(commandHandler: { [weak self] cmd in self?.run(commandText: cmd) })
        hotkeys.apply(config: config)
        hotkeys.start()
        Logger.info("hotkey tap: \(hotkeys.isInstalled ? "INSTALLED" : "FAILED (need Input Monitoring permission)")")
        bar.bind(config: config, manager: manager)
        bar.start()
        Logger.info("bar windows: \(bar.windows.count)")
        ipc.bind(commandHandler: { [weak self] cmd in self?.run(commandText: cmd) ?? "[]" }, manager: manager, config: { [weak self] in self?.config ?? I3Config() })
        ipc.start()
        runStartupExecs(once: true)
        runStartupExecs(once: false)
        startTrustWatcher()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.manager.handleAppLaunched(app)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.manager.handleAppTerminated(app)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.manager.handleAppActivated(app)
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.manager.handleSpaceChanged()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.manager.handleScreensChanged()
            self?.bar.handleScreensChanged()
        }
    }

    func loadConfig() {
        do {
            config = try I3Config.load(path: configPath)
            Logger.info("loaded \(config.bindings.count) bindings, \(config.modes.count) modes")
        } catch {
            Logger.warn("config load failed: \(error). Using empty config.")
            config = I3Config()
        }
    }

    func reload() {
        loadConfig()
        manager.bind(config: config, bar: bar)
        hotkeys.apply(config: config)
        bar.bind(config: config, manager: manager)
        bar.refresh()
    }

    private func startTrustWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if now && !self.lastTrust {
                Logger.info("Accessibility trust GAINED — re-bootstrapping window manager")
                self.lastTrust = true
                self.manager.bootstrap()
                Logger.info("re-bootstrap done — windows=\(self.manager.windowsByID.count)")
                if !self.hotkeys.isInstalled {
                    self.hotkeys.start()
                    Logger.info("hotkey tap retry: \(self.hotkeys.isInstalled ? "INSTALLED" : "still failing — grant Input Monitoring too")")
                }
            } else if !now && self.lastTrust {
                Logger.warn("Accessibility trust LOST")
                self.lastTrust = false
            }
        }
        timer.resume()
        trustWatcher = timer
    }

    func runStartupExecs(once: Bool) {
        for e in config.execs where e.once == once {
            I3App.shell(e.command)
        }
    }

    @discardableResult
    func run(commandText: String) -> String {
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.info("cmd: \(trimmed)")
        let cmds = CommandParser.parse(commandText)
        var results: [[String: Any]] = []
        for c in cmds {
            let ok = CommandExecutor.execute(c, app: self)
            results.append(["success": ok])
        }
        if let json = try? JSONSerialization.data(withJSONObject: results) {
            return String(data: json, encoding: .utf8) ?? "[]"
        }
        return "[]"
    }

    static func shell(_ command: String) {
        Logger.info("exec: \(command)")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        do { try task.run() } catch { Logger.warn("exec failed: \(error)") }
    }
}

func shell(_ command: String) { I3App.shell(command) }

enum Logger {
    static let prefix = "[i3wm-osx]"
    static let logPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/i3wm-osx.log"
    }()
    static let fileHandle: FileHandle? = {
        let path = logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        try? h?.seekToEnd()
        return h
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: String, _ s: String) {
        let line = "\(timeFormatter.string(from: Date())) \(prefix) \(level)\(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? fileHandle?.write(contentsOf: Data(line.utf8))
    }

    static func info(_ s: String) { emit("", s) }
    static func warn(_ s: String) { emit("WARN ", s) }
    static func debug(_ s: String) {
        if ProcessInfo.processInfo.environment["I3WM_OSX_DEBUG"] != nil { emit("DBG ", s) }
    }
}
