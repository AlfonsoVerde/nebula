import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: "shortcut")
            }
        }
    }
    @Published var finderOnly: Bool {
        didSet { UserDefaults.standard.set(finderOnly, forKey: "finderOnly") }
    }
    /// True while the recorder is listening (the global hotkey is paused).
    @Published var recording = false

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "shortcut"),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .default
        }
        finderOnly = defaults.object(forKey: "finderOnly") as? Bool ?? true
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Scorciatoia") {
                    ShortcutRecorder(settings: settings)
                }
                Text("Seleziona uno o più file e tieni premuta la scorciatoia: compare la nebula. Muovi il puntatore verso un formato e rilascia. Se rilasci senza muoverti, la nebula resta aperta e puoi scegliere con un clic.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Attiva la scorciatoia solo nel Finder", isOn: $settings.finderOnly)
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
                LabeledContent("FFmpeg") {
                    Text(FFmpeg.path != nil ? "Installato · formati extra attivi" : "Non installato · brew install ffmpeg")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                settings.recording ? stop() : start()
            } label: {
                Text(settings.recording ? "Premi la combinazione…" : settings.shortcut.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 150)
            }
            .controlSize(.large)
            if settings.shortcut != .default {
                Button("Ripristina") { settings.shortcut = .default }
                    .buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        settings.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stop()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                settings.shortcut = shortcut
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        settings.recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
