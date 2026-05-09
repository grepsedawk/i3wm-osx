import AppKit
import ApplicationServices
import Foundation

final class ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID
    var appName: String
    var title: String
    var lastKnownFrame: CGRect = .zero
    var isFloating: Bool = false
    var savedFloatingFrame: CGRect?
    var fullscreen: Bool = false
    var minimizedByUs: Bool = false
    var hiddenByUs: Bool = false

    init(element: AXUIElement, pid: pid_t, id: CGWindowID, appName: String, title: String) {
        self.element = element
        self.pid = pid
        self.id = id
        self.appName = appName
        self.title = title
    }

    func refreshTitle() {
        if let t = AX.title(element) { title = t }
    }

    @discardableResult
    func apply(frame: CGRect) -> Bool {
        lastKnownFrame = frame
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
                guard isManageable(w) else { continue }
                let id = AX.windowID(w) ?? 0
                results.append((app.processIdentifier, w, id))
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
