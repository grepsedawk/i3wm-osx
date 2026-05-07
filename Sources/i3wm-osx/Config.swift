import Foundation
import CoreGraphics

struct Keybinding {
    var keyspec: String
    var commandText: String
    var release: Bool = false
}

struct ModeDef {
    var name: String
    var bindings: [Keybinding]
}

struct ForWindowRule {
    var criteria: [String: String]
    var command: String
}

struct BarColors {
    var background: String?
    var statusline: String?
    var separator: String?
    var focusedWorkspace: [String] = []
    var activeWorkspace: [String] = []
    var inactiveWorkspace: [String] = []
    var urgentWorkspace: [String] = []
    var bindingMode: [String] = []
}

struct BarConfig {
    var statusCommand: String?
    var workspaceMinWidth: Int = 0
    var trayPadding: Int = 0
    var position: String = "top"
    var colors: BarColors = BarColors()
}

struct ClientColors {
    var border: String
    var background: String
    var text: String
    var indicator: String?
    var childBorder: String?
}

struct I3Config {
    var rawText: String = ""
    var sourcePath: String = ""
    var variables: [String: String] = [:]
    var bindings: [Keybinding] = []
    var execs: [(once: Bool, command: String)] = []
    var modes: [ModeDef] = []
    var forWindow: [ForWindowRule] = []
    var fontPango: String?
    var defaultBorder: String = "normal"
    var smartGaps: Bool = false
    var innerGap: CGFloat = 0
    var outerGap: CGFloat = 0
    var focusOnWindowActivation: String = "smart"
    var clientColors: [String: ClientColors] = [:]
    var clientBackground: String?
    var bar: BarConfig = BarConfig()
    var floatingModifier: String?
    var workspaceAutoBackAndForth: Bool = false
    var mouseFollowsFocus: Bool = false

    static func parse(_ raw: String, path: String = "") throws -> I3Config {
        var cfg = I3Config()
        cfg.rawText = raw
        cfg.sourcePath = path
        let parser = I3ConfigParser(text: raw)
        try parser.run(into: &cfg)
        return cfg
    }

    static func load(path: String) throws -> I3Config {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(raw, path: path)
    }
}

enum I3ConfigError: Error, CustomStringConvertible {
    case malformed(String, line: Int)
    case unmatchedBrace(line: Int)

    var description: String {
        switch self {
        case .malformed(let s, let line): return "config:\(line): \(s)"
        case .unmatchedBrace(let line): return "config:\(line): unmatched brace"
        }
    }
}

private final class I3ConfigParser {
    let lines: [String]
    var i: Int = 0
    var lineNo: Int { i + 1 }

    init(text: String) {
        self.lines = text.components(separatedBy: "\n")
    }

    func run(into cfg: inout I3Config) throws {
        i = 0
        while i < lines.count {
            let line = trim(lines[i])
            if line.isEmpty || line.hasPrefix("#") { i += 1; continue }
            try handleLine(line, into: &cfg)
            i += 1
        }
    }

    private func trim(_ s: String) -> String {
        var t = s
        while let last = t.last, last == " " || last == "\t" { t.removeLast() }
        while let first = t.first, first == " " || first == "\t" { t.removeFirst() }
        return t
    }

