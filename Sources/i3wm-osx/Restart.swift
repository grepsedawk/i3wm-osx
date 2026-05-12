import Foundation
import CoreGraphics

struct SavedRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ r: CGRect) {
        x = Double(r.origin.x)
        y = Double(r.origin.y)
        width = Double(r.width)
        height = Double(r.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct SavedContainer: Codable {
    var id: Int
    var kind: String
    var leafWindowID: UInt32?
    var layout: String
    var fraction: Double
    var focusOrder: [Int]
    var children: [SavedContainer]
}

struct SavedWorkspace: Codable {
    var name: String
    var number: Int?
    var outputID: Int?
    var tree: SavedContainer
}

struct SavedOutputAssignment: Codable {
    var outputID: Int
    var activeWorkspace: String?
}

struct SavedWindowState: Codable {
    var id: UInt32
    var isFloating: Bool
    var savedFloatingFrame: SavedRect?
    var fullscreen: Bool
}

struct RestartSnapshot: Codable {
    var version: Int
    var nextContainerID: Int
    var workspaces: [SavedWorkspace]
    var outputs: [SavedOutputAssignment]
    var current: String?
    var previous: String?
    var lastActive: [String: String]
    var floatingWindows: [UInt32]
    var fullscreenWindow: UInt32?
    var mode: String
    var modeStack: [String]
    var windowState: [SavedWindowState]
}

enum RestartState {
    static let snapshotVersion = 1

    static func capture(_ mgr: WindowManager) -> RestartSnapshot {
        var snap = RestartSnapshot(
            version: snapshotVersion,
            nextContainerID: Container.nextID,
            workspaces: [],
            outputs: [],
            current: mgr.ledger.current?.name,
            previous: mgr.ledger.previous?.name,
            lastActive: [:],
            floatingWindows: mgr.floatingWindows.map { UInt32($0) },
            fullscreenWindow: mgr.fullscreenWindow.map { UInt32($0) },
            mode: mgr.mode,
            modeStack: mgr.modeStack,
            windowState: []
        )
        for ws in mgr.ledger.workspaces {
            snap.workspaces.append(SavedWorkspace(
                name: ws.name,
                number: ws.number,
                outputID: ws.output?.id,
                tree: encodeContainer(ws.tree)
            ))
        }
        for out in mgr.outputs {
            snap.outputs.append(SavedOutputAssignment(
                outputID: out.id,
                activeWorkspace: out.activeWorkspace?.name
            ))
        }
        for (oid, ws) in mgr.ledger.lastActive {
            snap.lastActive[String(oid)] = ws.name
        }
        for (id, mw) in mgr.windowsByID {
            snap.windowState.append(SavedWindowState(
                id: UInt32(id),
                isFloating: mw.isFloating,
                savedFloatingFrame: mw.savedFloatingFrame.map(SavedRect.init),
                fullscreen: mw.fullscreen
            ))
        }
        return snap
    }

    private static func encodeContainer(_ c: Container) -> SavedContainer {
        let kindTag: String
        var leafID: UInt32? = nil
        switch c.kind {
        case .root: kindTag = "root"
        case .workspace: kindTag = "workspace"
        case .split: kindTag = "split"
        case .window(let mw):
            kindTag = "window"
            leafID = UInt32(mw.id)
        }
        return SavedContainer(
            id: c.id,
            kind: kindTag,
            leafWindowID: leafID,
            layout: c.layout.rawValue,
            fraction: Double(c.fraction),
            focusOrder: c.focusOrder,
            children: c.children.map(encodeContainer)
        )
    }

    static func write(_ snap: RestartSnapshot) -> String? {
        let dir = NSTemporaryDirectory()
        let path = "\(dir)i3wm-osx-restart-\(getpid())-\(Int.random(in: 0..<1_000_000)).json"
        do {
            let data = try JSONEncoder().encode(snap)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            Logger.warn("restart: snapshot write failed: \(error)")
            return nil
        }
    }

    static func load(_ path: String) -> RestartSnapshot? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let snap = try JSONDecoder().decode(RestartSnapshot.self, from: data)
            guard snap.version == snapshotVersion else {
                Logger.warn("restart: snapshot version \(snap.version) != \(snapshotVersion), discarding")
                return nil
            }
            return snap
        } catch {
            Logger.warn("restart: snapshot load failed: \(error)")
            return nil
        }
    }
}

