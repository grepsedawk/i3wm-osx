import AppKit
import ApplicationServices
import Foundation
import CoreGraphics

final class WindowManager {
    var outputs: [Output] = []
    let ledger = WorkspaceLedger()
    var windowsByID: [CGWindowID: ManagedWindow] = [:]
    var containerByWindowID: [CGWindowID: Container] = [:]
    var floatingWindows: Set<CGWindowID> = []
    var fullscreenWindow: CGWindowID?
    var focused: Container?
    var pendingSplit: Orientation = .none
    var mode: String = "default"
    var barInset: CGFloat = 24

    var config: I3Config = I3Config()
    weak var bar: BarController?
    var observers: [pid_t: AXObserver] = [:]
    /// Counter — not a set — because rapid workspace switches can trigger
    /// `setAppHidden(true)` for the same pid multiple times before the AX
    /// notifications drain. A set would coalesce the inserts and we'd
    /// "leak" notifications back into the user-⌘H detection path, which
    /// would relocate the window to a fresh workspace mid-switch and cause
    /// focus-follow to chase its tail.
    var pendingOurHides: [pid_t: Int] = [:]

    /// Wallclock of the last `switchWorkspace`. Used to suppress
    /// focus-follow chases for a brief grace period — when we hide an
    /// inactive workspace's windows via `setAppHidden`, those apps fire
    /// `kAXFocusedWindowChangedNotification` for their *internal* focused
    /// window. Without this, the WM chases the notification right back
    /// to the workspace we just left and the user sees the screen ping-pong.
    private var lastWorkspaceSwitchAt: TimeInterval = 0
    private static let focusFollowGracePeriod: TimeInterval = 0.35

    private var modeStack: [String] = []

    func bind(config: I3Config, bar: BarController) {
        self.config = config
        self.bar = bar
    }

    func bootstrap() {
        rebuildOutputs()
        if Container.nextID < 100 { Container.nextID = 100 }
        let names = (1...10).map(String.init)
        for n in names { _ = ledger.ensure(name: n) }
        if let primary = outputs.first {
            for ws in ledger.workspaces where ws.output == nil {
                ws.output = primary
                if !primary.workspaces.contains(where: { $0 === ws }) {
                    primary.workspaces.append(ws)
                }
            }
            if primary.activeWorkspace == nil { primary.activeWorkspace = ledger.workspaces.first }
            if ledger.current == nil, let first = ledger.workspaces.first { ledger.setCurrent(first) }
        }
        for screen in NSScreen.screens {
            if let out = outputs.first(where: { $0.screen === screen }), out.activeWorkspace == nil {
                if let ws = ledger.workspaces.first(where: { $0.output === out }) {
                    out.activeWorkspace = ws
                }
            }
        }
        scanExistingWindows()
        applyAllLayouts()
        bar?.refresh()
        Logger.info("scanned: \(windowsByID.count) windows across \(outputs.count) output(s)")
    }

    func rebuildOutputs() {
        var newOutputs: [Output] = []
        var nextID = 1
        for screen in NSScreen.screens {
            if let existing = outputs.first(where: { $0.screen === screen }) {
                newOutputs.append(existing)
            } else {
                newOutputs.append(Output(screen: screen, id: nextID))
            }
            nextID += 1
        }
        outputs = newOutputs
    }

    func scanExistingWindows() {
        for entry in WindowDiscovery.enumerateAll() {
            adopt(element: entry.element, pid: entry.pid, id: entry.id)
        }
    }

    @discardableResult
    func adopt(element: AXUIElement, pid: pid_t, id: CGWindowID) -> ManagedWindow? {
        guard id != 0 else { return nil }
        if let existing = windowsByID[id] { return existing }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        let title = AX.title(element) ?? ""
        Logger.info("adopt: [\(appName)] \(title.isEmpty ? "<untitled>" : title) (id=\(id))")
        let mw = ManagedWindow(element: element, pid: pid, id: id, appName: appName, title: title)
        if let frame = currentFrame(element) { mw.lastKnownFrame = frame }
        windowsByID[id] = mw
        if shouldFloat(window: mw) {
            mw.isFloating = true
            mw.savedFloatingFrame = mw.lastKnownFrame
            floatingWindows.insert(id)
        }
        // Always attach a container — even floating windows belong to a
        // workspace's tree. The layout engine ignores floating leaves when
        // tiling but the tree association is what guarantees the "every
        // window lives on exactly one workspace" invariant.
        let leaf = Container(kind: .window(mw))
        let ws = ledger.current ?? ledger.workspaces.first!
        attach(leaf, into: ws.tree)
        containerByWindowID[id] = leaf
        focused = leaf
        ws.tree.bumpFocus(leaf)
        observe(pid: pid, element: element)
        return mw
    }

