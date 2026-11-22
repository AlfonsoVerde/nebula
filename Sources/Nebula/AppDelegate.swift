import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private let nebula = NebulaController()
    private let settings = AppSettings.shared
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        // Finder → right click → Services / Quick Actions → "Converti con Nebula"
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Hold the shortcut → nebula appears; release → convert to the pointed format.
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
        hotKey.onRelease = { [weak self] in self?.nebula.release() }

        Publishers.CombineLatest3(settings.$shortcut, settings.$finderOnly, settings.$recording)
            .sink { [weak self] shortcut, finderOnly, recording in
                self?.updateHotKey(shortcut: shortcut, finderOnly: finderOnly, recording: recording)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHotKey() }
        }

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openSettings()
        }
    }

    /// Files dropped on the app icon or opened with "Apri con".
    func application(_ application: NSApplication, open urls: [URL]) {
        nebula.present(urls: urls, at: NSEvent.mouseLocation, holding: false)
    }

    // MARK: - Hotkey

    private func refreshHotKey() {
        updateHotKey(shortcut: settings.shortcut, finderOnly: settings.finderOnly, recording: settings.recording)
    }

    /// With "solo nel Finder" the shortcut is registered only while Finder is in front,
    /// so ⌥Space keeps working normally in every other app.
    private func updateHotKey(shortcut: Shortcut, finderOnly: Bool, recording: Bool) {
        let active = !recording && (!finderOnly || FinderBridge.finderIsFrontmost)
        if active { hotKey.register(shortcut) } else { hotKey.unregister() }
    }

    private func shortcutPressed() {
        if nebula.isVisible {
            nebula.dismiss()
            return
        }
        let urls = FinderBridge.selection()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        nebula.present(urls: urls, at: NSEvent.mouseLocation, holding: true)
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
        nebula.present(urls: panel.urls, at: center, holding: false)
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
        nebula.present(urls: urls, at: NSEvent.mouseLocation, holding: false)
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Nebula")

        let menu = NSMenu()
        menu.addItem(item("Apri file…", #selector(openPanel), key: "o"))
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
