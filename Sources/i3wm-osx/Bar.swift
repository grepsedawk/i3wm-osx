import AppKit
import CoreFoundation
import Foundation

private struct PangoFont {
    var family: String?
    var size: CGFloat = 13
    var traits: NSFontTraitMask = []
    var weight: Int = 5
}

private func parsePangoFont(_ raw: String?) -> PangoFont {
    var out = PangoFont()
    guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return out }
    if s.lowercased().hasPrefix("pango:") { s = String(s.dropFirst("pango:".count)).trimmingCharacters(in: .whitespaces) }
    if let spaceIdx = s.lastIndex(of: " ") {
        let tail = s[s.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
        if let n = Double(tail) {
            out.size = CGFloat(n)
            s = s[..<spaceIdx].trimmingCharacters(in: .whitespaces)
        }
    }
    var parts = s.split(separator: " ").map(String.init)
    while let last = parts.last?.lowercased() {
        switch last {
        case "italic", "oblique": out.traits.insert(.italicFontMask); parts.removeLast()
        case "bold": out.traits.insert(.boldFontMask); out.weight = 9; parts.removeLast()
        case "ultralight", "thin": out.weight = 2; parts.removeLast()
        case "light": out.weight = 3; parts.removeLast()
        case "medium": out.weight = 6; parts.removeLast()
        case "semibold": out.weight = 8; parts.removeLast()
        case "heavy", "black": out.weight = 10; parts.removeLast()
        case "condensed": out.traits.insert(.condensedFontMask); parts.removeLast()
        case "expanded": out.traits.insert(.expandedFontMask); parts.removeLast()
        default: out.family = parts.joined(separator: " "); return out
        }
    }
    return out
}

func barFont(for cfg: I3Config) -> NSFont {
    let p = parsePangoFont(cfg.bar.font)
    if let f = p.family, !f.isEmpty {
        if let nf = resolveFamilyMember(family: f, traits: p.traits, weight: p.weight, size: p.size) {
            return nf
        }
        if let nf = NSFontManager.shared.font(withFamily: f, traits: p.traits, weight: p.weight, size: p.size) {
            return nf
        }
        if let nf = NSFont(name: f, size: p.size) { return nf }
    }
    return NSFont.monospacedSystemFont(ofSize: p.size, weight: .regular)
}

private func resolveFamilyMember(family: String, traits: NSFontTraitMask, weight: Int, size: CGFloat) -> NSFont? {
    guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
    struct Member { let name: String; let weight: Int; let traits: UInt }
    let parsed: [Member] = members.compactMap { m in
        guard m.count >= 4,
              let name = m[0] as? String,
              let w = m[2] as? Int,
              let t = m[3] as? UInt else { return nil }
        // Skip the ambiguous bare-family PostScript name (e.g. "MonoLisa") —
        // when two TTFs export the same PostScript name, NSFont(name:) returns
        // whichever was registered first, often the italic file.
        if name.caseInsensitiveCompare(family) == .orderedSame { return nil }
        return Member(name: name, weight: w, traits: t)
    }
    let wantItalic = traits.contains(.italicFontMask)
    let wantBold = traits.contains(.boldFontMask)
    let italicMask: UInt = 1
    let boldMask: UInt = 2
    let matchingItalic = parsed.filter { (($0.traits & italicMask) != 0) == wantItalic }
    let pool = matchingItalic.isEmpty ? parsed : matchingItalic
    let boldFiltered = pool.filter { (($0.traits & boldMask) != 0) == wantBold }
    let finalPool = boldFiltered.isEmpty ? pool : boldFiltered
    let best = finalPool.min { abs($0.weight - weight) < abs($1.weight - weight) }
    guard let pick = best else { return nil }
    return NSFont(name: pick.name, size: size)
}

