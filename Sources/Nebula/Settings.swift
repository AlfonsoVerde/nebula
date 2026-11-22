import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

extension Shortcut {
    /// ⌥⌘V: last copied items.
    static let pasteDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey), key: "V")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var trigger: TriggerKey {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "trigger") }
    }
    @Published var clipboardOutsideFinder: Bool {
        didSet { UserDefaults.standard.set(clipboardOutsideFinder, forKey: "clipboardOutsideFinder") }
    }
    @Published var pasteShortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(pasteShortcut) {
                UserDefaults.standard.set(data, forKey: "pasteShortcut")
            }
        }
    }
    /// True while the recorder is listening (shortcuts are paused).
    @Published var recording = false

    private init() {
        let d = UserDefaults.standard
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .option
        clipboardOutsideFinder = d.object(forKey: "clipboardOutsideFinder") as? Bool ?? true
        if let data = d.data(forKey: "pasteShortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            pasteShortcut = saved
        } else {
            pasteShortcut = .pasteDefault
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = Accessibility.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Tasto della nebula", selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Text("Tieni premuto il tasto da solo. Con un file selezionato nel Finder la nebula compare subito; altrove parte un caricatore di 1,5 s e la nebula lavora su ciò che hai copiato. Punta un formato e rilascia, oppure dai uno strattone verso il formato. Clic al centro = Mini. Se usi il tasto insieme ad altri, funziona come sempre.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Fuori dal Finder usa gli appunti", isOn: $settings.clipboardOutsideFinder)
            }
            Section {
                LabeledContent("Ultimi copiati") {
                    ShortcutRecorder(shortcut: $settings.pasteShortcut, fallback: .pasteDefault, settings: settings)
                }
                Text("Tienila premuta per scegliere tra le ultime 3 cose copiate; rilascia per incollare. Nel Finder ⌥⌘V serve anche a spostare i file: se ti serve, scegli un'altra combinazione.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Accessibilità") {
                    if trusted {
                        Label("Concessa", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("Concedi…") { Accessibility.prompt(); Accessibility.openSettings() }
                            Button("Riavvia Nebula") { Accessibility.relaunch() }
                        }
                    }
                }
                if !trusted {
                    Text("Serve per accorgersi di quando tieni premuto il tasto e per incollare. Dopo averla concessa, riavvia Nebula. Ad ogni aggiornamento dell'app va riattivata.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Apri al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                LabeledContent("MarkItDown (AI.md)") {
                    Text(MarkItDown.isAvailable ? "Attivo" : "Convertitore nativo")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("FFmpeg") {
                    Text(FFmpeg.path != nil ? "Installato · formati extra attivi" : "Non installato · brew install ffmpeg")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onReceive(poll) { _ in trusted = Accessibility.isTrusted }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let fallback: Shortcut
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?
    @State private var listening = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                listening ? stop() : start()
            } label: {
                Text(listening ? "Premi la combinazione…" : shortcut.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 150)
            }
            .controlSize(.large)
            if shortcut != fallback {
                Button("Ripristina") { shortcut = fallback }
                    .buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        settings.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stop()
                return nil
            }
            if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        listening = false
        settings.recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
