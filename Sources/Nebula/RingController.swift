import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class RingModel: ObservableObject {
    enum Phase { case idle, converting, done, failed }

    @Published private(set) var phase: Phase = .idle
    @Published var hovered: ConversionTarget?
    @Published private(set) var chosen: ConversionTarget?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isClosing = false
    @Published private(set) var message = ""
    @Published private(set) var convertStart: Date?
    @Published private(set) var convertEnd: Date?

    let files: [URL]
    let targets: [ConversionTarget]
    let icon: NSImage
    let title: String
    let badge: String
    let start = Date()

    var onClose: () -> Void = {}
    var onReveal: ([URL]) -> Void = { _ in }
    private var outputs: [URL] = []

    init(files: [URL]) {
        self.files = files
        targets = ConversionCatalog.targets(for: files)
        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        if files.count == 1 {
            title = files[0].lastPathComponent
            let ext = files[0].pathExtension.uppercased()
            badge = ext.isEmpty ? FileInspector.kind(of: files[0]).label.uppercased() : ext
        } else {
            title = "\(files.count) file selezionati"
            badge = "\(files.count) FILE"
        }
    }

    var isEngaged: Bool { phase != .idle }

    func select(_ target: ConversionTarget) {
        guard phase == .idle, !isClosing else { return }
        chosen = target
        hovered = nil
        progress = 0
        convertStart = Date()
        phase = .converting

        let files = self.files
        let box = WeakModel(self)
        Task { [weak self] in
            do {
                let outs = try await ConversionEngine.run(target, on: files) { p in
                    Task { @MainActor in box.value?.bump(p) }
                }
                guard let self else { return }
                self.outputs = outs
                self.progress = 1
                self.convertEnd = Date()
                self.message = outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) file creati"
                self.phase = .done
                NSSound(named: "Glass")?.play()
                try? await Task.sleep(nanoseconds: 3_800_000_000)
                if self.phase == .done { self.requestClose() }
            } catch {
                guard let self else { return }
                self.convertEnd = Date()
                self.message = error.localizedDescription
                self.phase = .failed
                NSSound(named: "Basso")?.play()
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                self.requestClose()
            }
        }
    }

    private func bump(_ p: Double) {
        if phase == .converting { progress = max(progress, p) }
    }

    func reveal() {
        guard phase == .done, !outputs.isEmpty else { return }
        onReveal(outputs)
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        requestClose()
    }

    func coreTapped() {
        if phase == .done { reveal() }
    }

    func backgroundTap() {
        if phase != .converting { requestClose() }
    }

    func outsideClick() {
        if phase != .converting { requestClose() }
    }

    func requestClose() {
        guard !isClosing else { return }
        isClosing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            self?.onClose()
        }
    }

    /// Esc closes · Return confirms · 1…9, 0 pick a planet.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            requestClose()
            return true
        case 36, 76:
            if phase == .done { reveal() } else if let hovered { select(hovered) }
            return true
        default:
            guard phase == .idle, let chars = event.charactersIgnoringModifiers, let n = Int(chars) else { return false }
            let index = n == 0 ? 9 : n - 1
            guard index < targets.count else { return false }
            select(targets[index])
            return true
        }
    }
}

/// Sendable weak reference used to report progress from background work.
final class WeakModel: @unchecked Sendable {
    weak var value: RingModel?
    init(_ value: RingModel) { self.value = value }
}

// MARK: - Window

final class RingPanel: NSPanel {
    func configure() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class RingController {
    private var panel: RingPanel?
    private var model: RingModel?
    private var monitors: [Any] = []

    var onReveal: ([URL]) -> Void = { _ in }
    var isVisible: Bool { panel != nil }

    func present(urls: [URL], at point: NSPoint) {
        close()
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { NSSound.beep(); return }

        let model = RingModel(files: files)
        model.onClose = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }
        model.onReveal = { [weak self] urls in self?.onReveal(urls) }

        // Center on the pointer, letting the transparent margin overflow the screen edge a bit.
        let side = GalaxyRingView.side
        let slack: CGFloat = 60
        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX - slack), frame.maxX - side + slack)
            origin.y = min(max(origin.y, frame.minY - slack), frame.maxY - side + slack)
        }

        let panel = RingPanel(contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.configure()
        let host = NSHostingView(rootView: GalaxyRingView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        panel.contentView = host

        self.panel = panel
        self.model = model
        panel.orderFrontRegardless()
        panel.makeKey()

        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let model = self?.model else { return event }
            return model.handleKey(event) ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.model?.outsideClick()
        }) {
            monitors.append(global)
        }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
