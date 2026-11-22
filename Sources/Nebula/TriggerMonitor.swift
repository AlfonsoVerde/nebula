import AppKit

/// Which modifier opens the nebula when held on its own.
enum TriggerKey: String, CaseIterable, Codable, Identifiable {
    case option, rightOption, control, function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "⌥ Option"
        case .rightOption: "⌥ Option destro"
        case .control: "⌃ Control"
        case .function: "fn / 🌐"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option, .rightOption: .option
        case .control: .control
        case .function: .function
        }
    }

    /// `flags` must be the raw event flags (device-dependent bits tell left from right).
    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        default: flags.contains(flag)
        }
    }
}

/// Watches a lone modifier key system-wide.
/// - press: the modifier goes down with no other modifier held
/// - release: it goes up without anything else having happened in between
/// - interrupt: another key, another modifier or a mouse click while held → the
///   modifier is being used normally (⌥ò for @, ⌥-drag…), so the nebula backs off.
/// Needs the Accessibility permission (global key monitoring).
@MainActor
final class TriggerMonitor {
    var key: TriggerKey = .option
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onInterrupt: () -> Void = {}
    var onFlags: (NSEvent.ModifierFlags) -> Void = { _ in }

    private var isDown = false
    private var interrupted = false
    private var monitors: [Any] = []

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
            self?.handleFlags(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.handleOther()
        }) { monitors.append(m) }
        // Events delivered to Nebula's own windows don't reach global monitors.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
            self?.handleFlags(e)
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            self?.handleOther()
            return e
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleFlags(_ event: NSEvent) {
        let raw = event.modifierFlags
        onFlags(raw.intersection(.deviceIndependentFlagsMask))

        let held = key.isHeld(raw)
        let others = raw.intersection([.command, .control, .shift, .option, .function]).subtracting(key.flag)

        if held && !isDown {
            isDown = true
            interrupted = !others.isEmpty
            if !interrupted { onPress() }
        } else if held && isDown {
            if !others.isEmpty && !interrupted {
                interrupted = true
                onInterrupt()
            }
        } else if !held && isDown {
            isDown = false
            if !interrupted { onRelease() }
            interrupted = false
        }
    }

    private func handleOther() {
        guard isDown, !interrupted else { return }
        interrupted = true
        onInterrupt()
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
