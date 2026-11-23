import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

extension Shortcut {
    /// ⌥⌘V: Eco (last copied items).
    static let pasteDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey), key: "V")
    /// ⌥ Space: Pulsar (edit the selected files).
    static let pulsarDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: tr("Spazio"))
    /// ⌥⌫: Buco nero (expire / clean).
    static let blackHoleDefault = Shortcut(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey), key: "⌫")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var trigger: TriggerKey { didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "trigger") } }
    @Published var clipboardOutsideFinder: Bool { didSet { UserDefaults.standard.set(clipboardOutsideFinder, forKey: "clipboardOutsideFinder") } }
    @Published var pasteShortcut: Shortcut { didSet { Self.store(pasteShortcut, "pasteShortcut") } }
    @Published var pulsarShortcut: Shortcut { didSet { Self.store(pulsarShortcut, "pulsarShortcut") } }
    @Published var blackHoleShortcut: Shortcut { didSet { Self.store(blackHoleShortcut, "blackHoleShortcut") } }

    /// Each function can be switched off.
    @Published var nebulaOn: Bool { didSet { UserDefaults.standard.set(nebulaOn, forKey: "nebulaOn") } }
    @Published var pulsarOn: Bool { didSet { UserDefaults.standard.set(pulsarOn, forKey: "pulsarOn") } }
    @Published var blackHoleOn: Bool { didSet { UserDefaults.standard.set(blackHoleOn, forKey: "blackHoleOn") } }
    @Published var ecoOn: Bool { didSet { UserDefaults.standard.set(ecoOn, forKey: "ecoOn") } }

    /// True while a recorder is listening (shortcuts are paused).
    @Published var recording = false

    private static func store(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load(_ key: String, _ fallback: Shortcut) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }
        return saved
    }

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private init() {
        trigger = TriggerKey(rawValue: UserDefaults.standard.string(forKey: "trigger") ?? "") ?? .option
        clipboardOutsideFinder = Self.flag("clipboardOutsideFinder")
        pasteShortcut = Self.load("pasteShortcut", .pasteDefault)
        pulsarShortcut = Self.load("pulsarShortcut", .pulsarDefault)
        blackHoleShortcut = Self.load("blackHoleShortcut", .blackHoleDefault)
        nebulaOn = Self.flag("nebulaOn")
        pulsarOn = Self.flag("pulsarOn")
        blackHoleOn = Self.flag("blackHoleOn")
        ecoOn = Self.flag("ecoOn")
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = Accessibility.isTrusted
    @AppStorage("adaptive") private var adaptive = true
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            FeatureSection(kind: .nebula, title: "Nebula", subtitle: tr("Converte"), isOn: $settings.nebulaOn,
                           text: tr("Tieni premuto il tasto: compare la Nebula con i formati possibili. Punta e rilascia per convertire, oppure dai uno strattone deciso dal centro. Clic al centro per copiare il file. Fuori dal Finder lavora su ciò che hai copiato (premi due volte per fare prima).")) {
                Picker(tr("Tasto"), selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Toggle(tr("Fuori dal Finder usa gli appunti"), isOn: $settings.clipboardOutsideFinder)
            }

            FeatureSection(kind: .pulsar, title: "Pulsar", subtitle: tr("Modifica"), isOn: $settings.pulsarOn,
                           text: tr("Con file selezionati nel Finder: Mini, unire, svuotare o proteggere PDF, tagliare e silenziare video, scontornare, estrarre testo, oscurare volti e targhe, raggruppare e rinominare il contenuto delle cartelle.")) {
                LabeledContent(tr("Scorciatoia")) {
                    ShortcutRecorder(shortcut: $settings.pulsarShortcut, fallback: .pulsarDefault, settings: settings)
                }
            }

            FeatureSection(kind: .blackHole, title: tr("Buco nero"), subtitle: tr("Scadenza e pulizia"), isOn: $settings.blackHoleOn,
                           text: tr("Dai una scadenza ai file (1, 7 o 30 giorni, poi vanno nel Cestino) oppure cancella GPS, metadati e cronologia.")) {
                LabeledContent(tr("Scorciatoia")) {
                    ShortcutRecorder(shortcut: $settings.blackHoleShortcut, fallback: .blackHoleDefault, settings: settings)
                }
            }

            FeatureSection(kind: .eco, title: tr("Eco"), subtitle: tr("Incolla"), isOn: $settings.ecoOn,
                           text: tr("Le ultime 3 cose copiate: la più recente è la più grande. Punta e rilascia per incollare. Nel Finder ⌥⌘V sposta anche i file: se ti serve, cambia combinazione.")) {
                LabeledContent(tr("Scorciatoia")) {
                    ShortcutRecorder(shortcut: $settings.pasteShortcut, fallback: .pasteDefault, settings: settings)
                }
            }

            Section(tr("Generale")) {
                LabeledContent(tr("Accessibilità")) {
                    if trusted {
                        Label(tr("Concessa"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button(tr("Concedi…")) { Accessibility.prompt(); Accessibility.openSettings() }
                            Button(tr("Riavvia Nebula")) { Accessibility.relaunch() }
                        }
                    }
                }
                if !trusted {
                    Text(tr("Serve per sentire i tasti e per incollare. Va riattivata dopo ogni aggiornamento."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle(tr("Apri al login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(tr("Adatta alle mie abitudini"), isOn: $adaptive)
                HStack {
                    Text(tr("Le opzioni che usi di più diventano più grandi e salgono verso l'alto."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Azzera")) { Habits.shared.reset() }
                }
                LabeledContent("MarkItDown (AI.md)") {
                    Text(MarkItDown.isAvailable ? tr("Attivo") : tr("Convertitore nativo")).foregroundStyle(.secondary)
                }
                LabeledContent("FFmpeg") {
                    Text(FFmpeg.path != nil ? tr("Installato") : tr("Non installato") + " · brew install ffmpeg")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .onReceive(poll) { _ in trusted = Accessibility.isTrusted }
    }
}

/// One function: name + switch, animated demo, short explanation, its controls.
struct FeatureSection<Controls: View>: View {
    let kind: NebulaModel.Kind
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let text: String
    @ViewBuilder let controls: Controls

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
            DemoView(kind: kind)
                .frame(height: 150)
                .opacity(isOn ? 1 : 0.35)
                .saturation(isOn ? 1 : 0)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls.disabled(!isOn)
        }
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
                Text(listening ? tr("Premi la combinazione…") : shortcut.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 130)
            }
            if shortcut != fallback {
                Button(tr("Ripristina")) { shortcut = fallback }
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

// MARK: - Animated demos

/// A looping mini-film of the gesture: key down → blob pops → pointer moves →
/// blob leans → key up → the option fires.
struct DemoView: View {
    let kind: NebulaModel.Kind

    struct Script {
        let keys: [String]
        let source: String
        let result: String
        let icons: [String]
        let chosen: Int
    }

    var script: Script {
        switch kind {
        case .nebula:
            Script(keys: ["⌥"], source: "doc.richtext", result: "doc.plaintext",
                   icons: ["text.alignleft", "photo", "sparkles", "doc.zipper", "doc.text.fill"], chosen: 0)
        case .pulsar:
            Script(keys: ["⌥", "␣"], source: "film", result: "scissors",
                   icons: ["scissors", "speaker.slash", "arrow.down.right.and.arrow.up.left"], chosen: 0)
        case .blackHole:
            Script(keys: ["⌥", "⌫"], source: "doc", result: "hourglass",
                   icons: ["hourglass.bottomhalf.filled", "hourglass", "hourglass.tophalf.filled", "sparkles"], chosen: 1)
        case .eco:
            Script(keys: ["⌥", "⌘", "V"], source: "doc.on.clipboard", result: "text.alignleft",
                   icons: ["text.alignleft", "photo", "doc"], chosen: 0)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            DemoFrame(kind: kind, script: script, t: timeline.date.timeIntervalSinceReferenceDate)
        }
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One frame of the demo at time `t`.
struct DemoFrame: View {
    let kind: NebulaModel.Kind
    let script: DemoView.Script
    let t: Double

    static let cycle = 4.4
    static let radius: CGFloat = 46

    private var p: Double { t.truncatingRemainder(dividingBy: Self.cycle) }
    private var pressed: Bool { p > 0.25 && p < 2.6 }
    private var shrink: CGFloat { Ease.out(Ease.clamp((p - 2.6) / 0.35)) }
    private var fade: CGFloat { 1 - Ease.clamp((p - 3.7) / 0.5) }
    private var travel: CGFloat { Ease.inOut(Ease.clamp((p - 0.9) / 0.8)) }
    private var blobScale: CGFloat {
        let pop = p < 0.25 ? 0 : Ease.back(Ease.clamp((p - 0.25) / 0.45))
        return pop * (1 - 0.5 * shrink) * fade
    }
    private var fired: Bool { p > 2.6 }
    private var showResult: Bool { p > 2.9 }

    private func angle(_ i: Int) -> CGFloat {
        -.pi / 2 + CGFloat(i) / CGFloat(script.icons.count) * 2 * .pi
    }

    private var bulge: CGVector {
        let a = angle(script.chosen)
        let strength = 0.22 * travel * (1 - shrink)
        return CGVector(dx: cos(a) * strength, dy: sin(a) * strength)
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width * 0.62, y: geo.size.height / 2)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                fileIcon.position(x: geo.size.width * 0.18, y: geo.size.height * 0.4)
                keys.position(x: geo.size.width * 0.18, y: geo.size.height * 0.78)
                blob
                    .frame(width: Self.radius * 3, height: Self.radius * 3)
                    .scaleEffect(max(blobScale, 0.001))
                    .opacity(blobScale > 0.01 ? 1 : 0)
                    .position(center)
                pointer(center: center)
            }
        }
    }

    private var fileIcon: some View {
        VStack(spacing: 4) {
            Image(systemName: showResult ? script.result : script.source)
                .font(.system(size: 26))
                .frame(height: 32)
            Text(showResult ? "✓" : " ")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color.white.opacity(0.85))
    }

    private var keys: some View {
        HStack(spacing: 4) {
            ForEach(script.keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 24, minHeight: 22)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(pressed ? 0.32 : 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.7))
                    .offset(y: pressed ? 1.5 : 0)
            }
        }
        .foregroundStyle(.white)
    }

    private var blob: some View {
        let shape = BlobShape(radius: Self.radius, bulge: bulge, t: t)
        let selected = travel > 0.35 && !fired
        return ZStack {
            shape.fill(Color.black.opacity(0.35))
            GalaxyFill(t: t, spin: t * 0.2, bulge: bulge, radius: Self.radius, theme: NebulaTheme.of(kind))
                .clipShape(shape)
            shape.stroke(Color.white.opacity(0.35), lineWidth: 0.7)
            ForEach(0..<script.icons.count, id: \.self) { i in
                option(i, selected: selected)
            }
            if fired {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(Double(shrink))
            }
        }
    }

    private func option(_ i: Int, selected: Bool) -> some View {
        let a = angle(i)
        let chosen = i == script.chosen
        let lean = 1 + 0.85 * BlobGeometry.factor(a, bulge: bulge)
        let ecoSizes: [CGFloat] = [1.15, 1.0, 0.86]
        let base: CGFloat = kind == .eco ? ecoSizes[min(i, 2)] : 1
        let active: CGFloat = chosen && fired ? 1 + shrink * 0.8 : (selected && chosen ? 1.18 : 1)
        let visible: Double = fired ? (chosen ? Double(1 - shrink) : 0) : 1
        return ZStack {
            Circle().fill(chosen && selected ? Color.white : Color.black.opacity(0.5))
            Image(systemName: script.icons[i])
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(chosen && selected ? Color.black : Color.white)
        }
        .frame(width: 18, height: 18)
        .scaleEffect(base * active)
        .opacity(visible)
        .offset(x: cos(a) * 31 * lean, y: sin(a) * 31 * lean)
    }

    private func pointer(center: CGPoint) -> some View {
        let a = angle(script.chosen)
        let reach = 46 * travel
        return Image(systemName: "cursorarrow")
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .position(x: center.x + cos(a) * reach + 4, y: center.y + sin(a) * reach + 7)
            .opacity(Double(fade))
    }
}

enum Ease {
    static func clamp(_ x: Double) -> CGFloat { CGFloat(min(max(x, 0), 1)) }
    static func out(_ x: CGFloat) -> CGFloat { 1 - (1 - x) * (1 - x) }
    static func inOut(_ x: CGFloat) -> CGFloat { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
    static func back(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
