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

/// Polls the Finder selection and fires when it changes and settles.
@MainActor
final class SelectionWatcher {
    var onSelection: ([URL]) -> Void = { _ in }
    var isPaused: () -> Bool = { false }

    private var timer: Timer?
    private var last: [URL] = []
    private var candidate: [URL] = []
    private var stableTicks = 0

    func start() {
        stop()
        last = FinderBridge.finderIsFrontmost ? FinderBridge.selection() : []
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Treat these URLs as "already seen" (e.g. after revealing a converted file).
    func adopt(_ urls: [URL]) {
        last = urls
        candidate = []
        stableTicks = 0
    }

    private func tick() {
        guard FinderBridge.finderIsFrontmost,
              !isPaused(),
              NSEvent.pressedMouseButtons == 0 else { return }

        let selection = FinderBridge.selection()
        if selection == last {
            candidate = []
            stableTicks = 0
            return
        }
        if selection == candidate {
            stableTicks += 1
        } else {
            candidate = selection
            stableTicks = 0
        }
        // Wait for the selection to stay the same for one extra tick (~0.25 s)
        // so that arrowing quickly through files doesn't spam the ring.
        if stableTicks >= 1 {
            last = selection
            candidate = []
            if !selection.isEmpty { onSelection(selection) }
        }
    }
}
