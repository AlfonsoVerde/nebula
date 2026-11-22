import AppKit
import QuartzCore
import SwiftUI

// MARK: - Items

struct NebulaItem: Identifiable, Equatable {
    enum Action {
        case convert(ConversionTarget)
        case paste(ClipboardHistory.Entry)
    }

    let id: String
    let label: String
    let symbol: String
    let thumbnail: NSImage?
    let action: Action

    static func == (a: NebulaItem, b: NebulaItem) -> Bool { a.id == b.id }
}

// MARK: - Model (state + jelly physics)

@MainActor
final class NebulaModel: ObservableObject {
    enum Kind { case files, paste }
    enum Phase { case idle, launching, converting, done, failed }

    /// Physics snapshot, published once per frame.
    struct Frame {
        var t: Double = 0
        var spin: Double = 0
        var bulge: CGVector = .zero   // direction + strength of the squish (fraction of radius)
        var scale: CGFloat = 0        // pop in / out
        var size: CGFloat = 1         // 1 = full nebula, 0.5 = compact progress pill
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: Int?
    @Published private(set) var launchedIndex: Int?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var holding: Bool
    @Published private(set) var frame = Frame()

    let kind: Kind
    let items: [NebulaItem]
    let files: [URL]
    let fromClipboard: Bool
    let icon: NSImage?
    let badge: String
    let canMiniaturize: Bool

    /// Nebula center in screen coordinates.
    var center: NSPoint = .zero
    var onClose: () -> Void = {}
    var onPaste: (ClipboardHistory.Entry) -> Void = { _ in }

    private var outputs: [URL] = []
    private var velocity = CGVector.zero
    private var scaleVelocity: CGFloat = 0
    private var sizeVelocity: CGFloat = 0
    private var pointerVelocity = CGVector.zero
    private var lastMouse: NSPoint?
    private var launchTime: Double = 0
    private var closing = false
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    static let deadzone: CGFloat = 16
    /// A flick: fast (pt/s) and mostly outward from the center.
    static let flickSpeed: CGFloat = 1400

    init(files: [URL], fromClipboard: Bool, holding: Bool) {
        kind = .files
        self.files = files
        self.fromClipboard = fromClipboard
        self.holding = holding
        items = ConversionCatalog.targets(for: files).map {
            NebulaItem(id: $0.id, label: $0.label, symbol: $0.symbol, thumbnail: nil, action: .convert($0))
        }
        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        let firstKind = FileInspector.kind(of: files[0])
        if files.count == 1 {
            let ext = files[0].pathExtension.uppercased()
            let name = ext.isEmpty ? firstKind.label.uppercased() : ext
            badge = fromClipboard ? "APPUNTI · \(name)" : name
        } else {
            badge = "\(files.count) FILE"
        }
        canMiniaturize = !(fromClipboard && [FileKind.plainText, .markdown, .richDocument].contains(firstKind))
    }

    init(entries: [ClipboardHistory.Entry], holding: Bool) {
        kind = .paste
        files = []
        fromClipboard = false
        self.holding = holding
        items = entries.map {
            NebulaItem(id: $0.id.uuidString, label: $0.label, symbol: $0.symbol, thumbnail: $0.thumbnail, action: .paste($0))
        }
        icon = nil
        badge = "INCOLLA"
        canMiniaturize = false
    }

    func angle(_ index: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) / CGFloat(max(items.count, 1)) * 2 * .pi
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
        guard dt > 0 else { return }

        var f = frame
        f.t += Double(dt)
        f.spin += Double(dt) * (phase == .converting ? 1.8 : 0.14)

        // Smoothed pointer velocity (SwiftUI orientation: y down).
        let mouse = NSEvent.mouseLocation
        if let last = lastMouse {
            let v = CGVector(dx: (mouse.x - last.x) / dt, dy: (last.y - mouse.y) / dt)
            pointerVelocity = CGVector(dx: pointerVelocity.dx * 0.5 + v.dx * 0.5,
                                       dy: pointerVelocity.dy * 0.5 + v.dy * 0.5)
        }
        lastMouse = mouse

        var target = CGVector.zero
        var sizeGoal: CGFloat = 1

        switch phase {
        case .idle:
            if !closing && !items.isEmpty {
                let dx = mouse.x - center.x
                let dy = center.y - mouse.y
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

                    // Flick: "I WANT THIS".
                    let speed = hypot(pointerVelocity.dx, pointerVelocity.dy)
                    let outward = (pointerVelocity.dx * dx + pointerVelocity.dy * dy) / distance
                    if speed > Self.flickSpeed && outward > 0.75 * speed && distance > 26 {
                        launch(index)
                    }
                } else if selected != nil {
                    selected = nil
                }
            }
        case .launching:
            if let index = launchedIndex {
                let a = angle(index)
                target = CGVector(dx: cos(a) * 0.55, dy: sin(a) * 0.55)
            }
            sizeGoal = 0.62
            if f.t - launchTime > 0.3 { finishLaunch() }
        case .converting, .done:
            sizeGoal = 0.5
        case .failed:
            sizeGoal = 1
        }

