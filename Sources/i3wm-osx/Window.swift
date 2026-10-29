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
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
        // Multi-window apps restore their own last-focused sibling when
        // activated. Apply our window choice afterward so that sibling cannot
        // steal focus back from a window on another workspace.
        AX.raise(element)
        AX.setMain(element)
        AX.setFocused(element)
    }

    func close() {
        AX.close(element)
    }
}

struct WindowCandidate {
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect
}

struct DiscoveredWindow {
    let pid: pid_t
    let element: AXUIElement
    let id: CGWindowID
    let title: String
    let subrole: String?
    let frame: CGRect?

    init(pid: pid_t, element: AXUIElement, id: CGWindowID, title: String, subrole: String?, frame: CGRect?) {
        self.pid = pid
        self.element = element
        self.id = id
        self.title = title
        self.subrole = subrole
        self.frame = frame
    }

    init(pid: pid_t, element: AXUIElement, id: CGWindowID) {
        self.init(pid: pid, element: element, id: id, title: AX.title(element) ?? "", subrole: AX.subrole(element), frame: AX.frame(element))
    }
}

enum WindowDiscovery {
    static func enumerateAll(
        excluding knownIDs: Set<CGWindowID> = [],
        candidates: [WindowCandidate]? = nil
    ) -> [DiscoveredWindow] {
        var results: [DiscoveredWindow] = []
        let candidateIDs = candidates.map { Dictionary(grouping: $0, by: \.pid).mapValues { Set($0.map(\.id)) } }
        if let candidates, candidates.isEmpty { return [] }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            if app.processIdentifier == selfPID { continue }
            if candidates != nil && app.isHidden { continue }
            if let candidateIDs, candidateIDs[app.processIdentifier] == nil { continue }
            let appElem = AXUIElementCreateApplication(app.processIdentifier)
            if candidates != nil { AXUIElementSetMessagingTimeout(appElem, 0.2) }
            guard let windows: [AXUIElement] = AX.attribute(appElem, kAXWindowsAttribute) else { continue }
            for w in windows {
                if candidates != nil { AXUIElementSetMessagingTimeout(w, 0.2) }
                guard let id = AX.windowID(w), id != 0, !knownIDs.contains(id) else { continue }
                if let candidateIDs, candidateIDs[app.processIdentifier]?.contains(id) != true { continue }
                if isManageable(w) {
                    results.append(DiscoveredWindow(pid: app.processIdentifier, element: w, id: id))
                } else if candidates == nil && ProcessInfo.processInfo.environment["I3WM_OSX_DEBUG"] != nil {
                    let role = AX.role(w) ?? "nil"
                    let sub = AX.subrole(w) ?? "nil"
                    let szStr = AX.size(w).map { "\(Int($0.width))×\(Int($0.height))" } ?? "nil"
                    Logger.debug("scan reject: [\(app.localizedName ?? "?")] role=\(role) sub=\(sub) size=\(szStr) min=\(AX.isMinimized(w))")
                }
            }
        }
        return results
    }

    static func recoveryCandidates(_ windows: [[String: Any]], excluding knownIDs: Set<CGWindowID>) -> [WindowCandidate] {
        var result: [WindowCandidate] = []
        for window in windows {
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  id != 0, !knownIDs.contains(id),
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid > 0,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 50, frame.height > 50 else { continue }
            result.append(WindowCandidate(pid: pid, id: id, frame: frame))
        }
        return result
    }

    static func isManageable(_ element: AXUIElement) -> Bool {
        let modal: NSNumber? = AX.attribute(element, kAXModalAttribute)
        return isManageable(role: AX.role(element), subrole: AX.subrole(element), size: AX.size(element), minimized: AX.isMinimized(element), modal: modal?.boolValue)
    }

    static func isManageable(role: String?, subrole: String?, size: CGSize?, minimized: Bool, modal: Bool? = nil) -> Bool {
        if minimized { return false }
        guard role == kAXWindowRole else { return false }
        // Brave/Chromium adopt-time check passes a normal-looking
        // AXStandardWindow, then silently mutates it: subrole disappears,
        // size collapses to 0×0 (e.g. inactive Private-mode tabs).
        // Re-check size first so post-mutation windows fail this gate even
        // if they were managed at adoption time.
        guard let size, size.width > 50, size.height > 50 else { return false }
        if let subrole {
            // ChatGPT can expose its main window as AXDialog.
            return subrole == kAXStandardWindowSubrole || (subrole == kAXDialogSubrole && modal == false)
        }
        return true
    }
}
