import AppKit

/// Reads the current Finder selection through Apple Events.
enum FinderBridge {
    private static let script: NSAppleScript? = {
        let source = """
        tell application "Finder"
            set out to ""
            set sel to (get selection as alias list)
            repeat with f in sel
                set out to out & POSIX path of (f as alias) & linefeed
            end repeat
            return out
        end tell
        """
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }()

    static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    /// True while you're typing in the Finder (renaming a file, search field…).
    static var isEditingText: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.finder" else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let name = role as? String
        return name == kAXTextFieldRole as String || name == kAXTextAreaRole as String || name == "AXSearchField"
    }

    static func selection() -> [URL] {
        guard let script else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) }
    }
}