private func parseHexColor(_ s: String?) -> NSColor? {
    guard let s = s else { return nil }
    var v = s
    if v.hasPrefix("#") { v.removeFirst() }
    guard v.count == 6 || v.count == 8, let n = UInt32(v, radix: 16) else { return nil }
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

private func hex(_ s: String?, fallback: NSColor) -> NSColor {
    parseHexColor(s) ?? fallback
}

final class BarController {
    private(set) var windows: [BarWindow] = []
    weak var manager: WindowManager?
    var config: I3Config = I3Config()
    private var statusFeed: StatusFeed?
    private(set) var statusBlocks: [StatusBlock] = []
    private var hidden = false

    /// Hide the bar while an i3-fullscreen window is up so the window covers
    /// its strip instead of a tile sliding under it. (Native macOS fullscreen
    /// is handled by the bar not joining all Spaces — see BarWindow.init.)
    func setHidden(_ hidden: Bool) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden
        for w in windows {
            if hidden { w.orderOut(nil) } else { w.orderFront(nil) }
        }
    }

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
            if !hidden { w.orderFront(nil) }
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

struct StatusTextRun {
    var text: String
    var color: NSColor?
}

struct StatusBlock {
    static let legacySeparatorPadding: CGFloat = 16

    var text: String
    var color: NSColor?
    var markup: String?
    var separator: Bool
    var separatorBlockWidth: CGFloat?
    private(set) var textRuns: [StatusTextRun]

    init(
        text: String,
        color: NSColor?,
        markup: String? = nil,
        separator: Bool = true,
        separatorBlockWidth: CGFloat? = nil
    ) {
        self.text = text
        self.color = color
        self.markup = markup
        self.separator = separator
        self.separatorBlockWidth = separatorBlockWidth
        self.textRuns = markup == "pango"
            ? PangoMarkupParser.parse(text) ?? [StatusTextRun(text: text, color: nil)]
            : [StatusTextRun(text: text, color: nil)]
    }

    func boundaryWidth(separatorGlyphWidth: CGFloat) -> CGFloat {
        separatorBlockWidth ?? separatorGlyphWidth + Self.legacySeparatorPadding
    }

    func attributedText(font: NSFont, defaultColor: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: "")
        let blockColor = color ?? defaultColor
        for run in textRuns {
            attributed.append(NSAttributedString(
                string: run.text,
                attributes: [
                    .font: font,
                    .foregroundColor: run.color ?? blockColor,
                ]
            ))
        }
        return attributed
    }
}

private final class PangoMarkupParser: NSObject, XMLParserDelegate {
    private var runs: [StatusTextRun] = []
    private var colors: [NSColor?] = []
    private var valid = true

    static func parse(_ markup: String) -> [StatusTextRun]? {
        guard let data = "<status>\(markup)</status>".data(using: .utf8) else { return nil }
        let delegate = PangoMarkupParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.valid, delegate.colors.isEmpty else { return nil }
        return delegate.runs
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "status" {
            guard colors.isEmpty else {
                valid = false
                parser.abortParsing()
                return
            }
            colors.append(nil)
            return
        }
        guard elementName == "span", !colors.isEmpty else {
            valid = false
            parser.abortParsing()
            return
        }
        let inherited = colors.last ?? nil
        let rawColor = attributeDict["foreground"] ?? attributeDict["color"]
        let explicit = parseHexColor(rawColor)
        if rawColor != nil, explicit == nil {
            valid = false
            parser.abortParsing()
            return
        }
        colors.append(explicit ?? inherited)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !colors.isEmpty else {
            valid = false
            parser.abortParsing()
            return
        }
        colors.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            valid = false
            parser.abortParsing()
            return
        }
        append(string)
    }

    private func append(_ string: String) {
        guard !string.isEmpty, !colors.isEmpty else { return }
        let color = colors.last ?? nil
        if let last = runs.indices.last, runs[last].color == color {
            runs[last].text += string
        } else {
            runs.append(StatusTextRun(text: string, color: color))
        }
    }
}

struct StatusRenderItem: Equatable {
    var blockIndex: Int
    var boundaryOwnerIndex: Int?
}

struct StatusLayoutItem: Equatable {
    var blockIndex: Int
    var textX: CGFloat
    var boundaryOwnerIndex: Int?
    var separatorX: CGFloat?
}

func statusRenderOrder(blockCount: Int) -> [StatusRenderItem] {
    guard blockCount > 0 else { return [] }
    return (0..<blockCount).reversed().map { index in
        StatusRenderItem(
            blockIndex: index,
            boundaryOwnerIndex: index > 0 ? index - 1 : nil
        )
    }
}