    func release(id: CGWindowID) {
        guard let mw = windowsByID.removeValue(forKey: id) else { return }
        Logger.info("release: [\(mw.appName)] \(mw.title.isEmpty ? "<untitled>" : mw.title) (id=\(id))")
        floatingWindows.remove(id)
        if fullscreenWindow == id { fullscreenWindow = nil }
        if let c = containerByWindowID.removeValue(forKey: id) {
            removeContainer(c)
            if focused === c { focused = nil }
        }
    }

    private func currentFrame(_ element: AXUIElement) -> CGRect? {
        guard let p = AX.position(element), let s = AX.size(element) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private func shouldFloat(window: ManagedWindow) -> Bool {
        for rule in config.forWindow {
            if matches(window: window, criteria: rule.criteria) {
                let cmd = rule.command.lowercased()
                if cmd.contains("floating enable") || cmd.contains("floating toggle") { return true }
            }
        }
        return false
    }

    func matches(window: ManagedWindow, criteria: [String: String]) -> Bool {
        for (k, v) in criteria {
            switch k {
            case "title":
                if !regexMatch(v, in: window.title) { return false }
            case "class", "instance":
                if !regexMatch(v, in: window.appName) { return false }
            case "app_id":
                if !regexMatch(v, in: window.appName) { return false }
            default: continue
            }
        }
        return true
    }

    private func regexMatch(_ pattern: String, in text: String) -> Bool {
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let r = NSRange(text.startIndex..<text.endIndex, in: text)
            return re.firstMatch(in: text, options: [], range: r) != nil
        }
        return text.localizedCaseInsensitiveContains(pattern)
    }

    func attach(_ leaf: Container, into workspace: Container) {
        if let f = focused, isInWorkspace(f, ws: workspace) {
            insertNearFocus(leaf, near: f)
        } else if let last = workspace.children.last {
            if pendingSplit != .none {
                wrapAndInsert(leaf, near: last, orientation: pendingSplit)
                pendingSplit = .none
            } else {
                workspace.add(leaf)
            }
        } else {
            workspace.add(leaf)
            pendingSplit = .none
        }
    }

    private func isInWorkspace(_ c: Container, ws: Container) -> Bool {
        var cur: Container? = c
        while let x = cur {
            if x === ws { return true }
            cur = x.parent
        }
        return false
    }

    private func insertNearFocus(_ leaf: Container, near focus: Container) {
        if pendingSplit != .none {
            wrapAndInsert(leaf, near: focus, orientation: pendingSplit)
            pendingSplit = .none
            return
        }
        if let parent = focus.parent {
            let idx = (parent.indexOf(focus) ?? -1) + 1
            parent.add(leaf, at: idx)
        }
    }

    private func wrapAndInsert(_ leaf: Container, near focus: Container, orientation: Orientation) {
        guard let parent = focus.parent else { return }
        let parentLayout = Orientation.from(parent.layout)
        if parentLayout == orientation {
            let idx = (parent.indexOf(focus) ?? -1) + 1
            parent.add(leaf, at: idx)
            return
        }
        let split = Container(kind: .split)
        split.layout = orientation == .horizontal ? .splitH : .splitV
        let idx = parent.indexOf(focus) ?? 0
        parent.remove(focus)
        parent.add(split, at: idx)
        split.add(focus)
        split.add(leaf)
    }

    private func removeContainer(_ c: Container) {
        guard let parent = c.parent else { return }
        parent.remove(c)
        collapseIfRedundant(parent)
    }

