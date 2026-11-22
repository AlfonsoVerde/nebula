import AppKit
import Carbon.HIToolbox

/// A user-configurable shortcut (Carbon key code + Carbon modifier mask).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// ⌥ Space: free by default on macOS, unused in Finder, easy to hold with one hand.
    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Spazio")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s.isEmpty ? key : "\(s) \(key)"
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Builds a shortcut from a key press in the recorder. Needs a modifier, unless it's an F-key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }

        let code = Int(event.keyCode)
        let fKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18"
        ]
        let special: [Int: String] = [
            kVK_Space: "Spazio", kVK_Return: "Invio", kVK_Tab: "Tab", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘"
        ]
        let isFKey = fKeys[code] != nil
        guard mods != 0 || isFKey else { return nil }
        let name = fKeys[code] ?? special[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(code), modifiers: mods, key: name)
    }
}

/// Global hotkey with press *and* release callbacks (Carbon RegisterEventHotKey).
final class HotKey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    private(set) var registered: Shortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed): hotKey.onPress()
            case UInt32(kEventHotKeyReleased): hotKey.onRelease()
            default: break
            }
            return noErr
        }, 2, &specs, me, &handlerRef)
    }

    func register(_ shortcut: Shortcut) {
        guard registered != shortcut else { return }
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4E42_554C), id: 1) // 'NBUL'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr { registered = shortcut }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
