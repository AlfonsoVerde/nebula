import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let trigger = TriggerMonitor()
    private let pasteKey = HotKey()
    private let pulsarKey = HotKey()
    private let blackHoleKey = HotKey()
    private let panels = ToolPanelController()
    private var lastTriggerUp: CFTimeInterval = 0
    private let nebula = NebulaController()
    private let loader = PointerLoader()
    private var history: ClipboardHistory { ClipboardHistory.shared }
    private let settings = AppSettings.shared
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pendingShow: Task<Void, Never>?

    static let loaderDuration = 1.5
    /// Tiny grace before showing in Finder, so ⌥+key combos and ⌥-clicks don't flash the nebula.
    static let finderGrace: UInt64 = 120_000_000

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        history.start()
        ExpiryStore.shared.start()
        nebula.onPaste = { [weak self] entry in self?.history.paste(entry) }
        nebula.onPanel = { [weak self] tool, files in self?.panels.open(tool, files: files) }

        trigger.onPress = { [weak self] in self?.triggerDown() }
        trigger.onRelease = { [weak self] in self?.triggerUp() }
        trigger.onInterrupt = { [weak self] in self?.triggerInterrupted() }
        trigger.onFlags = { [weak self] flags in self?.flagsChanged(flags) }
        trigger.start()
        settings.$trigger
            .sink { [weak self] key in self?.trigger.key = key }
            .store(in: &cancellables)

        pasteKey.onPress = { [weak self] in self?.showEco() }
        Publishers.CombineLatest3(settings.$pasteShortcut, settings.$recording, settings.$ecoOn)
            .sink { [weak self] shortcut, recording, on in
                if recording || !on { self?.pasteKey.unregister() } else { self?.pasteKey.register(shortcut) }
            }
            .store(in: &cancellables)

        pulsarKey.onPress = { [weak self] in self?.showTools(.pulsar) }
        blackHoleKey.onPress = { [weak self] in self?.showTools(.blackHole) }
        // @Published fires before the value is stored: read the settings on the next turn.
        Publishers.Merge4(settings.$pulsarShortcut.map { _ in () }, settings.$blackHoleShortcut.map { _ in () },
                          settings.$recording.map { _ in () },
                          settings.$pulsarOn.combineLatest(settings.$blackHoleOn).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshFinderKeys() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFinderKeys() }
        }

        if !Accessibility.isTrusted { Accessibility.prompt() }
        _ = UndoCenter.shared
        if !UserDefaults.standard.bool(forKey: "launchedV6") {
            UserDefaults.standard.set(true, forKey: "launchedV6")
            openSettings()
        }
    }

    /// Files dropped on the app icon or opened with "Apri con".
    func application(_ application: NSApplication, open urls: [URL]) {
        nebula.present(files: urls, fromClipboard: false, at: NSEvent.mouseLocation, holding: false)
    }

    // MARK: - Trigger key

    private func triggerDown() {
        guard settings.nebulaOn, !settings.recording, !nebula.isVisible, !loader.isActive, NSEvent.pressedMouseButtons == 0 else { return }

        // Finder with a selection → nebula right away.
        if FinderBridge.finderIsFrontmost {
            let urls = FinderBridge.selection()
            if !urls.isEmpty {
                pendingShow = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.finderGrace)
                    guard !Task.isCancelled, let self, NSEvent.pressedMouseButtons == 0 else { return }
                    self.nebula.present(files: urls, fromClipboard: false, at: NSEvent.mouseLocation, holding: true)
                }
                return
            }
        }

        // Anywhere else → loader around the pointer, then the clipboard.
        // Pressing ⌥ twice in a row runs the loader at double speed.
        guard settings.clipboardOutsideFinder else { return }
        let doubleTap = CACurrentMediaTime() - lastTriggerUp < 0.4
        loader.start(duration: doubleTap ? Self.loaderDuration / 2 : Self.loaderDuration) { [weak self] in
            self?.showClipboardNebula()
        }
    }

    private func showClipboardNebula() {
        guard let source = ClipboardSource.materialize() else {
            NSSound.beep()
            return
        }
        nebula.present(files: source.urls, fromClipboard: source.temporary, at: NSEvent.mouseLocation, holding: true)
    }

    private func triggerUp() {
        lastTriggerUp = CACurrentMediaTime()
        pendingShow?.cancel()
        loader.cancel()
        if nebula.kind == .nebula { nebula.release() }
    }

    private func triggerInterrupted() {
        pendingShow?.cancel()
        loader.cancel()
        if nebula.kind == .nebula { nebula.cancelHold() }
    }

    /// Eco lives while ⌥ and ⌘ are held; Pulsar and Buco nero while ⌥ is held.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard nebula.isVisible, nebula.isHolding else { return }
        switch nebula.kind {
        case .eco:
            if !flags.contains(.option) || !flags.contains(.command) { nebula.release() }
        case .pulsar, .blackHole:
            if !flags.contains(.option) { nebula.release() }
        default:
            break
        }
    }

    private func showEco() {
        guard !settings.recording else { return }
        pendingShow?.cancel()
        loader.cancel()
        guard !history.entries.isEmpty else {
            NSSound.beep()
            return
        }
        nebula.presentEco(history.entries, at: NSEvent.mouseLocation, holding: true)
    }

    // MARK: - Pulsar & Buco nero (Finder only)

    private func refreshFinderKeys() {
        let active = !settings.recording && FinderBridge.finderIsFrontmost
        if active && settings.pulsarOn { pulsarKey.register(settings.pulsarShortcut) } else { pulsarKey.unregister() }
        if active && settings.blackHoleOn { blackHoleKey.register(settings.blackHoleShortcut) } else { blackHoleKey.unregister() }
    }

    private func showTools(_ kind: NebulaModel.Kind) {
        let key = kind == .pulsar ? pulsarKey : blackHoleKey
        let shortcut = kind == .pulsar ? settings.pulsarShortcut : settings.blackHoleShortcut
        // Renaming a file or typing in the search field: give the keystroke back.
        if FinderBridge.isEditingText {
            passThrough(key, shortcut)
            return
        }
        let urls = FinderBridge.selection()
        guard !urls.isEmpty else {
            passThrough(key, shortcut)
            return
        }
        pendingShow?.cancel()
        loader.cancel()
        nebula.close()
        let tools = kind == .pulsar ? ToolCatalog.pulsar(for: urls) : ToolCatalog.blackHole(for: urls)
        let holding = NSEvent.modifierFlags.contains(.option)
        nebula.presentTools(tools, files: urls, kind: kind, at: NSEvent.mouseLocation, holding: holding)
    }

    /// Re-sends a keystroke that a Nebula shortcut caught but didn't need.
    private func passThrough(_ key: HotKey, _ shortcut: Shortcut) {
        key.unregister()
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []
        if shortcut.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if shortcut.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.refreshFinderKeys()
        }
    }

    // MARK: - Actions

    @objc func openPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = tr("Scegli i file da convertire")
        panel.prompt = tr("Converti")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let center = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        nebula.present(files: panel.urls, fromClipboard: false, at: center, holding: false)
    }

    @objc func undoLast() {
        UndoCenter.shared.undo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(undoLast) ? UndoCenter.shared.canUndo : true
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(rootView: SettingsView())
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 540, height: 720)),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tr("Impostazioni di Nebula")
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Services entry point (NSMessage = convertFiles in Info.plist).
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        nebula.present(files: urls, fromClipboard: false, at: NSEvent.mouseLocation, holding: false)
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Nebula")

        let menu = NSMenu()
        menu.addItem(item(tr("Apri file…"), #selector(openPanel), key: "o"))
        menu.addItem(item(tr("Annulla ultima azione di Nebula"), #selector(undoLast), key: "z"))
        menu.addItem(item(tr("Impostazioni…"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item(tr("Esci da Nebula"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }
}