    private func collapseIfRedundant(_ c: Container) {
        guard case .split = c.kind else { return }

        // Empty split — orphan, just delete it.
        if c.children.isEmpty {
            if let parent = c.parent {
                parent.remove(c)
                collapseIfRedundant(parent)
            }
            return
        }

        // Single-child split — promote the child, inheriting parent's
        // fraction so its slot in the grandparent stays the same size.
        if c.children.count == 1, let parent = c.parent {
            let only = c.children[0]
            let idx = parent.indexOf(c) ?? 0
            only.fraction = c.fraction
            parent.remove(c)
            parent.add(only, at: idx)
            collapseIfRedundant(parent)
            return
        }

        // Same-orientation nested splits flatten:
        //   splitH(a, splitH(b, c), d)  →  splitH(a, b, c, d)
        // Each grandchild absorbs its parent's slot fraction proportionally.
        var i = 0
        while i < c.children.count {
            let child = c.children[i]
            if case .split = child.kind, child.layout == c.layout {
                let inheritedSlot = child.fraction
                let childTotal = child.children.reduce(0.0) { $0 + max($1.fraction, 0) }
                let normTotal = childTotal > 0.0001 ? childTotal : CGFloat(child.children.count)
                let promotedChildren = child.children
                c.remove(child)
                for (j, gc) in promotedChildren.enumerated() {
                    let weight = childTotal > 0.0001 ? gc.fraction : 1.0
                    gc.fraction = inheritedSlot * (weight / normTotal)
                    c.add(gc, at: i + j)
                }
                continue
            }
            i += 1
        }
    }

    func applyAllLayouts() {
        let ctx = LayoutContext(
            innerGap: config.innerGap,
            outerGap: config.outerGap,
            smartGaps: config.smartGaps,
            barInset: barInset,
            barAtBottom: config.bar.position == "bottom"
        )
        for out in outputs {
            guard let ws = out.activeWorkspace else { continue }
            if let fsID = fullscreenWindow, let mw = windowsByID[fsID] {
                mw.apply(frame: out.visibleFrame)
                continue
            }
            LayoutEngine.compute(workspace: ws.tree, in: out.visibleFrame, ctx: ctx)
            applyTreeFrames(ws.tree)
        }
        for id in floatingWindows {
            if let mw = windowsByID[id] {
                if let saved = mw.savedFloatingFrame {
                    mw.apply(frame: saved)
                }
            }
        }
    }

    private func applyTreeFrames(_ c: Container) {
        if let w = c.window {
            if w.isFloating {
                if let f = w.savedFloatingFrame { w.apply(frame: f) }
            } else if fullscreenWindow != w.id {
                w.apply(frame: c.rect)
            }
            // Un-hide AFTER positioning so the window doesn't briefly flash
            // at its prior offscreen rect. hiddenByUs may mean alpha=0 OR
            // AX.setAppHidden — only showWindow reverses both.
            if w.hiddenByUs { showWindow(w) }
            return
        }
        for child in c.children { applyTreeFrames(child) }
    }

    func currentWorkspace() -> Workspace { ledger.current ?? ledger.workspaces.first! }

    func focusContainer(_ c: Container) {
        focused = c
        c.parent?.bumpFocus(c)
        if let win = c.window {
            win.focus()
            if config.mouseFollowsFocus { warpMouseToFocus(c) }
        }
        bar?.refresh()
    }

    private func warpMouseToFocus(_ c: Container) {
        let r: CGRect
        if c.rect.width > 1 && c.rect.height > 1 {
            r = c.rect
        } else if let win = c.window, win.lastKnownFrame.width > 1 {
            r = win.lastKnownFrame
        } else { return }
        let center = CGPoint(x: r.midX, y: r.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func workspaceContaining(_ c: Container) -> Workspace? {
        var cur: Container? = c
        while let x = cur {
            for ws in ledger.workspaces where ws.tree === x { return ws }
            cur = x.parent
        }
        return nil
    }

    /// Called when an external focus event happens (app activation, AX
    /// focused-window-changed). If the now-focused window belongs to a
    /// non-active workspace, jump to that workspace.
    func handleExternalFocus(windowID id: CGWindowID) {
        guard let c = containerByWindowID[id] else { return }
        guard let target = workspaceContaining(c) else { return }
        if ledger.current === target {
            focused = c
            c.parent?.bumpFocus(c)
            bar?.refresh()
            return
        }
        // Apps we hid still fire focus-changed events as macOS reshuffles
        // their internal focused window — chasing those would teleport us
        // back to the workspace we just left.
        if let win = c.window, win.hiddenByUs { return }
        if Date().timeIntervalSince1970 - lastWorkspaceSwitchAt < Self.focusFollowGracePeriod { return }
        Logger.info("focus-follow: \(describe(c)) is on ws \(target.name) — switching")
        switchWorkspace(name: target.name)
    }

    func handleAppActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElem = AXUIElementCreateApplication(pid)
        guard let win: AXUIElement = AX.attribute(appElem, kAXFocusedWindowAttribute),
              let id = AX.windowID(win), id != 0 else { return }
        handleExternalFocus(windowID: id)
    }

    func handleAppLaunched(_ app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let appElem = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows: [AXUIElement] = AX.attribute(appElem, kAXWindowsAttribute) else { return }
            for w in windows {
                guard WindowDiscovery.isManageable(w), let id = AX.windowID(w) else { continue }
                self.adopt(element: w, pid: app.processIdentifier, id: id)
            }
            self.applyAllLayouts()
            self.bar?.refresh()
        }
    }