func statusLayout(
    blocks: [StatusBlock],
    textWidths: [CGFloat],
    separatorGlyphWidth: CGFloat,
    rightEdge: CGFloat
) -> [StatusLayoutItem] {
    guard blocks.count == textWidths.count else { return [] }
    var x = rightEdge
    return statusRenderOrder(blockCount: blocks.count).map { renderItem in
        x -= textWidths[renderItem.blockIndex]
        let textX = x
        var separatorX: CGFloat?
        if let ownerIndex = renderItem.boundaryOwnerIndex {
            let owner = blocks[ownerIndex]
            let boundaryWidth = owner.boundaryWidth(separatorGlyphWidth: separatorGlyphWidth)
            x -= boundaryWidth
            if owner.separator {
                separatorX = x + (boundaryWidth - separatorGlyphWidth) / 2
            }
        }
        return StatusLayoutItem(
            blockIndex: renderItem.blockIndex,
            textX: textX,
            boundaryOwnerIndex: renderItem.boundaryOwnerIndex,
            separatorX: separatorX
        )
    }
}

func parseStatusBlocks(_ jsonText: String) -> [StatusBlock]? {
    guard let data = jsonText.data(using: .utf8),
          let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return nil
    }
    return items.map { item in
        let text = item["full_text"] as? String ?? ""
        let color = (item["color"] as? String).flatMap(parseHexColor)
        let markup = item["markup"] as? String
        let separator = item["separator"] as? Bool ?? true
        let separatorBlockWidth: CGFloat?
        if let number = item["separator_block_width"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            separatorBlockWidth = max(0, CGFloat(truncating: number))
        } else {
            separatorBlockWidth = nil
        }
        return StatusBlock(
            text: text,
            color: color,
            markup: markup,
            separator: separator,
            separatorBlockWidth: separatorBlockWidth
        )
    }
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
            guard let blocks = parseStatusBlocks(jsonText) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onUpdate(blocks) }
        }
    }
}

final class BarWindow: NSPanel {
    let view: BarView
    weak var screenRef: NSScreen?
    weak var controller: BarController?
    static let defaultHeight: CGFloat = 28

    static func height(for cfg: I3Config) -> CGFloat {
        let f = barFont(for: cfg)
        return max(defaultHeight, ceil(f.ascender - f.descender + f.leading) + 10)
    }

    init(screen: NSScreen, controller: BarController) {
        let visible = screen.visibleFrame
        let atBottom = controller.config.bar.position == "bottom"
        let h = BarWindow.height(for: controller.config)
        let barY = atBottom ? visible.minY : visible.maxY - h
        let barFrame = NSRect(x: visible.minX, y: barY, width: visible.width, height: h)
        self.view = BarView(frame: NSRect(origin: .zero, size: barFrame.size))
        self.screenRef = screen
        self.controller = controller
        super.init(contentRect: barFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.level = .statusBar
        // Deliberately NOT .canJoinAllSpaces: that flag forces the bar onto
        // every Space including the separate Space macOS creates for a
        // native-fullscreen window, where it would float over the window's
        // edge. Bound to its own Space, the bar stays on the i3 workspace
        // (the only Space we ever use) and fullscreen windows cover it.
        self.collectionBehavior = [.stationary, .ignoresCycle]
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

        let font = barFont(for: cfg)

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
        let separatorColor = hex(cfg.bar.colors.separator, fallback: NSColor(srgbRed: 0xA0/255.0, green: 0xA4/255.0, blue: 0xB8/255.0, alpha: 1.0))
        let blocks = ctrl.statusBlocks.filter { !$0.text.isEmpty }
        let texts = blocks.map { $0.attributedText(font: font, defaultColor: statusColor) }
        let sizes = texts.map { $0.size() }
        let sep = "|" as NSString
        let sepAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: separatorColor]
        let separatorSize = sep.size(withAttributes: sepAttrs)
        let layout = statusLayout(
            blocks: blocks,
            textWidths: sizes.map(\.width),
            separatorGlyphWidth: separatorSize.width,
            rightEdge: bounds.width - 8
        )
        for item in layout {
            let text = texts[item.blockIndex]
            let size = sizes[item.blockIndex]
            text.draw(at: NSPoint(x: item.textX, y: (h - size.height) / 2 - 1))
            if let separatorX = item.separatorX {
                sep.draw(
                    at: NSPoint(x: separatorX, y: (h - separatorSize.height) / 2 - 1),
                    withAttributes: sepAttrs
                )
            }
        }
        _ = screenFrame
    }
}
