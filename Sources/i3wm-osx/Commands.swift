import AppKit
import Foundation
import CoreGraphics

enum I3Command {
    case focus(Direction)
    case focusParent
    case focusChild
    case focusModeToggle
    case move(Direction)
    case moveContainerToWorkspace(String)
    case moveWorkspaceToOutput(String)
    case splitH
    case splitV
    case splitToggle
    case layout(String)
    case fullscreenToggle
    case floatingToggle
    case floatingEnable
    case floatingDisable
    case workspace(String)
    case workspaceNext
    case workspacePrev
    case kill
    case exec(String, noStartupId: Bool)
    case gapsAdjust(kind: String, deltaSign: Int, amount: CGFloat)
    case mode(String)
    case resize(grow: Bool, axis: String, px: CGFloat, ppt: CGFloat)
    case reload
    case restart
    case exit
    case nop
}

enum CommandParser {
    static func parse(_ text: String) -> [I3Command] {
        let parts = splitCommands(text)
        var out: [I3Command] = []
        for p in parts {
            let trimmed = p.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let c = parseSingle(trimmed) { out.append(c) }
        }
        return out
    }

    private static func splitCommands(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inDouble = false, inSingle = false, inBracket = 0
        for c in s {
            if c == "\"", !inSingle, inBracket == 0 { inDouble.toggle(); cur.append(c); continue }
            if c == "'", !inDouble, inBracket == 0 { inSingle.toggle(); cur.append(c); continue }
            if c == "[", !inDouble, !inSingle { inBracket += 1; cur.append(c); continue }
            if c == "]", !inDouble, !inSingle { inBracket = max(0, inBracket - 1); cur.append(c); continue }
            if (c == ";" || c == ",") && !inDouble && !inSingle && inBracket == 0 {
                out.append(cur); cur = ""
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func parseSingle(_ text: String) -> I3Command? {
        let toks = tokenize(text)
        guard let head = toks.first else { return nil }
        let rest = Array(toks.dropFirst())
        switch head {
        case "focus":
            if let arg = rest.first {
                switch arg {
                case "left": return .focus(.left)
                case "right": return .focus(.right)
                case "up": return .focus(.up)
                case "down": return .focus(.down)
                case "parent": return .focusParent
                case "child": return .focusChild
                case "mode_toggle": return .focusModeToggle
                default: break
                }
            }
            return nil
        case "move":
            return parseMove(rest)
        case "split":
            switch rest.first {
            case "h", "horizontal": return .splitH
            case "v", "vertical": return .splitV
            case "toggle": return .splitToggle
            default: return nil
            }
        case "layout":
            return .layout(rest.joined(separator: " "))
        case "fullscreen":
            return .fullscreenToggle
        case "floating":
            switch rest.first {
            case "toggle": return .floatingToggle
            case "enable": return .floatingEnable
            case "disable": return .floatingDisable
            default: return nil
            }
        case "workspace":
            if rest.first == "next" { return .workspaceNext }
            if rest.first == "prev" || rest.first == "previous" { return .workspacePrev }
            if rest.first == "back_and_forth" { return .workspace("back_and_forth") }
            if rest.first == "number", rest.count > 1 { return .workspace(rest[1]) }
            if let arg = rest.first { return .workspace(arg) }
            return nil
        case "kill":
            return .kill
        case "exec":
            var noStartup = false
            var args = rest
            while let f = args.first, f.hasPrefix("--") {
                if f == "--no-startup-id" { noStartup = true }
                args.removeFirst()
            }
            let cmd = args.map { stripQuotes($0) }.joined(separator: " ")
            return .exec(cmd, noStartupId: noStartup)
        case "gaps":
            return parseGaps(rest)
        case "mode":
            if let n = rest.first { return .mode(stripQuotes(n)) }
            return nil
        case "resize":
            return parseResize(rest)
        case "reload": return .reload
        case "restart": return .restart
        case "exit": return .exit
        case "bar":
            return .nop
        default:
            return nil
        }
    }

    private static func parseMove(_ rest: [String]) -> I3Command? {
        guard let first = rest.first else { return nil }
        switch first {
        case "left": return .move(.left)
        case "right": return .move(.right)
        case "up": return .move(.up)
        case "down": return .move(.down)
        case "container":
            if rest.count >= 4, rest[1] == "to", rest[2] == "workspace" {
                if rest[3] == "number", rest.count > 4 { return .moveContainerToWorkspace(rest[4]) }
                return .moveContainerToWorkspace(rest[3])
            }
        case "workspace":
            if rest.count >= 4, rest[1] == "to", rest[2] == "output" {
                return .moveWorkspaceToOutput(rest[3])
            }
            if rest.count >= 2 {
                return .moveContainerToWorkspace(rest[1])
            }
        case "to":
            if rest.count >= 3, rest[1] == "workspace" {
                return .moveContainerToWorkspace(rest[2])
            }
        default: break
        }
        return nil
    }

    private static func parseGaps(_ rest: [String]) -> I3Command? {
        guard rest.count >= 4 else { return nil }
        let kind = rest[0]
        if rest[1] == "current" {
            let sign = rest[2] == "plus" ? 1 : (rest[2] == "minus" ? -1 : 0)
            let amount = CGFloat(Double(rest[3]) ?? 0)
            return .gapsAdjust(kind: kind, deltaSign: sign, amount: amount)
        }
        return nil
    }

    private static func parseResize(_ rest: [String]) -> I3Command? {
        guard rest.count >= 3 else { return nil }
        let grow = rest[0] == "grow"
        let axis = rest[1]
        let px = CGFloat(Double(rest[2]) ?? 0)
        var ppt: CGFloat = 0
        if rest.count >= 7, rest[3] == "px", rest[4] == "or" {
            ppt = CGFloat(Double(rest[5]) ?? 0)
        }
        return .resize(grow: grow, axis: axis, px: px, ppt: ppt)
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inDouble = false, inSingle = false, inBracket = 0
        for c in s {
            if c == "\"", !inSingle, inBracket == 0 { inDouble.toggle(); continue }
            if c == "'", !inDouble, inBracket == 0 { inSingle.toggle(); continue }
            if c == "[", !inDouble, !inSingle { inBracket += 1; cur.append(c); continue }
            if c == "]", !inDouble, !inSingle { inBracket = max(0, inBracket - 1); cur.append(c); continue }
            if (c == " " || c == "\t"), !inDouble, !inSingle, inBracket == 0 {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func stripQuotes(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2) || (s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

enum CommandExecutor {
    @discardableResult
    static func execute(_ cmd: I3Command, app: I3App) -> Bool {
        let mgr = app.manager
        switch cmd {
        case .focus(let d): mgr.directionalFocus(d); return true
        case .focusParent: mgr.focusParent(); return true
        case .focusChild:
            if let f = mgr.focused, let last = f.lastFocusedChild { mgr.focusContainer(last) }
            return true
        case .focusModeToggle: mgr.focusModeToggle(); return true
        case .move(let d): mgr.directionalMove(d); return true
        case .moveContainerToWorkspace(let name): mgr.moveContainerToWorkspace(name: name); return true
        case .moveWorkspaceToOutput(let dir): mgr.moveWorkspaceToOutput(direction: dir); return true
        case .splitH: mgr.split(.horizontal); return true
        case .splitV: mgr.split(.vertical); return true
        case .splitToggle:
            let cur = mgr.focused?.parent?.layout
            mgr.split(cur == .splitV ? .horizontal : .vertical)
            return true
        case .layout(let s): mgr.setLayout(s); return true
        case .fullscreenToggle: mgr.toggleFullscreen(); return true
        case .floatingToggle: mgr.toggleFloating(); return true
        case .floatingEnable:
            if let mw = mgr.focused?.window, !mw.isFloating { mgr.toggleFloating() }
            return true
        case .floatingDisable:
            if let mw = mgr.focused?.window, mw.isFloating { mgr.toggleFloating() }
            return true
        case .workspace(let name):
            if name == "back_and_forth" {
                if let prev = mgr.ledger.previous { mgr.switchWorkspace(name: prev.name) }
            } else {
                mgr.switchWorkspace(name: name)
            }
            return true
        case .workspaceNext:
            if let cur = mgr.ledger.current, let i = mgr.ledger.workspaces.firstIndex(where: { $0 === cur }) {
                let nx = mgr.ledger.workspaces[(i + 1) % mgr.ledger.workspaces.count]
                mgr.switchWorkspace(name: nx.name)
            }
            return true
        case .workspacePrev:
            if let cur = mgr.ledger.current, let i = mgr.ledger.workspaces.firstIndex(where: { $0 === cur }) {
                let n = mgr.ledger.workspaces.count
                let nx = mgr.ledger.workspaces[(i - 1 + n) % n]
                mgr.switchWorkspace(name: nx.name)
            }
            return true
        case .kill: mgr.killFocused(); return true
        case .exec(let command, _):
            shell(command); return true
        case .gapsAdjust(let kind, let sign, let amount):
            mgr.gapsAdjust(kind: kind, delta: CGFloat(sign) * amount); return true
        case .mode(let name):
            mgr.enterMode(name)
            app.hotkeys.setMode(name == "default" ? "default" : name)
            return true
        case .resize(let grow, let axis, let px, let ppt):
            let dir: Direction
            switch axis {
            case "width": dir = grow ? .right : .left
            case "height": dir = grow ? .down : .up
            default: return false
            }
            mgr.resizeFocused(direction: dir, pixels: px, ppt: ppt)
            return true
        case .reload:
            app.reload(); return true
        case .restart:
            relaunch(app: app); return true
        case .exit:
            NSApplication.shared.terminate(nil); return true
        case .nop:
            return true
        }
    }

    private static func relaunch(app: I3App) {
        // Prefer Bundle.main.executablePath — survives the installer-tempdir
        // case where argv[0] points to a path that's been moved by the time
        // restart fires (e.g. atomic .app replacement during an update).
        let binary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]

        var newArgs = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var i = 0
        while i < newArgs.count {
            if newArgs[i] == "--restore-state" {
                let drop = min(2, newArgs.count - i)
                newArgs.removeSubrange(i..<i + drop)
            } else {
                i += 1
            }
        }

        let snap = RestartState.capture(app.manager)
        if let path = RestartState.write(snap) {
            newArgs.append(contentsOf: ["--restore-state", path])
            Logger.info("restart: snapshot at \(path) (\(snap.workspaces.count) workspaces, \(snap.windowState.count) windows)")
        }

        let task = Process()
        task.launchPath = binary
        task.arguments = newArgs
        do {
            try task.run()
        } catch {
            Logger.warn("restart: launch failed: \(error)")
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
