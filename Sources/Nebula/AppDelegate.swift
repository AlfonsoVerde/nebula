import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let ring = RingController()
    private let watcher = SelectionWatcher()
    private var autoItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var autoShow: Bool {
        get { UserDefaults.standard.bool(forKey: "autoShow") }
        set { UserDefaults.standard.set(newValue, forKey: "autoShow") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        // Finder → right click → Services / Quick Actions → "Converti con Nebula"
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Global shortcut: ⌥Space summons the ring for the current Finder selection.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.summonFromFinder()
        }

        // Optional "automatic" mode: the ring appears as soon as you select a file.
        watcher.onSelection = { [weak self] urls in
            self?.ring.present(urls: urls, at: NSEvent.mouseLocation)
        }
        watcher.isPaused = { [weak self] in self?.ring.isVisible ?? false }
        ring.onReveal = { [weak self] urls in self?.watcher.adopt(urls) }
        if autoShow { watcher.start() }
    }

    /// Files dropped on the app icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        ring.present(urls: urls, at: NSEvent.mouseLocation)
    }

    // MARK: - Actions

    @objc func summonFromFinder() {
        let urls = FinderBridge.selection()
        guard !urls.isEmpty else {
            openPanel()
            return
        }
        ring.present(urls: urls, at: NSEvent.mouseLocation)
    }

    @objc func openPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Scegli i file da convertire"
        panel.prompt = "Converti"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let center = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        ring.present(urls: panel.urls, at: center)
    }

    @objc private func toggleAuto() {
        autoShow.toggle()
        autoItem.state = autoShow ? .on : .off
        if autoShow {
            _ = FinderBridge.selection() // triggers the Automation permission prompt once
            watcher.start()
        } else {
            watcher.stop()
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossibile modificare l'avvio automatico"
            alert.informativeText = "Sposta Nebula nella cartella Applicazioni e riprova.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    /// Services entry point (NSMessage = convertFiles in Info.plist).
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        ring.present(urls: urls, at: NSEvent.mouseLocation)
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Nebula")

        let menu = NSMenu()
        menu.addItem(item("Converti selezione del Finder", #selector(summonFromFinder), key: " ", mods: [.option]))
        menu.addItem(item("Apri file…", #selector(openPanel), key: "o"))
        menu.addItem(.separator())

        autoItem = item("Mostra la ghiera quando selezioni un file", #selector(toggleAuto))
        autoItem.state = autoShow ? .on : .off
        menu.addItem(autoItem)

        loginItem = item("Apri al login", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let ff = NSMenuItem(title: FFmpeg.path != nil ? "FFmpeg trovato: formati extra attivi" : "FFmpeg non installato (formati base)",
                            action: nil, keyEquivalent: "")
        menu.addItem(ff)
        menu.addItem(.separator())
        menu.addItem(item("Esci da Nebula", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target ?? self
        return item
    }
}
