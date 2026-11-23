import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let trigger = TriggerMonitor()
    private let pasteKey = HotKey()
    private let nebula = NebulaController()
    private let loader = PointerLoader()
    private let history = ClipboardHistory()
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
        nebula.onPaste = { [weak self] entry in self?.history.paste(entry) }

        trigger.onPress = { [weak self] in self?.triggerDown() }
        trigger.onRelease = { [weak self] in self?.triggerUp() }
        trigger.onInterrupt = { [weak self] in self?.triggerInterrupted() }
        trigger.onFlags = { [weak self] flags in self?.flagsChanged(flags) }
        trigger.start()
        settings.$trigger
            .sink { [weak self] key in self?.trigger.key = key }
            .store(in: &cancellables)

        pasteKey.onPress = { [weak self] in self?.showPasteNebula() }
        Publishers.CombineLatest(settings.$pasteShortcut, settings.$recording)
            .sink { [weak self] shortcut, recording in
                if recording { self?.pasteKey.unregister() } else { self?.pasteKey.register(shortcut) }
            }
            .store(in: &cancellables)

        if !Accessibility.isTrusted { Accessibility.prompt() }
        _ = UndoCenter.shared
        if !UserDefaults.standard.bool(forKey: "launchedV4") {
            UserDefaults.standard.set(true, forKey: "launchedV4")
            openSettings()
        }
    }

    /// Files dropped on the app icon or opened with "Apri con".
    func application(_ application: NSApplication, open urls: [URL]) {
        nebula.present(files: urls, fromClipboard: false, at: NSEvent.mouseLocation, holding: false)
    }

    // MARK: - Trigger key

    private func triggerDown() {
        guard !settings.recording, !nebula.isVisible, !loader.isActive, NSEvent.pressedMouseButtons == 0 else { return }

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
        guard settings.clipboardOutsideFinder else { return }
        loader.start(duration: Self.loaderDuration) { [weak self] in
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
        pendingShow?.cancel()
        loader.cancel()
        if !nebula.isPasteMode { nebula.release() }
    }

    private func triggerInterrupted() {
        pendingShow?.cancel()
        loader.cancel()
        if !nebula.isPasteMode { nebula.cancelHold() }
    }

    /// Paste nebula: it lives while ⌥ and ⌘ are both held.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard nebula.isPasteMode else { return }
        if !flags.contains(.option) || !flags.contains(.command) { nebula.release() }
    }

    private func showPasteNebula() {
        guard !settings.recording else { return }
        pendingShow?.cancel()
        loader.cancel()
        guard !history.entries.isEmpty else {
            NSSound.beep()
            return
        }
        nebula.presentPaste(history.entries, at: NSEvent.mouseLocation, holding: true)
    }

    // MARK: - Actions

    @objc func openPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Scegli i file da convertire"
        panel.prompt = "Converti"
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
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Impostazioni di Nebula"
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
        menu.addItem(item("Apri file…", #selector(openPanel), key: "o"))
        menu.addItem(item("Annulla ultima azione di Nebula", #selector(undoLast), key: "z"))
        menu.addItem(item("Impostazioni…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Esci da Nebula", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }
}