    private func substituteVars(_ s: String, vars: [String: String]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "$" {
                var j = s.index(after: i)
                var name = ""
                while j < s.endIndex {
                    let c = s[j]
                    if c.isLetter || c.isNumber || c == "_" { name.append(c); j = s.index(after: j) }
                    else { break }
                }
                if !name.isEmpty, let v = vars[name] { out.append(v); i = j; continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private func handleLine(_ rawLine: String, into cfg: inout I3Config) throws {
        var line = rawLine
        if let hash = findUnquotedHash(line) { line = trim(String(line[..<hash])) }
        if line.isEmpty { return }
        if line.hasPrefix("set ") || line.hasPrefix("set\t") {
            try handleSet(line, into: &cfg)
            return
        }
        line = substituteVars(line, vars: cfg.variables)
        let tokens = tokenize(line)
        guard let first = tokens.first else { return }
        switch first {
        case "exec":
            cfg.execs.append((once: true, command: extractExecCommand(tokens)))
        case "exec_always":
            cfg.execs.append((once: false, command: extractExecCommand(tokens)))
        case "bindsym":
            if let b = parseBindsym(tokens) { cfg.bindings.append(b) }
        case "for_window":
            if let r = parseForWindow(line) { cfg.forWindow.append(r) }
        case "font":
            cfg.fontPango = extractAfter(line, prefix: "font").trimmingCharacters(in: .whitespaces)
        case "default_border":
            cfg.defaultBorder = tokens.count > 1 ? tokens[1] : "normal"
        case "smart_gaps":
            cfg.smartGaps = (tokens.count > 1 && tokens[1] == "on")
        case "gaps":
            try parseGaps(tokens, into: &cfg)
        case "focus_on_window_activation":
            cfg.focusOnWindowActivation = tokens.count > 1 ? tokens[1] : "smart"
        case "floating_modifier":
            cfg.floatingModifier = tokens.count > 1 ? tokens[1] : nil
        case "workspace_auto_back_and_forth":
            cfg.workspaceAutoBackAndForth = (tokens.count > 1 && (tokens[1] == "yes" || tokens[1] == "true"))
        case "mouse_follows_focus":
            cfg.mouseFollowsFocus = (tokens.count > 1 && (tokens[1] == "yes" || tokens[1] == "true" || tokens[1] == "on"))
        case "mouse_warping":
            cfg.mouseFollowsFocus = (tokens.count > 1 && tokens[1] == "focus")
        case "mode":
            try handleModeBlock(tokens: tokens, into: &cfg)
        case "bar":
            try handleBarBlock(tokens: tokens, into: &cfg)
        case "client.background":
            if tokens.count > 1 { cfg.clientBackground = tokens[1] }
        default:
            if first.hasPrefix("client.") {
                let key = String(first.dropFirst("client.".count))
                let cols = Array(tokens.dropFirst())
                guard cols.count >= 3 else { return }
                cfg.clientColors[key] = ClientColors(
                    border: cols[0],
                    background: cols[1],
                    text: cols[2],
                    indicator: cols.count > 3 ? cols[3] : nil,
                    childBorder: cols.count > 4 ? cols[4] : nil
                )
            }
        }
    }

    private func handleSet(_ line: String, into cfg: inout I3Config) throws {
        let after = line.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" })
        guard after.hasPrefix("$") else { throw I3ConfigError.malformed("set: expected $name", line: lineNo) }
        let rest = after.dropFirst()
        var name = ""
        var idx = rest.startIndex
        while idx < rest.endIndex {
            let c = rest[idx]
            if c.isLetter || c.isNumber || c == "_" { name.append(c); idx = rest.index(after: idx) }
            else { break }
        }
        let value = String(rest[idx...]).trimmingCharacters(in: .whitespaces)
        cfg.variables[name] = substituteVars(value, vars: cfg.variables)
    }

    private func handleModeBlock(tokens: [String], into cfg: inout I3Config) throws {
        guard tokens.count >= 3 else { throw I3ConfigError.malformed("mode: missing name/brace", line: lineNo) }
        let name = stripQuotes(tokens[1])
        var mode = ModeDef(name: name, bindings: [])
        i += 1
        while i < lines.count {
            let lt = trim(lines[i])
            if lt.isEmpty || lt.hasPrefix("#") { i += 1; continue }
            if lt == "}" { cfg.modes.append(mode); return }
            let substituted = substituteVars(lt, vars: cfg.variables)
            let toks = tokenize(substituted)
            if toks.first == "bindsym", let b = parseBindsym(toks) {
                mode.bindings.append(b)
            }
            i += 1
        }
        throw I3ConfigError.unmatchedBrace(line: lineNo)
    }

    private func handleBarBlock(tokens: [String], into cfg: inout I3Config) throws {
        i += 1
        while i < lines.count {
            let lt = trim(lines[i])
            if lt.isEmpty || lt.hasPrefix("#") { i += 1; continue }
            if lt == "}" { return }
            let substituted = substituteVars(lt, vars: cfg.variables)
            let toks = tokenize(substituted)
            switch toks.first ?? "" {
            case "status_command":
                cfg.bar.statusCommand = extractAfter(substituted, prefix: "status_command").trimmingCharacters(in: .whitespaces)
            case "workspace_min_width":
                cfg.bar.workspaceMinWidth = Int(toks.dropFirst().first ?? "0") ?? 0
            case "tray_padding":
                cfg.bar.trayPadding = Int(toks.dropFirst().first ?? "0") ?? 0
            case "position":
                cfg.bar.position = toks.count > 1 ? toks[1] : "top"
            case "colors":
                try handleBarColorsBlock(into: &cfg)
            default: break
            }
            i += 1
        }
        throw I3ConfigError.unmatchedBrace(line: lineNo)
    }

    private func handleBarColorsBlock(into cfg: inout I3Config) throws {
        i += 1
        while i < lines.count {
            let lt = trim(lines[i])
            if lt.isEmpty || lt.hasPrefix("#") { i += 1; continue }
            if lt == "}" { return }
            let toks = tokenize(lt)
            guard let key = toks.first else { i += 1; continue }
            let rest = Array(toks.dropFirst())
            switch key {
            case "background": cfg.bar.colors.background = rest.first
            case "statusline": cfg.bar.colors.statusline = rest.first
            case "separator": cfg.bar.colors.separator = rest.first
            case "focused_workspace": cfg.bar.colors.focusedWorkspace = rest
            case "active_workspace": cfg.bar.colors.activeWorkspace = rest
            case "inactive_workspace": cfg.bar.colors.inactiveWorkspace = rest
            case "urgent_workspace": cfg.bar.colors.urgentWorkspace = rest
            case "binding_mode": cfg.bar.colors.bindingMode = rest
            default: break
            }
            i += 1
        }
        throw I3ConfigError.unmatchedBrace(line: lineNo)
    }

    private func parseBindsym(_ toks: [String]) -> Keybinding? {
        var t = toks
        t.removeFirst()
        var release = false
        while let first = t.first, first.hasPrefix("--") {
            if first == "--release" { release = true }
            t.removeFirst()
        }
        guard let key = t.first else { return nil }
        let cmd = t.dropFirst().joined(separator: " ")
        return Keybinding(keyspec: key, commandText: cmd, release: release)
    }

    private func parseGaps(_ toks: [String], into cfg: inout I3Config) throws {
        guard toks.count >= 3 else { return }
        let kind = toks[1]
        if toks[2] == "current" {
            return
        }
        if let n = Double(toks[2]) {
            if kind == "inner" { cfg.innerGap = CGFloat(n) }
            else if kind == "outer" { cfg.outerGap = CGFloat(n) }
        }
    }

    private func parseForWindow(_ line: String) -> ForWindowRule? {
        let after = extractAfter(line, prefix: "for_window")
        guard let openIdx = after.firstIndex(of: "[") else { return nil }
        guard let closeIdx = after[openIdx...].firstIndex(of: "]") else { return nil }
        let inside = String(after[after.index(after: openIdx)..<closeIdx])
        let cmd = String(after[after.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        var dict: [String: String] = [:]
        let parts = parseCriteria(inside)
        for (k, v) in parts { dict[k] = v }
        return ForWindowRule(criteria: dict, command: cmd)
    }

    private func parseCriteria(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
            if i == s.endIndex { break }
            var key = ""
            while i < s.endIndex, s[i] != "=" && s[i] != " " && s[i] != "\t" {
                key.append(s[i]); i = s.index(after: i)
            }
            if i < s.endIndex, s[i] == "=" { i = s.index(after: i) }
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" { value.append(s[i]); i = s.index(after: i) }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                while i < s.endIndex, s[i] != " " && s[i] != "\t" {
                    value.append(s[i]); i = s.index(after: i)
                }
            }
            out.append((key, value))
        }
        return out
    }

    private func extractExecCommand(_ tokens: [String]) -> String {
        var t = tokens
        t.removeFirst()
        while let first = t.first, first.hasPrefix("--") { t.removeFirst() }
        if t.count == 1 { return stripQuotes(t[0]) }
        return t.map { stripQuotes($0) }.joined(separator: " ")
    }

    private func extractAfter(_ line: String, prefix: String) -> String {
        guard let r = line.range(of: prefix) else { return "" }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private func findUnquotedHash(_ s: String) -> String.Index? {
        var inSingle = false, inDouble = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"", !inSingle { inDouble.toggle() }
            else if c == "'", !inDouble { inSingle.toggle() }
            else if c == "#", !inSingle, !inDouble { return i }
            i = s.index(after: i)
        }
        return nil
    }

    private func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSingle = false, inDouble = false, inBracket = 0
        for c in s {
            if c == "\"", !inSingle, inBracket == 0 { inDouble.toggle(); cur.append(c); continue }
            if c == "'", !inDouble, inBracket == 0 { inSingle.toggle(); cur.append(c); continue }
            if c == "[", !inSingle, !inDouble { inBracket += 1; cur.append(c); continue }
            if c == "]", !inSingle, !inDouble { inBracket = max(0, inBracket - 1); cur.append(c); continue }
            if c == "{", !inSingle, !inDouble, inBracket == 0 {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append("{")
                continue
            }
            if c == "}", !inSingle, !inDouble, inBracket == 0 {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append("}")
                continue
            }
            if (c == " " || c == "\t"), !inSingle, !inDouble, inBracket == 0 {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func stripQuotes(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2) || (s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
