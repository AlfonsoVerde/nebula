import AppKit
import QuartzCore
import SwiftUI

// MARK: - Model (state + jelly physics)

@MainActor
final class NebulaModel: ObservableObject {
    enum Phase { case idle, converting, done, failed }

    /// Physics snapshot, published once per frame.
    struct Frame {
        var t: Double = 0
        var spin: Double = 0
        var bulge: CGVector = .zero   // direction + strength of the squish (fraction of radius)
        var scale: CGFloat = 0
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: Int?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var holding: Bool
    @Published private(set) var frame = Frame()

    let files: [URL]
    let targets: [ConversionTarget]
    let icon: NSImage
    let badge: String

    /// Nebula center in screen coordinates.
    var center: NSPoint = .zero
    var onClose: () -> Void = {}

    private var outputs: [URL] = []
    private var velocity = CGVector.zero
    private var scaleVelocity: CGFloat = 0
    private var closing = false
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    static let deadzone: CGFloat = 16

    init(files: [URL], holding: Bool) {
        self.files = files
        self.holding = holding
        targets = ConversionCatalog.targets(for: files)
        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        if files.count == 1 {
            let ext = files[0].pathExtension.uppercased()
            badge = ext.isEmpty ? FileInspector.kind(of: files[0]).label.uppercased() : ext
        } else {
            badge = "\(files.count) FILE"
        }
    }

    func angle(_ index: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) / CGFloat(max(targets.count, 1)) * 2 * .pi
    }

    // MARK: Loop

    func start() {
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1.0 / 30.0))
        lastTick = now

        var f = frame
        f.t += Double(dt)
        f.spin += Double(dt) * (phase == .converting ? 1.8 : 0.14)

        // Pointer direction → selected option + squish target.
        var target = CGVector.zero
        if phase == .idle && !closing && !targets.isEmpty {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - center.x
            let dy = center.y - mouse.y // SwiftUI y grows downwards
            let distance = hypot(dx, dy)
            if distance > Self.deadzone {
                let index = nearestIndex(to: atan2(dy, dx))
                if selected != index {
                    selected = index
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                let amount = min(1, (distance - Self.deadzone) / 90)
                let strength = 0.07 + 0.2 * amount
                let a = angle(index)
                target = CGVector(dx: cos(a) * strength, dy: sin(a) * strength)
            } else if selected != nil {
                selected = nil
            }
        }

        // Under-damped spring = jelly.
        let k: CGFloat = 170, c: CGFloat = 9
        velocity.dx += ((target.dx - f.bulge.dx) * k - velocity.dx * c) * dt
        velocity.dy += ((target.dy - f.bulge.dy) * k - velocity.dy * c) * dt
        f.bulge.dx += velocity.dx * dt
        f.bulge.dy += velocity.dy * dt

        // Pop in with a bounce, collapse without one.
        let goal: CGFloat = closing ? 0 : 1
        let sk: CGFloat = closing ? 420 : 240
        let sc: CGFloat = closing ? 41 : 15
        scaleVelocity += ((goal - f.scale) * sk - scaleVelocity * sc) * dt
        f.scale = max(0, f.scale + scaleVelocity * dt)

        frame = f
        if closing && f.scale < 0.04 {
            stop()
            onClose()
        }
    }

    private func nearestIndex(to phi: CGFloat) -> Int {
        var best = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for i in targets.indices {
            let a = angle(i)
            let delta = abs(atan2(sin(phi - a), cos(phi - a)))
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    // MARK: Interaction

    /// Shortcut released: convert if pointing at an option, otherwise stay open.
    func release() {
        guard holding else { return }
        holding = false
        if phase == .idle, let selected { convert(targets[selected]) }
    }

    func click() {
        switch phase {
        case .idle: if let selected { convert(targets[selected]) }
        case .done: reveal()
        case .failed: requestClose()
        case .converting: break
        }
    }

    func outsideClick() {
        if phase != .converting { requestClose() }
    }

    func requestClose() {
        closing = true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            requestClose()
            return true
        case 36, 76:
            click()
            return true
        default:
            guard phase == .idle, let chars = event.charactersIgnoringModifiers, let n = Int(chars) else { return false }
            let index = n == 0 ? 9 : n - 1
            guard index < targets.count else { return false }
            convert(targets[index])
            return true
        }
    }

    private func convert(_ target: ConversionTarget) {
        guard phase == .idle, !closing else { return }
        selected = targets.firstIndex(of: target)
        progress = 0
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
                self.phase = .done
                NSSound(named: "Glass")?.play()
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                if self.phase == .done { self.requestClose() }
            } catch {
                guard let self else { return }
                self.message = error.localizedDescription
                self.phase = .failed
                NSSound(named: "Basso")?.play()
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                self.requestClose()
            }
        }
    }

    fileprivate func bump(_ p: Double) {
        if phase == .converting { progress = max(progress, p) }
    }

    private func reveal() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        requestClose()
    }
}

/// Sendable weak reference used to report progress from background work.
final class WeakModel: @unchecked Sendable {
    weak var value: NebulaModel?
    init(_ value: NebulaModel) { self.value = value }
}

// MARK: - Window

final class NebulaPanel: NSPanel {
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
final class NebulaController {
    private var panel: NebulaPanel?
    private var model: NebulaModel?
    private var monitors: [Any] = []

    var isVisible: Bool { panel != nil }

    func present(urls: [URL], at point: NSPoint, holding: Bool) {
        close()
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { NSSound.beep(); return }

        let model = NebulaModel(files: files, holding: holding)
        model.onClose = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }

        let side = NebulaView.side
        let slack: CGFloat = 50
        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX - slack), frame.maxX - side + slack)
            origin.y = min(max(origin.y, frame.minY - slack), frame.maxY - side + slack)
        }
        model.center = NSPoint(x: origin.x + side / 2, y: origin.y + side / 2)

        let panel = NebulaPanel(contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.configure()
        let host = NSHostingView(rootView: NebulaView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        panel.contentView = host

        self.panel = panel
        self.model = model
        model.start()
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

    func release() {
        model?.release()
    }

    func dismiss() {
        model?.requestClose()
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        model?.stop()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
