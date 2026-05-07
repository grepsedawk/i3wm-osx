import AppKit
import Foundation

private func hex(_ s: String?, fallback: NSColor) -> NSColor {
    guard let s = s else { return fallback }
    var v = s
    if v.hasPrefix("#") { v.removeFirst() }
    guard let n = UInt32(v, radix: 16) else { return fallback }
    let r, g, b, a: CGFloat
    if v.count == 8 {
        r = CGFloat((n >> 24) & 0xff) / 255
        g = CGFloat((n >> 16) & 0xff) / 255
        b = CGFloat((n >>  8) & 0xff) / 255
        a = CGFloat( n        & 0xff) / 255
    } else {
        r = CGFloat((n >> 16) & 0xff) / 255
        g = CGFloat((n >>  8) & 0xff) / 255
        b = CGFloat( n        & 0xff) / 255
        a = 1.0
    }
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

final class BarController {
    private(set) var windows: [BarWindow] = []
    weak var manager: WindowManager?
    var config: I3Config = I3Config()
    private var statusFeed: StatusFeed?
    private(set) var statusBlocks: [StatusBlock] = []

    func bind(config: I3Config, manager: WindowManager) {
        self.config = config
        self.manager = manager
        startStatusFeed()
    }

    func start() {
        rebuildWindows()
    }

    func handleScreensChanged() {
        rebuildWindows()
    }

    func rebuildWindows() {
        for w in windows { w.close() }
        windows = []
        for screen in NSScreen.screens {
            let w = BarWindow(screen: screen, controller: self)
            windows.append(w)
            w.orderFront(nil)
        }
        refresh()
    }

    func refresh() {
        for w in windows { w.refresh() }
    }

    private func startStatusFeed() {
        statusFeed?.stop()
        guard let cmd = config.bar.statusCommand, !cmd.isEmpty else { return }
        let feed = StatusFeed(command: cmd) { [weak self] blocks in
            self?.statusBlocks = blocks
            self?.refresh()
        }
        feed.start()
        statusFeed = feed
    }
}

struct StatusBlock {
    var text: String
    var color: NSColor?
}

final class StatusFeed {
    let command: String
    let onUpdate: ([StatusBlock]) -> Void
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()

    init(command: String, onUpdate: @escaping ([StatusBlock]) -> Void) {
        self.command = command
        self.onUpdate = onUpdate
    }

    func start() {
        let p = Process()
        p.launchPath = "/bin/sh"
        p.arguments = ["-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.consume(data)
        }
        do {
            try p.run()
        } catch {
            Logger.warn("status_command failed: \(error)")
        }
        self.process = p
        self.pipe = out
    }

    func stop() {
        process?.terminate()
        process = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(0...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("{") { continue }
            var jsonText = trimmed
            if jsonText.hasPrefix(",") { jsonText.removeFirst() }
            if !jsonText.hasPrefix("[") {
                DispatchQueue.main.async { [weak self] in self?.onUpdate([StatusBlock(text: trimmed, color: nil)]) }
                continue
            }
            guard let data = jsonText.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            var blocks: [StatusBlock] = []
            for item in arr {
                let text = item["full_text"] as? String ?? ""
                var color: NSColor?
                if let c = item["color"] as? String { color = hex(c, fallback: .white) }
                blocks.append(StatusBlock(text: text, color: color))
            }
            DispatchQueue.main.async { [weak self] in self?.onUpdate(blocks) }
        }
    }
}

final class BarWindow: NSPanel {
    let view: BarView
    weak var screenRef: NSScreen?
    weak var controller: BarController?
    static let height: CGFloat = 24

    init(screen: NSScreen, controller: BarController) {
        let visible = screen.visibleFrame
        let atBottom = controller.config.bar.position == "bottom"
        let barY = atBottom ? visible.minY : visible.maxY - BarWindow.height
        let barFrame = NSRect(x: visible.minX, y: barY, width: visible.width, height: BarWindow.height)
        self.view = BarView(frame: NSRect(origin: .zero, size: barFrame.size))
        self.screenRef = screen
        self.controller = controller
        super.init(contentRect: barFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.backgroundColor = .clear
        self.hasShadow = false
        self.contentView = view
        view.controller = controller
        view.screenRef = screen
    }

    func refresh() {
        view.needsDisplay = true
    }
}

final class BarView: NSView {
    weak var controller: BarController?
    weak var screenRef: NSScreen?
    private var pillRects: [(NSRect, String)] = []

    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, name) in pillRects where r.contains(p) {
            controller?.manager?.switchWorkspace(name: name)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        pillRects = []
        guard let ctrl = controller else { return }
        let cfg = ctrl.config

        let bg = hex(cfg.bar.colors.background, fallback: NSColor(srgbRed: 0x28/255.0, green: 0x2a/255.0, blue: 0x36/255.0, alpha: 1.0))
        bg.setFill()
        bounds.fill()

        let mgr = ctrl.manager
        let screen = screenRef
        let screenFrame = screen?.frame ?? .zero

        var x: CGFloat = 6
        let y: CGFloat = 0
        let h = bounds.height

        let fontSize: CGFloat = 12
        let font = NSFont(name: "JetBrainsMono Nerd Font", size: fontSize) ?? NSFont.menuFont(ofSize: fontSize)

        let curWS = mgr?.ledger.current
        let activePerOutput: Set<ObjectIdentifier> = Set((mgr?.outputs ?? []).compactMap { $0.activeWorkspace.map { ObjectIdentifier($0) } })

        let workspaces = (mgr?.ledger.workspaces ?? []).filter { ws in
            // Only show workspaces assigned to this output, and only if they
            // have a window OR they're the focused workspace. Empty unfocused
            // workspaces stay accessible via $mod+1..0 but don't clutter.
            guard let out = ws.output, let s = screen else { return true }
            if out.screen !== s { return false }
            let nonEmpty = !ws.tree.collectWindows().isEmpty
            let isFocused = curWS === ws
            return nonEmpty || isFocused
        }

        for ws in workspaces {
            let isFocused = curWS === ws
            let isActive = activePerOutput.contains(ObjectIdentifier(ws))
            let pillColors: [String]
            if isFocused {
                pillColors = cfg.bar.colors.focusedWorkspace.isEmpty
                    ? ["#44475A", "#44475A", "#F8F8F2"]
                    : cfg.bar.colors.focusedWorkspace
            } else if isActive {
                pillColors = cfg.bar.colors.activeWorkspace.isEmpty
                    ? ["#282A36", "#44475A", "#F8F8F2"]
                    : cfg.bar.colors.activeWorkspace
            } else {
                pillColors = cfg.bar.colors.inactiveWorkspace.isEmpty
                    ? ["#282A36", "#282A36", "#BFBFBF"]
                    : cfg.bar.colors.inactiveWorkspace
            }

            let label = ws.name as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: hex(pillColors.count > 2 ? pillColors[2] : "#F8F8F2", fallback: .white),
            ]
            let textSize = label.size(withAttributes: attrs)
            let minWidth = CGFloat(max(cfg.bar.workspaceMinWidth, 25))
            let pillWidth = max(textSize.width + 14, minWidth)
            let rect = NSRect(x: x, y: y + 2, width: pillWidth, height: h - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            hex(pillColors.count > 1 ? pillColors[1] : "#44475A", fallback: .darkGray).setFill()
            path.fill()
            hex(pillColors.first ?? "#44475A", fallback: .darkGray).setStroke()
            path.lineWidth = 1
            path.stroke()
            label.draw(at: NSPoint(x: rect.minX + (rect.width - textSize.width) / 2, y: rect.minY + (rect.height - textSize.height) / 2 - 1), withAttributes: attrs)
            pillRects.append((rect, ws.name))
            x = rect.maxX + 4
        }

        if let m = mgr?.mode, m != "default" {
            let modeText = m as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: hex(cfg.bar.colors.bindingMode.count > 2 ? cfg.bar.colors.bindingMode[2] : "#F8F8F2", fallback: .white),
            ]
            let s = modeText.size(withAttributes: attrs)
            let pad: CGFloat = 8
            let rect = NSRect(x: x, y: y + 2, width: s.width + pad * 2, height: h - 4)
            hex(cfg.bar.colors.bindingMode.count > 1 ? cfg.bar.colors.bindingMode[1] : "#FF5555", fallback: .red).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            modeText.draw(at: NSPoint(x: rect.minX + pad, y: rect.minY + (rect.height - s.height) / 2 - 1), withAttributes: attrs)
            x = rect.maxX + 6
        }

        let statusColor = hex(cfg.bar.colors.statusline, fallback: NSColor(srgbRed: 0xF8/255.0, green: 0xF8/255.0, blue: 0xF2/255.0, alpha: 1.0))
        let blocks = ctrl.statusBlocks
        var rx: CGFloat = bounds.width - 8
        for block in blocks.reversed() {
            let text = block.text as NSString
            if text.length == 0 { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: block.color ?? statusColor,
            ]
            let s = text.size(withAttributes: attrs)
            rx -= s.width
            text.draw(at: NSPoint(x: rx, y: (h - s.height) / 2 - 1), withAttributes: attrs)
            rx -= 12
        }
        _ = screenFrame
    }
}
