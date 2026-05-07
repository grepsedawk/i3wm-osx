import AppKit
import Foundation
import CoreGraphics

final class Workspace {
    let name: String
    let number: Int?
    var output: Output?
    let tree: Container

    init(name: String, number: Int?) {
        self.name = name
        self.number = number
        self.tree = Container(kind: .workspace)
    }
}

final class Output {
    let screen: NSScreen
    let id: Int
    var workspaces: [Workspace] = []
    var activeWorkspace: Workspace?

    init(screen: NSScreen, id: Int) {
        self.screen = screen
        self.id = id
    }

    var frame: CGRect {
        let s = screen.frame
        let main = NSScreen.screens.first?.frame ?? s
        let flippedY = main.height - (s.origin.y + s.height)
        return CGRect(x: s.origin.x, y: flippedY, width: s.width, height: s.height)
    }

    var visibleFrame: CGRect {
        let s = screen.visibleFrame
        let main = NSScreen.screens.first?.frame ?? s
        let flippedY = main.height - (s.origin.y + s.height)
        return CGRect(x: s.origin.x, y: flippedY, width: s.width, height: s.height)
    }

    var name: String {
        if let n = screen.localizedName as String?, !n.isEmpty { return n }
        return "output-\(id)"
    }
}

final class WorkspaceLedger {
    var workspaces: [Workspace] = []
    var lastActive: [Int: Workspace] = [:]
    var current: Workspace?
    var previous: Workspace?

    func ensure(name: String) -> Workspace {
        if let ws = workspaces.first(where: { $0.name == name }) { return ws }
        let num = Int(name)
        let ws = Workspace(name: name, number: num)
        workspaces.append(ws)
        return ws
    }

    func setCurrent(_ ws: Workspace) {
        if current !== ws {
            previous = current
            current = ws
            if let out = ws.output { lastActive[out.id] = ws }
        }
    }

    func nextNumberedName() -> String {
        let used = Set(workspaces.compactMap { $0.number })
        for i in 1...99 { if !used.contains(i) { return "\(i)" } }
        return "\(workspaces.count + 1)"
    }
}
