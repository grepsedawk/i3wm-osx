import AppKit
import ApplicationServices
import Foundation

enum AX {
    static func ensureTrusted(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: [String: Any] = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard err == .success, let value = raw else { return nil }
        return value as? T
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let raw: AXValue = attribute(element, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(raw, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let raw: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw, .cgSize, &s) ? s : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = position(element), let s = size(element) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ p: CGPoint) -> Bool {
        var pt = p
        guard let value = AXValueCreate(.cgPoint, &pt) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ s: CGSize) -> Bool {
        var sz = s
        guard let value = AXValueCreate(.cgSize, &sz) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setFrame(_ element: AXUIElement, _ r: CGRect) -> Bool {
        // Position → size → position. Some apps (Brave, Slack, JetBrains)
        // won't accept a smaller size until they've been repositioned
        // (their internal layout recomputes against the new origin), and
        // others snap the origin to a slightly different pixel after
        // resizing — the second setPosition forces them back. Without
        // this dance, windows that refuse to shrink will visibly overlap
        // their neighbors after a move.
        setPosition(element, r.origin)
        setSize(element, r.size)
        setPosition(element, r.origin)
        return true
    }

    @discardableResult
    static func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    @discardableResult
    static func close(_ element: AXUIElement) -> Bool {
        if let button: AXUIElement = attribute(element, kAXCloseButtonAttribute) {
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
        return false
    }

    @discardableResult
    static func setMain(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    static func setFocused(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func subrole(_ element: AXUIElement) -> String? {
        attribute(element, kAXSubroleAttribute)
    }

    static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute)
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        let v: NSNumber? = attribute(element, kAXMinimizedAttribute)
        return v?.boolValue ?? false
    }

    @discardableResult
    static func setMinimized(_ element: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    @discardableResult
    static func setAppHidden(_ pid: pid_t, _ on: Bool) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    static func isAppHidden(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let v: NSNumber? = attribute(app, kAXHiddenAttribute)
        return v?.boolValue ?? false
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        let v: NSNumber? = attribute(element, "AXFullScreen")
        return v?.boolValue ?? false
    }

    @discardableResult
    static func setFullscreen(_ element: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, on as CFBoolean) == .success
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }
}

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

// SkyLight private APIs — reachable from any process on macOS 13+ without
// entitlements or scripting addition. Used to toggle window visibility
// without triggering the Dock minimize animation.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetWindowAlpha")
@discardableResult
func CGSSetWindowAlpha(_ cid: Int32, _ wid: UInt32, _ alpha: Float) -> Int32

enum CGS {
    static func setAlpha(_ wid: CGWindowID, _ alpha: Float) {
        CGSSetWindowAlpha(CGSMainConnectionID(), UInt32(wid), alpha)
    }
}