extension WindowManager {
    func applyRestoreSnapshot(_ snap: RestartSnapshot) {
        Container.nextID = max(Container.nextID, snap.nextContainerID)

        let liveIDs = Set(windowsByID.keys)
        var unclaimed = liveIDs

        containerByWindowID.removeAll()

        for saved in snap.workspaces {
            let ws = ledger.ensure(name: saved.name)
            let existing = ws.tree.children
            for child in existing { ws.tree.remove(child) }
            ws.tree.id = saved.tree.id
            ws.tree.layout = Layout(rawValue: saved.tree.layout) ?? .splitH
            ws.tree.focusOrder = []
            let rebuilt = saved.tree.children.compactMap { rebuildContainer($0, unclaimed: &unclaimed) }
            for c in rebuilt { ws.tree.add(c) }
            let surviving = Set(ws.tree.children.map { $0.id })
            ws.tree.focusOrder = saved.tree.focusOrder.filter { surviving.contains($0) }
            for c in ws.tree.children where !ws.tree.focusOrder.contains(c.id) {
                ws.tree.focusOrder.append(c.id)
            }
        }

        for out in outputs {
            out.workspaces.removeAll()
            out.activeWorkspace = nil
        }
        for saved in snap.workspaces {
            let ws = ledger.ensure(name: saved.name)
            if let oid = saved.outputID, let out = outputs.first(where: { $0.id == oid }) {
                ws.output = out
                out.workspaces.append(ws)
            } else if let primary = outputs.first {
                ws.output = primary
                primary.workspaces.append(ws)
            }
        }
        for assign in snap.outputs {
            guard let out = outputs.first(where: { $0.id == assign.outputID }) else { continue }
            if let name = assign.activeWorkspace,
               let ws = ledger.workspaces.first(where: { $0.name == name }) {
                out.activeWorkspace = ws
            }
        }
        for out in outputs where out.activeWorkspace == nil {
            out.activeWorkspace = out.workspaces.first
        }

        if let cur = snap.current, let ws = ledger.workspaces.first(where: { $0.name == cur }) {
            ledger.current = ws
        }
        if let prev = snap.previous, let ws = ledger.workspaces.first(where: { $0.name == prev }) {
            ledger.previous = ws
        }
        ledger.lastActive.removeAll()
        for (oidStr, name) in snap.lastActive {
            if let oid = Int(oidStr),
               let out = outputs.first(where: { $0.id == oid }),
               let ws = ledger.workspaces.first(where: { $0.name == name }) {
                ledger.lastActive[out.id] = ws
            }
        }

        for state in snap.windowState {
            let id = CGWindowID(state.id)
            guard let mw = windowsByID[id] else { continue }
            mw.isFloating = state.isFloating
            mw.savedFloatingFrame = state.savedFloatingFrame?.cgRect
            mw.fullscreen = state.fullscreen
            if state.isFloating {
                floatingWindows.insert(id)
            } else {
                floatingWindows.remove(id)
            }
        }
        if let fsID = snap.fullscreenWindow, windowsByID[CGWindowID(fsID)] != nil {
            fullscreenWindow = CGWindowID(fsID)
        } else {
            fullscreenWindow = nil
        }

        if !unclaimed.isEmpty {
            let target = ledger.current ?? ledger.workspaces.first
            if let ws = target {
                for id in unclaimed {
                    guard let mw = windowsByID[id] else { continue }
                    let leaf = Container(kind: .window(mw))
                    ws.tree.add(leaf)
                    containerByWindowID[id] = leaf
                }
            }
        }

        mode = snap.mode
        modeStack = snap.modeStack

        if let cur = ledger.current {
            focused = cur.tree.deepestFocusedLeaf()
        }

        applyAllLayouts()
        bar?.refresh()
    }

    private func rebuildContainer(_ saved: SavedContainer, unclaimed: inout Set<CGWindowID>) -> Container? {
        switch saved.kind {
        case "window":
            guard let savedID = saved.leafWindowID else { return nil }
            let id = CGWindowID(savedID)
            guard let mw = windowsByID[id] else { return nil }
            unclaimed.remove(id)
            let c = Container(kind: .window(mw))
            c.id = saved.id
            c.fraction = CGFloat(saved.fraction)
            containerByWindowID[id] = c
            return c
        case "split":
            let kids = saved.children.compactMap { rebuildContainer($0, unclaimed: &unclaimed) }
            if kids.isEmpty { return nil }
            if kids.count == 1 {
                let only = kids[0]
                only.fraction = CGFloat(saved.fraction)
                return only
            }
            let c = Container(kind: .split)
            c.id = saved.id
            c.layout = Layout(rawValue: saved.layout) ?? .splitH
            c.fraction = CGFloat(saved.fraction)
            for child in kids { c.add(child) }
            let surviving = Set(kids.map { $0.id })
            c.focusOrder = saved.focusOrder.filter { surviving.contains($0) }
            for ch in kids where !c.focusOrder.contains(ch.id) { c.focusOrder.append(ch.id) }
            return c
        default:
            return nil
        }
    }
}
