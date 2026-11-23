import AppKit
import AVFoundation
import SwiftUI

/// Small dark-glass panels that open after a Pulsar choice needing input.
@MainActor
final class ToolPanelController {
    private var panel: NebulaPanel?

    func open(_ tool: Tool, files: [URL]) {
        close()
        let view: AnyView
        switch tool {
        case .pdfLock:
            view = AnyView(PasswordView(onDone: { [weak self] password in
                self?.close()
                guard let password else { return }
                Self.run(message: "Protetto") {
                    let out = try ToolRunner.lockPDF(files[0], password: password)
                    return .files([out], restoring: nil)
                }
            }))
        case .renameCustom:
            view = AnyView(RenameView(folders: files, onDone: { [weak self] base, start in
                self?.close()
                guard let base else { return }
                Self.run(message: "Rinominati") {
                    .moves(try ToolRunner.rename(files, base: base, start: start, byDate: false), created: [])
                }
            }))
        case .trim:
            view = AnyView(TrimView(file: files[0], onDone: { [weak self] range in
                self?.close()
                guard let range else { return }
                Task { @MainActor in
                    do {
                        let out = try await ToolRunner.trim(files[0], from: range.lowerBound, to: range.upperBound) { _ in }
                        UndoCenter.shared.register(.files([out], restoring: nil))
                        Toast.show("Tagliato · ⌘Z annulla", symbol: "scissors")
                    } catch {
                        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
                    }
                }
            }))
        default:
            return
        }

        let host = NSHostingView(rootView: PanelChrome { view })
        let size = host.fittingSize
        let p = NSEvent.mouseLocation
        let panel = NebulaPanel(contentRect: NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                                    width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.configure()
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = host
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func run(message: String, _ work: @escaping () throws -> UndoCenter.Action) {
        do {
            UndoCenter.shared.register(try work())
            Toast.show("\(message) · ⌘Z annulla", symbol: "checkmark")
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }
}

struct PanelChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
            .environment(\.colorScheme, .dark)
            .padding(12)
    }
}

private struct PanelButtons: View {
    let confirm: String
    let enabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Button("Annulla", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(confirm, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
        }
        .controlSize(.large)
    }
}

struct PasswordView: View {
    let onDone: (String?) -> Void
    @State private var password = ""
    @State private var repeated = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Proteggi con password", systemImage: "lock")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            SecureField("Password", text: $password)
            SecureField("Ripeti la password", text: $repeated)
            if !repeated.isEmpty && repeated != password {
                Text("Le password non coincidono").font(.caption).foregroundStyle(.orange)
            }
            PanelButtons(confirm: "Proteggi", enabled: !password.isEmpty && password == repeated,
                         onCancel: { onDone(nil) }, onConfirm: { onDone(password) })
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct RenameView: View {
    let folders: [URL]
    let onDone: (String?, Int) -> Void
    @State private var base = ""
    @State private var start = 1

    private var example: String {
        let name = base.isEmpty ? "Nome" : base
        return "\(name) \(String(format: "%03d", start)).jpg, \(name) \(String(format: "%03d", start + 1)).jpg…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rinomina i file della cartella", systemImage: "character.cursor.ibeam")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            TextField("Nome", text: $base)
                .textFieldStyle(.roundedBorder)
            Stepper("Parti da \(start)", value: $start, in: 0...9999)
            Text(example)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            PanelButtons(confirm: "Rinomina", enabled: !base.trimmingCharacters(in: .whitespaces).isEmpty,
                         onCancel: { onDone(nil, start) },
                         onConfirm: { onDone(base.trimmingCharacters(in: .whitespaces), start) })
        }
        .onAppear { base = folders.first?.lastPathComponent ?? "" }
    }
}

/// Filmstrip with two handles to choose the part to keep.
struct TrimView: View {
    let file: URL
    let onDone: (ClosedRange<Double>?) -> Void

    @State private var duration: Double = 0
    @State private var thumbnails: [NSImage] = []
    @State private var lower: Double = 0
    @State private var upper: Double = 1

    private let width: CGFloat = 304
    private let height: CGFloat = 46

    private func time(_ fraction: Double) -> String {
        let t = fraction * duration
        return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Taglia", systemImage: "scissors")
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        LinearGradient(colors: [Color(hue: 0.52, saturation: 0.5, brightness: 0.5),
                                                Color(hue: 0.75, saturation: 0.5, brightness: 0.45)],
                                       startPoint: .leading, endPoint: .trailing)
                    } else {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(nsImage: thumbnails[i])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(thumbnails.count), height: height)
                                .clipped()
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Dim the parts that will be cut.
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: width * lower, height: height)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: width * (1 - upper), height: height)
                    .offset(x: width * upper)

                // Selected range outline.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 2.5)
                    .frame(width: max(width * (upper - lower), 8), height: height)
                    .offset(x: width * lower)
                    .allowsHitTesting(false)

                handle(isLower: true)
                handle(isLower: false)
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "strip")

            HStack {
                Text(time(lower))
                Spacer()
                Text("durata \(time(upper - lower))").foregroundStyle(.secondary)
                Spacer()
                Text(time(upper))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())

            PanelButtons(confirm: "Taglia", enabled: duration > 0 && upper - lower > 0.01,
                         onCancel: { onDone(nil) },
                         onConfirm: { onDone((lower * duration)...(upper * duration)) })
        }
        .task { await load() }
    }

    private func handle(isLower: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 8, height: height + 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: width * (isLower ? lower : upper) - 4)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                let x = min(max(value.location.x / width, 0), 1)
                if isLower { lower = min(x, upper - 0.01) } else { upper = max(x, lower + 0.01) }
            })
    }

    private func load() async {
        let asset = AVURLAsset(url: file)
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        guard FileInspector.kind(of: file) == .video else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        var images: [NSImage] = []
        for i in 0..<8 {
            let t = CMTime(seconds: seconds * (Double(i) + 0.5) / 8, preferredTimescale: 600)
            if let frame = try? await generator.image(at: t) {
                images.append(NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height)))
            }
        }
        thumbnails = images
    }
}
