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
