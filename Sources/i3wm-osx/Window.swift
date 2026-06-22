import AppKit
import ApplicationServices
import Foundation

final class ManagedWindow {
    // Gecko (Firefox/Zen) re-asserts its own remembered window geometry once,
    // shortly after a window opens — so a one-shot re-tile is scheduled for
    // these. Keyed by bundle id since localized app names vary.
    static let geometryQuirkBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "app.zen-browser.zen-twilight",
    ]

    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID
    let bundleID: String?
    var appName: String
    var title: String
    var lastKnownFrame: CGRect = .zero
    var isFloating: Bool = false
    var savedFloatingFrame: CGRect?
    var fullscreen: Bool = false
    var minimizedByUs: Bool = false
    var hiddenByUs: Bool = false

    // Stamped whenever the WM itself moves the window. Mouse-driven snap-back
    // ignores AX moved/resized events inside this window so our own apply() —
    // and an app's immediate min-size bounce-back to it — don't feed back.
    var suppressSnapBackUntil: TimeInterval = 0
    static let snapBackSuppression: TimeInterval = 0.4

    var hasGeometryQuirk: Bool {
        guard let bundleID else { return false }
        return ManagedWindow.geometryQuirkBundleIDs.contains(bundleID)
    }

    init(element: AXUIElement, pid: pid_t, id: CGWindowID, appName: String, title: String, bundleID: String?) {
        self.element = element
        self.pid = pid
        self.id = id
        self.appName = appName
        self.title = title
        self.bundleID = bundleID
    }

    func refreshTitle() {
        if let t = AX.title(element) { title = t }
    }

    @discardableResult
    func apply(frame: CGRect) -> Bool {
        lastKnownFrame = frame
        suppressSnapBackUntil = Date().timeIntervalSince1970 + Self.snapBackSuppression
        return AX.setFrame(element, frame)
    }

    func focus() {
        AX.raise(element)
        AX.setMain(element)
        AX.setFocused(element)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
    }

    func close() {
        AX.close(element)
    }
}

enum WindowDiscovery {
    static func enumerateAll() -> [(pid: pid_t, element: AXUIElement, id: CGWindowID)] {
        var results: [(pid_t, AXUIElement, CGWindowID)] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            if app.processIdentifier == selfPID { continue }
            let appElem = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows: [AXUIElement] = AX.attribute(appElem, kAXWindowsAttribute) else { continue }
            for w in windows {
                if isManageable(w) {
                    let id = AX.windowID(w) ?? 0
                    results.append((app.processIdentifier, w, id))
                } else {
                    // DIAGNOSTIC (temporary): why was a real-looking window not adopted
                    // at scan? Logs the AX fields isManageable gates on so an orphan
                    // (e.g. a Zen window stuck unmanaged) can be explained directly.
                    let role = AX.role(w) ?? "nil"
                    let sub = AX.subrole(w) ?? "nil"
                    let szStr = AX.size(w).map { "\(Int($0.width))×\(Int($0.height))" } ?? "nil"
                    Logger.info("scan reject: [\(app.localizedName ?? "?")] role=\(role) sub=\(sub) size=\(szStr) min=\(AX.isMinimized(w))")
                }
            }
        }
        return results
    }

    static func isManageable(_ element: AXUIElement) -> Bool {
        if AX.isMinimized(element) { return false }
        let role = AX.role(element)
        guard role == kAXWindowRole else { return false }
        // Brave/Chromium adopt-time check passes a normal-looking
        // AXStandardWindow, then silently mutates it: subrole disappears,
        // size collapses to 0×0 (e.g. inactive Private-mode tabs).
        // Re-check size first so post-mutation windows fail this gate even
        // if they were managed at adoption time.
        guard let size = AX.size(element), size.width > 50, size.height > 50 else { return false }
        if let sub = AX.subrole(element) {
            return sub == kAXStandardWindowSubrole
        }
        return true
    }
}