        // Under-damped springs = jelly.
        let k: CGFloat = phase == .launching ? 260 : 170
        let c: CGFloat = phase == .launching ? 12 : 9
        velocity.dx += ((target.dx - f.bulge.dx) * k - velocity.dx * c) * dt
        velocity.dy += ((target.dy - f.bulge.dy) * k - velocity.dy * c) * dt
        f.bulge.dx += velocity.dx * dt
        f.bulge.dy += velocity.dy * dt

        sizeVelocity += ((sizeGoal - f.size) * 200 - sizeVelocity * 17) * dt
        f.size = max(0.2, f.size + sizeVelocity * dt)

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
        for i in items.indices {
            let a = angle(i)
            let delta = abs(atan2(sin(phi - a), cos(phi - a)))
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    // MARK: Interaction

    /// Trigger released: launch the pointed option, or just vanish.
    func release() {
        guard holding else { return }
        holding = false
        guard phase == .idle else { return }
        if let selected { launch(selected) } else { requestClose() }
    }

    /// The key was used for something else (⌥ + key, ⌥-click…).
    func cancelHold() {
        guard holding, phase == .idle else { return }
        holding = false
        requestClose()
    }

    func click() {
        switch phase {
        case .idle: if let selected { launch(selected) }
        case .done: reveal()
        case .failed: requestClose()
        case .launching, .converting: break
        }
    }

    func miniaturize() {
        guard phase == .idle, canMiniaturize, !closing else { return }
        selected = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        startConversion(ConversionCatalog.mini)
    }

    func outsideClick() {
        if phase != .converting && phase != .launching { requestClose() }
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
            guard index < items.count else { return false }
            launch(index)
            return true
        }
    }

    private func launch(_ index: Int) {
        guard phase == .idle, !closing, index < items.count else { return }
        selected = index
        launchedIndex = index
        launchTime = frame.t
        phase = .launching
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func finishLaunch() {
        guard let index = launchedIndex else { return }
        switch items[index].action {
        case .convert(let target):
            startConversion(target)
        case .paste(let entry):
            phase = .done
            onPaste(entry)
            requestClose()
        }
    }

    private func startConversion(_ target: ConversionTarget) {
        progress = 0
        phase = .converting

        let files = self.files
        let fromClipboard = self.fromClipboard
        let box = WeakModel(self)
        Task { [weak self] in
            do {
                let outs = try await ConversionEngine.run(target, on: files) { p in
                    Task { @MainActor in box.value?.bump(p) }
                }
                if fromClipboard { ClipboardWriter.put(outs) }
                guard let self else { return }
                self.outputs = outs
                self.progress = 1
                self.message = fromClipboard ? "Copiato" : "Mostra"
                self.phase = .done
                NSSound(named: "Glass")?.play()
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if self.phase == .done { self.requestClose() }
            } catch {
                guard let self else { return }
                self.message = error.localizedDescription
                self.phase = .failed
                NSSound(named: "Basso")?.play()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
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
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clicks work even though the panel never takes keyboard focus from the Finder.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

@MainActor
final class NebulaController {
    private var panel: NebulaPanel?
    private var model: NebulaModel?
    private var monitors: [Any] = []

    var onPaste: (ClipboardHistory.Entry) -> Void = { _ in }
    var isVisible: Bool { panel != nil }
    var isPasteMode: Bool { model?.kind == .paste }

    func present(files urls: [URL], fromClipboard: Bool, at point: NSPoint, holding: Bool) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { NSSound.beep(); return }
        show(NebulaModel(files: files, fromClipboard: fromClipboard, holding: holding), at: point)
    }

    func presentPaste(_ entries: [ClipboardHistory.Entry], at point: NSPoint, holding: Bool) {
        show(NebulaModel(entries: entries, holding: holding), at: point)
    }

    private func show(_ model: NebulaModel, at point: NSPoint) {
        close()
        model.onClose = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }
        model.onPaste = { [weak self] entry in self?.onPaste(entry) }

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
        let host = FirstMouseHostingView(rootView: NebulaView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        panel.contentView = host

        self.panel = panel
        self.model = model
        model.start()
        panel.orderFrontRegardless()
        // While holding the key, keyboard focus stays where it was (⌥ + key keeps working).
        if !model.holding { panel.makeKey() }

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

    func release() { model?.release() }
    func cancelHold() { model?.cancelHold() }
    func dismiss() { model?.requestClose() }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        model?.stop()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
