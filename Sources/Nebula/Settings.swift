import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

extension Shortcut {
    /// ⌥⌘V: Eco (last copied items).
    static let pasteDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey), key: "V")
    /// ⌥ Space: Pulsar (edit the selected files).
    static let pulsarDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Spazio")
    /// ⌥⌫: Buco nero (expire / clean).
    static let blackHoleDefault = Shortcut(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey), key: "⌫")
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
    @Published var pulsarShortcut: Shortcut {
        didSet { Self.store(pulsarShortcut, "pulsarShortcut") }
    }
    @Published var blackHoleShortcut: Shortcut {
        didSet { Self.store(blackHoleShortcut, "blackHoleShortcut") }
    }

    private static func store(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load(_ key: String, _ fallback: Shortcut) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }
        return saved
    }

    /// True while the recorder is listening (shortcuts are paused).
    @Published var recording = false

    private init() {
        let d = UserDefaults.standard
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .option
        clipboardOutsideFinder = d.object(forKey: "clipboardOutsideFinder") as? Bool ?? true
        pasteShortcut = Self.load("pasteShortcut", .pasteDefault)
        pulsarShortcut = Self.load("pulsarShortcut", .pulsarDefault)
        blackHoleShortcut = Self.load("blackHoleShortcut", .blackHoleDefault)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = Accessibility.isTrusted
    @AppStorage("adaptive") private var adaptive = true
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Tasto della nebula", selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Text("Tieni premuto il tasto da solo. Con un file selezionato nel Finder la Nebula compare subito; altrove parte un caricatore di 1,5 s (premi due volte per dimezzarlo) e la Nebula lavora su ciò che hai copiato: il risultato finisce in Eco. Punta e rilascia, oppure dai uno strattone deciso dal centro. Clic al centro = copia il file. ⌘Z annulla subito l'ultima azione. Se usi il tasto insieme ad altri, funziona come sempre.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Fuori dal Finder usa gli appunti", isOn: $settings.clipboardOutsideFinder)
            }
            Section {
                LabeledContent("Pulsar · modifica") {
                    ShortcutRecorder(shortcut: $settings.pulsarShortcut, fallback: .pulsarDefault, settings: settings)
                }
                LabeledContent("Buco nero · scadenza e pulizia") {
                    ShortcutRecorder(shortcut: $settings.blackHoleShortcut, fallback: .blackHoleDefault, settings: settings)
                }
                Text("Attive solo nel Finder con file selezionati, e mai mentre rinomini un file. Pulsar: Mini, unire, svuotare o proteggere PDF, tagliare o rendere muti i video, scontornare, estrarre testo, oscurare volti e targhe, raggruppare e rinominare il contenuto delle cartelle. Buco nero: scadenza a 1, 7 o 30 giorni (poi il file va nel Cestino) e pulizia di GPS e metadati.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Eco · ultimi copiati") {
                    ShortcutRecorder(shortcut: $settings.pasteShortcut, fallback: .pasteDefault, settings: settings)
                }
                Text("Tienila premuta per scegliere tra le ultime 3 cose copiate (e i file convertiti dagli appunti); rilascia per incollare. Nel Finder ⌥⌘V serve anche a spostare i file: se ti serve, scegli un'altra combinazione.")
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
                Toggle("Adatta la nebula alle mie abitudini", isOn: $adaptive)
                Text("I formati che usi di più per ogni tipo di file salgono piano piano verso l'alto (sempre negli stessi punti, per ritrovarli a memoria), il preferito ha un pallino, l'interruttore Mini viene ricordato e lo strattone si calibra sulla tua velocità.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Azzera le abitudini") { Habits.shared.reset() }
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
