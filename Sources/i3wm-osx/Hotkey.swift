import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct ParsedKey: Hashable {
    let keyCode: CGKeyCode
    let modifiers: UInt64
}

enum KeyMap {
    static let nameToCode: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "space": CGKeyCode(kVK_Space),
        "tab": CGKeyCode(kVK_Tab),
        "left": CGKeyCode(kVK_LeftArrow),
        "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow),
        "down": CGKeyCode(kVK_DownArrow),
        "minus": CGKeyCode(kVK_ANSI_Minus),
        "equal": CGKeyCode(kVK_ANSI_Equal), "plus": CGKeyCode(kVK_ANSI_Equal),
        "bracketleft": CGKeyCode(kVK_ANSI_LeftBracket),
        "bracketright": CGKeyCode(kVK_ANSI_RightBracket),
        "semicolon": CGKeyCode(kVK_ANSI_Semicolon),
        "comma": CGKeyCode(kVK_ANSI_Comma),
        "period": CGKeyCode(kVK_ANSI_Period),
        "slash": CGKeyCode(kVK_ANSI_Slash),
        "backslash": CGKeyCode(kVK_ANSI_Backslash),
        "grave": CGKeyCode(kVK_ANSI_Grave),
        "apostrophe": CGKeyCode(kVK_ANSI_Quote),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    private static func maskFor(_ name: String) -> UInt64? {
        switch name {
        case "command", "cmd": return UInt64(CGEventFlags.maskCommand.rawValue)
        case "option", "alt":  return UInt64(CGEventFlags.maskAlternate.rawValue)
        case "control", "ctrl": return UInt64(CGEventFlags.maskControl.rawValue)
        case "shift": return UInt64(CGEventFlags.maskShift.rawValue)
        default: return nil
        }
    }

    static let mod4Mask: UInt64 = {
        let env = ProcessInfo.processInfo.environment["I3WM_OSX_MOD4"]?.lowercased() ?? "option"
        return maskFor(env) ?? UInt64(CGEventFlags.maskAlternate.rawValue)
    }()
    static let mod1Mask: UInt64 = {
        let env = ProcessInfo.processInfo.environment["I3WM_OSX_MOD1"]?.lowercased() ?? "option"
        return maskFor(env) ?? UInt64(CGEventFlags.maskAlternate.rawValue)
    }()

    static func parse(_ keyspec: String) -> ParsedKey? {
        let parts = keyspec.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return nil }
        var mods: UInt64 = 0
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "mod4", "mod4+", "$mod4", "super", "win":
                mods |= mod4Mask
            case "mod1":
                mods |= mod1Mask
            case "option", "alt":
                mods |= UInt64(CGEventFlags.maskAlternate.rawValue)
            case "cmd", "command":
                mods |= UInt64(CGEventFlags.maskCommand.rawValue)
            case "control", "ctrl":
                mods |= UInt64(CGEventFlags.maskControl.rawValue)
            case "shift":
                mods |= UInt64(CGEventFlags.maskShift.rawValue)
            default: break
            }
        }
        if let code = nameToCode[last.lowercased()] {
            return ParsedKey(keyCode: code, modifiers: mods)
        }
        if last.hasPrefix("XF86") {
            return nil
        }
        return nil
    }
}

final class HotkeyManager {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [String: [ParsedKey: String]] = [:]
    private var commandHandler: ((String) -> Void)?
    private(set) var currentMode: String = "default"
    var isInstalled: Bool { tap != nil }

    func bind(commandHandler: @escaping (String) -> Void) {
        self.commandHandler = commandHandler
    }

    func apply(config: I3Config) {
        bindings = [:]
        var defaultMap: [ParsedKey: String] = [:]
        for kb in config.bindings {
            if let pk = KeyMap.parse(kb.keyspec) {
                defaultMap[pk] = kb.commandText
            } else {
                Logger.debug("hotkey: unsupported keyspec '\(kb.keyspec)'")
            }
        }
        bindings["default"] = defaultMap
        for mode in config.modes {
            var map: [ParsedKey: String] = [:]
            for kb in mode.bindings {
                if let pk = KeyMap.parse(kb.keyspec) { map[pk] = kb.commandText }
            }
            bindings[mode.name] = map
        }
    }

    func setMode(_ mode: String) { currentMode = mode }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = mgr.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if mgr.handle(event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: refcon
        ) else {
            Logger.warn("could not create event tap (need Accessibility + Input Monitoring permissions)")
            return
        }
        self.tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Logger.info("hotkey tap installed")
    }

    private func handle(event: CGEvent) -> Bool {
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let raw = UInt64(event.flags.rawValue)
        let interesting: UInt64 =
            UInt64(CGEventFlags.maskCommand.rawValue) |
            UInt64(CGEventFlags.maskAlternate.rawValue) |
            UInt64(CGEventFlags.maskControl.rawValue) |
            UInt64(CGEventFlags.maskShift.rawValue)
        let mods = raw & interesting
        let pk = ParsedKey(keyCode: kc, modifiers: mods)
        let map = bindings[currentMode] ?? [:]
        if let cmd = map[pk] {
            DispatchQueue.main.async { [weak self] in self?.commandHandler?(cmd) }
            return true
        }
        return false
    }
}