    func handleAppTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let dead = windowsByID.values.filter { $0.pid == pid }.map { $0.id }
        for id in dead { release(id: id) }
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        applyAllLayouts()
        bar?.refresh()
    }

    func handleSpaceChanged() {
        scanExistingWindows()
        applyAllLayouts()
    }

    func handleScreensChanged() {
        rebuildOutputs()
        for out in outputs where out.activeWorkspace == nil {
            if let ws = ledger.workspaces.first(where: { $0.output === out }) {
                out.activeWorkspace = ws
            }
        }
        applyAllLayouts()
    }

    private func observe(pid: pid_t, element: AXUIElement) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let obs = observers[pid] {
            AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(obs, element, kAXMovedNotification as CFString, refcon)
            AXObserverAddNotification(obs, element, kAXResizedNotification as CFString, refcon)
            return
        }
        var observerOut: AXObserver?
        let cb: AXObserverCallback = { _, elem, notif, refcon in
            guard let refcon = refcon else { return }
            let mgr = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            let n = notif as String
            DispatchQueue.main.async {
                if n == kAXUIElementDestroyedNotification as String {
                    if let id = AX.windowID(elem) {
                        mgr.release(id: id); mgr.applyAllLayouts(); mgr.bar?.refresh()
                    }
                } else if n == kAXFocusedWindowChangedNotification as String {
                    if let id = AX.windowID(elem) {
                        mgr.handleExternalFocus(windowID: id)
                    }
                } else if n == kAXApplicationHiddenNotification as String {
                    var p: pid_t = 0
                    AXUIElementGetPid(elem, &p)
                    if p > 0 { mgr.handleAppHidden(pid: p) }
                } else if n == kAXWindowCreatedNotification as String {
                    var p: pid_t = 0
                    AXUIElementGetPid(elem, &p)
                    if WindowDiscovery.isManageable(elem), let id = AX.windowID(elem), p > 0 {
                        mgr.adopt(element: elem, pid: p, id: id)
                        mgr.applyAllLayouts()
                        mgr.bar?.refresh()
                    }
                }
            }
        }
        let result = AXObserverCreate(pid, cb, &observerOut)
        guard result == .success, let obs = observerOut else { return }
        AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXResizedNotification as CFString, refcon)
        let appElem = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appElem, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appElem, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appElem, kAXApplicationHiddenNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func describe(_ c: Container?) -> String {
        guard let c = c, let w = c.window else { return "<no window>" }
        let title = w.title.isEmpty ? "<untitled>" : w.title
        return "[\(w.appName)] \(title)"
    }

    private func appHasOtherVisibleWindow(_ mw: ManagedWindow) -> Bool {
        let visibleWsIDs = Set(outputs.compactMap { $0.activeWorkspace.map { ObjectIdentifier($0) } })
        for other in windowsByID.values where other.pid == mw.pid && other.id != mw.id {
            guard let c = containerByWindowID[other.id], let ws = workspaceContaining(c) else { continue }
            if visibleWsIDs.contains(ObjectIdentifier(ws)) { return true }
        }
        return false
    }

    private func hideWindow(_ mw: ManagedWindow) {
        if appHasOtherVisibleWindow(mw) {
            // Per-window: alpha=0 + offscreen. Used when an app spans multiple
            // workspaces and we can't hide the whole app.
            CGS.setAlpha(mw.id, 0)
            AX.setPosition(mw.element, CGPoint(x: -30000, y: -30000))
        } else {
            // App-level hide — equivalent to ⌘H. Truly instant, no animation.
            // Mark this as our own hide so the AX observer doesn't treat the
            // ensuing kAXApplicationHiddenNotification as a user ⌘H press.
            pendingOurHides[mw.pid, default: 0] += 1
            AX.setAppHidden(mw.pid, true)
        }
        mw.hiddenByUs = true
    }

    private func showWindow(_ mw: ManagedWindow) {
        // Either path — unhide the app and restore alpha. Both are no-ops if
        // they were already in the right state.
        AX.setAppHidden(mw.pid, false)
        CGS.setAlpha(mw.id, 1)
        mw.hiddenByUs = false

        // Unhiding the whole app also reveals sibling windows of this app on
        // inactive workspaces. Re-hide those via the per-window mechanism.
        let visibleWsIDs = Set(outputs.compactMap { $0.activeWorkspace.map { ObjectIdentifier($0) } })
        for other in windowsByID.values where other.pid == mw.pid && other.id != mw.id && other.hiddenByUs {
            guard let c = containerByWindowID[other.id], let ws = workspaceContaining(c) else { continue }
            if !visibleWsIDs.contains(ObjectIdentifier(ws)) {
                CGS.setAlpha(other.id, 0)
                AX.setPosition(other.element, CGPoint(x: -30000, y: -30000))
            }
        }
    }

    func nextUnusedWorkspace() -> Workspace {
        if let empty = ledger.workspaces.first(where: { $0.tree.collectWindows().isEmpty }) {
            return empty
        }
        let ws = ledger.ensure(name: ledger.nextNumberedName())
        if ws.output == nil { ws.output = outputs.first }
        return ws
    }

    /// Called when AX reports an application became hidden. If this hide came
    /// from us (workspace switch) we ignore it; otherwise the user pressed ⌘H,
    /// so we relocate any of that app's windows that were on a visible
    /// workspace to an empty workspace, preserving the invariant that every
    /// window lives in exactly one workspace's tree.
    func handleAppHidden(pid: pid_t) {
        if let count = pendingOurHides[pid], count > 0 {
            if count == 1 { pendingOurHides.removeValue(forKey: pid) }
            else { pendingOurHides[pid] = count - 1 }
            return
        }
        let visibleWsIDs = Set(outputs.compactMap { $0.activeWorkspace.map { ObjectIdentifier($0) } })
        let appWindowsOnVisibleWs: [(ManagedWindow, Container)] = windowsByID.values.compactMap { w in
            guard w.pid == pid else { return nil }
            guard let c = containerByWindowID[w.id], let ws = workspaceContaining(c) else { return nil }
            guard visibleWsIDs.contains(ObjectIdentifier(ws)) else { return nil }
            return (w, c)
        }
        if appWindowsOnVisibleWs.isEmpty { return }
        let target = nextUnusedWorkspace()
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid=\(pid)"
        Logger.info("user ⌘H: moving \(appWindowsOnVisibleWs.count) [\(appName)] window(s) to ws \(target.name)")
        for (w, c) in appWindowsOnVisibleWs {
            let prevParent = c.parent
            c.parent?.remove(c)
            target.tree.add(c)
            if let p = prevParent { collapseIfRedundant(p) }
            w.hiddenByUs = true
        }
        applyAllLayouts()
        bar?.refresh()
    }

    func syncFocusFromSystem() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let appElem = AXUIElementCreateApplication(pid)
        guard let win: AXUIElement = AX.attribute(appElem, kAXFocusedWindowAttribute) else { return }
        guard let id = AX.windowID(win), id != 0 else { return }
        if let c = containerByWindowID[id] {
            if focused !== c {
                Logger.debug("sync focus: \(describe(focused)) → \(describe(c))")
                focused = c
                c.parent?.bumpFocus(c)
            }
            return
        }
        // System has focus on a window we haven't adopted — try to pick it up.
        if WindowDiscovery.isManageable(win) {
            adopt(element: win, pid: pid, id: id)
            if let c = containerByWindowID[id] {
                focused = c
                c.parent?.bumpFocus(c)
                Logger.info("sync focus: adopted previously-unknown \(describe(c))")
            }
        }
    }

    func directionalFocus(_ d: Direction) {
        syncFocusFromSystem()
        guard let cur = focused else { Logger.info("focus \(d): no current window"); return }
        guard let target = neighbor(of: cur, direction: d) else {
            Logger.info("focus \(d): no neighbor — staying on \(describe(cur))")
            return
        }
        let leaf = target.deepestFocusedLeaf()
        Logger.info("focus \(d): \(describe(cur)) → \(describe(leaf))")
        focusContainer(leaf)
        applyAllLayouts()
    }

    func neighbor(of c: Container, direction d: Direction) -> Container? {
        var cur = c
        while let parent = cur.parent {
            let parentOrient = Orientation.from(parent.layout)
            if parentOrient == d.orientation, let idx = parent.indexOf(cur) {
                let target = idx + (d.positive ? 1 : -1)
                if target >= 0 && target < parent.children.count {
                    return parent.children[target]
                }
            }
            cur = parent
        }
        return nil
    }

    func directionalMove(_ d: Direction) {
        syncFocusFromSystem()
        guard let cur = focused else { Logger.info("move \(d): no current window"); return }
        guard let parent = cur.parent else { return }
        Logger.info("move \(d): \(describe(cur))")
        let parentOrient = Orientation.from(parent.layout)
        if parentOrient == d.orientation, let idx = parent.indexOf(cur) {
            let target = idx + (d.positive ? 1 : -1)
            if target >= 0 && target < parent.children.count {
                // Swap fractions in lockstep with positions so visual sizes
                // stay attached to the windows, not the slots.
                let f = parent.children[idx].fraction
                parent.children[idx].fraction = parent.children[target].fraction
                parent.children[target].fraction = f
                parent.children.swapAt(idx, target)
                applyAllLayouts()
                return
            }
        }
        var ancestor: Container? = cur.parent
        while let a = ancestor {
            if let aParent = a.parent {
                let aOrient = Orientation.from(aParent.layout)
                if aOrient == d.orientation, let idx = aParent.indexOf(a) {
                    let target = idx + (d.positive ? 1 : 0)
                    let sourceParent = cur.parent
                    cur.parent?.remove(cur)
                    aParent.add(cur, at: target)
                    if let sp = sourceParent { collapseIfRedundant(sp) }
                    applyAllLayouts()
                    return
                }
            }
            ancestor = a.parent
        }
        // No matching-orientation ancestor. Mirror i3's `ws_force_orientation`:
        // flip the entire workspace's orientation so the move can land. The
        // moved window ends up next to the rest of the workspace's content,
        // on the side dictated by direction d.
        //
        // Example: splitH[A, B, C, D], focused B, move down →
        //   workspace.layout flips to splitV
        //   workspace.children = [splitH[A, C, D], B]   (B drops below row)
        guard let ws = workspaceContaining(cur)?.tree else { return }
        if Orientation.from(ws.layout) == d.orientation {
            return
        }
        let inner = Container(kind: .split)
        inner.layout = ws.layout
        let kids = ws.children
        for c in kids { ws.remove(c) }
        ws.layout = d.orientation == .horizontal ? .splitH : .splitV
        ws.add(inner)
        for c in kids { inner.add(c) }
        let sourceParent = cur.parent
        cur.parent?.remove(cur)
        ws.add(cur, at: d.positive ? 1 : 0)
        if let sp = sourceParent, sp !== inner { collapseIfRedundant(sp) }
        collapseIfRedundant(inner)
        // The cascade of fixFractions during the rewrap leaves residue from
        // the previous normalizations, often shrinking the moved window to
        // an unusable sliver. Reset to a clean balanced state: workspace's
        // two halves are 50/50, and the surviving row/column inside is
        // evenly divided.
        for c in ws.children { c.fraction = 0.5 }
        if !inner.children.isEmpty {
            let eq = 1.0 / CGFloat(inner.children.count)
            for c in inner.children { c.fraction = eq }
        }
        applyAllLayouts()
    }

    func switchWorkspace(name: String) {
        let ws: Workspace
        if let existing = ledger.workspaces.first(where: { $0.name == name }) {
            ws = existing
        } else {
            ws = ledger.ensure(name: name)
            if ws.output == nil { ws.output = outputs.first }
        }
        if config.workspaceAutoBackAndForth, ledger.current?.name == name, let prev = ledger.previous {
            Logger.info("workspace: auto_back_and_forth → \(prev.name)")
            return switchWorkspace(name: prev.name)
        }
        let previous = ledger.current
        if previous?.name == ws.name { return }
        lastWorkspaceSwitchAt = Date().timeIntervalSince1970
        // pendingSplit is a one-shot scoped to "next window in this workspace
        // and moment" — leaving it set across a switch makes a stale split
        // intent get applied to an unrelated future window.
        pendingSplit = .none
        let nWindows = ws.tree.collectWindows().count
        Logger.info("workspace: \(previous?.name ?? "?") → \(ws.name) (\(nWindows) window\(nWindows == 1 ? "" : "s"))")
        if let out = ws.output {
            out.activeWorkspace = ws
        }
        ledger.setCurrent(ws)
        // Restore windows on the workspace we're showing. Order matters:
        // first re-tile (positions them correctly), then make them visible —
        // otherwise the user briefly sees them at their stale off-screen rect.
        for w in ws.tree.collectWindows() where w.minimizedByUs {
            // legacy minimize cleanup
            AX.setMinimized(w.element, false)
            w.minimizedByUs = false
        }
        applyAllLayouts()
        for w in ws.tree.collectWindows() where w.hiddenByUs {
            showWindow(w)
        }
        // Hide windows we're leaving behind (skip ones the user minimized
        // themselves so they stay minimized when we come back).
        for w in (previous?.tree.collectWindows() ?? []) where !AX.isMinimized(w.element) {
            hideWindow(w)
        }
        let leaf = ws.tree.deepestFocusedLeaf()
        if let firstWin = leaf.window {
            focused = leaf
            firstWin.focus()
            if config.mouseFollowsFocus { warpMouseToFocus(leaf) }
        } else {
            focused = ws.tree
        }
        bar?.refresh()
    }

    func moveContainerToWorkspace(name: String) {
        syncFocusFromSystem()
        guard let cur = focused else { Logger.info("move-to-ws \(name): no current window"); return }
        let ws = ledger.workspaces.first(where: { $0.name == name }) ?? ledger.ensure(name: name)
        if ws.output == nil { ws.output = outputs.first }
        let from = ledger.current?.name ?? "?"
        Logger.info("move-to-ws: \(describe(cur)) — ws \(from) → ws \(name)")
        let prevParent = cur.parent
        let sourceWs = ledger.current
        cur.parent?.remove(cur)
        ws.tree.add(cur)
        if let p = prevParent { collapseIfRedundant(p) }

        let destVisible = outputs.contains { $0.activeWorkspace === ws }
        if !destVisible, let w = cur.window {
            hideWindow(w)
        }

        // The moved container was the focused one, so move focus to whatever
        // leaf is left in the source workspace.
        if let src = sourceWs {
            let leaf = src.tree.deepestFocusedLeaf()
            if let win = leaf.window {
                focused = leaf
                win.focus()
                if config.mouseFollowsFocus { warpMouseToFocus(leaf) }
            } else {
                focused = src.tree
            }
        }

        applyAllLayouts()
        bar?.refresh()
    }

    func killFocused() {
        syncFocusFromSystem()
        if let cur = focused { Logger.info("kill: \(describe(cur))") }
        focused?.window?.close()
    }

    func setLayout(_ name: String) {
        syncFocusFromSystem()
        guard let cur = focused, let parent = cur.parent else { return }
        switch name {
        case "splith": parent.layout = .splitH
        case "splitv": parent.layout = .splitV
        case "tabbed": parent.layout = .tabbed
        case "stacking": parent.layout = .stacking
        case "toggle":
            parent.layout = parent.layout == .splitH ? .splitV : .splitH
        case "toggle split":
            parent.layout = parent.layout == .splitH ? .splitV : .splitH
        default: break
        }
        applyAllLayouts()
    }

    func split(_ orient: Orientation) {
        pendingSplit = orient
    }

    func toggleFullscreen() {
        syncFocusFromSystem()
        guard let cur = focused, let mw = cur.window else { return }
        let wasFs = fullscreenWindow == mw.id
        Logger.info("fullscreen \(wasFs ? "off" : "on"): \(describe(cur))")
        if wasFs { fullscreenWindow = nil } else { fullscreenWindow = mw.id }
        applyAllLayouts()
    }

    func toggleFloating() {
        syncFocusFromSystem()
        guard let cur = focused, let mw = cur.window else { return }
        Logger.info("float \(mw.isFloating ? "off" : "on"): \(describe(cur))")
        // Toggle the flag only — the container stays in its workspace tree
        // either way, so the per-window-per-workspace invariant holds.
        if mw.isFloating {
            mw.isFloating = false
            floatingWindows.remove(mw.id)
        } else {
            mw.savedFloatingFrame = currentFrame(mw.element)
            if mw.savedFloatingFrame == nil {
                let r = currentWorkspace().tree.rect
                mw.savedFloatingFrame = CGRect(x: r.midX - 300, y: r.midY - 200, width: 600, height: 400)
            }
            mw.isFloating = true
            floatingWindows.insert(mw.id)
        }
        applyAllLayouts()
    }

    func resizeFocused(direction: Direction, pixels: CGFloat, ppt: CGFloat) {
        syncFocusFromSystem()
        guard let cur = focused else {
            Logger.info("resize \(direction): no focused window")
            return
        }
        // Walk up to find an ancestor whose parent's layout matches the
        // requested axis. The container we resize is a child of that
        // matching parent. This mirrors i3's `resize_neighboring_cons`
        // search: a `resize grow height` on a window inside a horizontal
        // row resizes the row itself within its vertical workspace, not
        // bails like the previous implementation did.
        var node: Container = cur
        var matchedParent: Container? = nil
        while let p = node.parent {
            if Orientation.from(p.layout) == direction.orientation, p.children.count >= 2 {
                matchedParent = p
                break
            }
            node = p
        }
        guard let parent = matchedParent, let idx = parent.indexOf(node) else {
            Logger.info("resize \(direction): no axis-matching ancestor for \(describe(cur))")
            return
        }
        let n = parent.children.count
        let span = direction.orientation == .horizontal ? parent.rect.width : parent.rect.height
        let delta: CGFloat = pixels > 0 ? pixels / max(span, 1) : ppt / 100.0
        let signed: CGFloat = direction.positive ? +delta : -delta
        // Pick the neighbor whose slot we'll trade space with — the one on
        // the side of `direction`. If we're at the edge, fall back to the
        // other neighbor so resize still works at the boundary.
        let primaryNeighbor = direction.positive ? idx + 1 : idx - 1
        let fallbackNeighbor = direction.positive ? idx - 1 : idx + 1
        let neighborIdx: Int
        if primaryNeighbor >= 0 && primaryNeighbor < n {
            neighborIdx = primaryNeighbor
        } else if fallbackNeighbor >= 0 && fallbackNeighbor < n {
            neighborIdx = fallbackNeighbor
        } else {
            return
        }
        let me = node
        let other = parent.children[neighborIdx]
        // Directional semantic: the directional key moves the shared edge
        // in the key's direction. If the neighbor is on the *positive*
        // side of me (idx+1, below/right), moving the shared edge in the
        // positive direction grows me. If the neighbor is on the *negative*
        // side (idx-1, above/left), moving the shared edge positive shrinks
        // me. Hence the sign on my fraction flips when we use the negative-
        // side neighbor.
        let neighborSign: CGFloat = neighborIdx > idx ? 1 : -1
        let myDelta = signed * neighborSign
        let minF: CGFloat = 0.05
        // Bound the trade so neither side collapses below minF.
        let bounded: CGFloat
        if myDelta >= 0 {
            bounded = min(myDelta, max(other.fraction - minF, 0))
        } else {
            bounded = -min(-myDelta, max(me.fraction - minF, 0))
        }
        me.fraction = me.fraction + bounded
        other.fraction = other.fraction - bounded
        Logger.info("resize \(direction) on \(describe(cur)): Δ=\(String(format: "%.3f", bounded)) (neighbor \(neighborIdx > idx ? "below/right" : "above/left"))")
        applyAllLayouts()
    }

    private func d_orientation(_ d: Direction) -> Orientation { d.orientation }

    func gapsAdjust(kind: String, delta: CGFloat) {
        switch kind {
        case "inner": config.innerGap = max(0, config.innerGap + delta)
        case "outer": config.outerGap = max(0, config.outerGap + delta)
        default: break
        }
        applyAllLayouts()
    }

    func enterMode(_ name: String) {
        if name == "default" {
            mode = "default"
        } else {
            mode = name
        }
        bar?.refresh()
    }

    func focusModeToggle() {
        guard let cur = focused, let mw = cur.window else { return }
        let candidates = currentWorkspace().tree.collectWindows()
        let target: ManagedWindow?
        if mw.isFloating {
            target = candidates.first { !$0.isFloating }
        } else {
            target = candidates.first { $0.isFloating }
        }
        guard let t = target, let c = containerByWindowID[t.id] else { return }
        focusContainer(c)
    }

    func focusParent() {
        guard let cur = focused, let parent = cur.parent else { return }
        focused = parent
        bar?.refresh()
    }

    func moveWorkspaceToOutput(direction: String) {
        guard let cur = ledger.current, let curOut = cur.output, let idx = outputs.firstIndex(where: { $0 === curOut }) else { return }
        let target: Output
        switch direction {
        case "left": target = outputs[max(0, idx - 1)]
        case "right": target = outputs[min(outputs.count - 1, idx + 1)]
        default: return
        }
        if target === curOut { return }
        cur.output = target
        if !target.workspaces.contains(where: { $0 === cur }) { target.workspaces.append(cur) }
        target.activeWorkspace = cur
        applyAllLayouts()
        bar?.refresh()
    }
}
