import AppKit
import QuartzCore
import SwiftUI

// MARK: - Items

struct NebulaItem: Identifiable, Equatable {
    enum Action {
        case convert(ConversionTarget)
        case paste(ClipboardHistory.Entry)
        case tool(Tool)
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
    /// Nebula converts · Eco pastes · Pulsar edits · Buco nero expires / cleans.
    enum Kind { case nebula, eco, pulsar, blackHole }
    enum Phase { case idle, launching, converting, done, failed }

    /// Physics snapshot, published once per frame.
    struct Frame {
        var t: Double = 0
        var spin: Double = 0
        var bulge: CGVector = .zero   // direction + strength of the squish (fraction of radius)
        var scale: CGFloat = 0        // pop in / out
        var size: CGFloat = 1         // 1 = full, 0.5 = compact progress pill
    }

    /// A pointer move that started at rest in the center (candidate flick).
    private struct Gesture {
        var start: CGPoint
        var last: CGPoint
        var time: Double
        var path: CGFloat
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: Int?
    @Published private(set) var launchedIndex: Int?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var holding: Bool
    @Published private(set) var centerHover = false
    @Published private(set) var canUndo = false
    @Published private(set) var frame = Frame()

    let kind: Kind
    let items: [NebulaItem]
    let files: [URL]
    let fromClipboard: Bool
    let icon: NSImage?
    let badge: String
    let canCopy: Bool
    let favoriteID: String?
    let habitKey: String
    /// Option size: Eco by position (newest biggest), the others by how likely you are to pick them.
    let emphasis: [String: CGFloat]

    /// Nebula center in screen coordinates.
    var center: NSPoint = .zero
    var onClose: () -> Void = {}
    var onPaste: (ClipboardHistory.Entry) -> Void = { _ in }
    var onPanel: (Tool, [URL]) -> Void = { _, _ in }

    private var outputs: [URL] = []
    private var velocity = CGVector.zero
    private var scaleVelocity: CGFloat = 0
    private var sizeVelocity: CGFloat = 0
    private var gesture: Gesture?
    private var launchTime: Double = 0
    private var closing = false
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    static let radius: CGFloat = 88
    /// Rest area in the center (= the Copy button).
    static let deadzone: CGFloat = 26
    /// A flick must reach beyond the edge of the blob…
    static let flickReach: CGFloat = radius + 14
    static let maxItems = 8

    /// Nebula: conversions for files (or clipboard content).
    init(files: [URL], fromClipboard: Bool, holding: Bool) {
        kind = .nebula
        self.files = files
        self.fromClipboard = fromClipboard
        self.holding = holding

        let key = Habits.key(for: files)
        habitKey = key
        var targets = ConversionCatalog.targets(for: files)
        let order = Habits.shared.arrange(targets.map(\.id), key: key)
        targets.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        let list = targets.prefix(Self.maxItems).map {
            NebulaItem(id: $0.id, label: tr($0.label), symbol: $0.symbol, thumbnail: nil, action: .convert($0))
        }
        items = list
        canCopy = !fromClipboard
        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        badge = Self.badge(for: files)
        favoriteID = Habits.shared.favorite(key: key)
        emphasis = Self.emphasis(key: key, ids: list.map(\.id))
    }

    private static func emphasis(key: String, ids: [String]) -> [String: CGFloat] {
        let p = Habits.shared.likelihood(key: key, ids: ids)
        guard let top = p.values.max(), top > 0 else { return [:] }
        return p.mapValues { 0.9 + 0.32 * CGFloat($0 / top) }
    }

    /// Pulsar / Buco nero: tools for the selected files.
    init(tools: [Tool], files: [URL], kind: Kind, holding: Bool) {
        self.kind = kind
        self.files = files
        fromClipboard = false
        self.holding = holding
        let key = (kind == .pulsar ? "pulsar:" : "bh:") + Habits.key(for: files)
        habitKey = key
        let order = Habits.shared.arrange(tools.map(\.rawValue), key: key)
        let sorted = tools.sorted { (order.firstIndex(of: $0.rawValue) ?? 0) < (order.firstIndex(of: $1.rawValue) ?? 0) }
        let list = sorted.prefix(Self.maxItems).map {
            NebulaItem(id: $0.rawValue, label: $0.label, symbol: $0.symbol, thumbnail: nil, action: .tool($0))
        }
        items = list
        canCopy = false
        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        badge = Self.badge(for: files)
        favoriteID = Habits.shared.favorite(key: key)
        emphasis = Self.emphasis(key: key, ids: list.map(\.id))
    }

    /// Eco: last copied items.
    init(entries: [ClipboardHistory.Entry], holding: Bool) {
        kind = .eco
        files = []
        fromClipboard = false
        self.holding = holding
        let list = entries.map {
            NebulaItem(id: $0.id.uuidString, label: $0.label, symbol: $0.symbol, thumbnail: $0.thumbnail, action: .paste($0))
        }
        items = list
        icon = nil
        badge = tr("Eco").uppercased()
        canCopy = false
        favoriteID = nil
        habitKey = ""
        let sizes: [CGFloat] = [1.16, 1.0, 0.86]
        var emphasis: [String: CGFloat] = [:]
        for (i, item) in list.enumerated() { emphasis[item.id] = sizes[min(i, sizes.count - 1)] }
        self.emphasis = emphasis
    }

    private static func badge(for files: [URL]) -> String {
        guard files.count == 1 else { return tr("%d file", files.count).uppercased() }
        let ext = files[0].pathExtension.uppercased()
        return ext.isEmpty ? FileInspector.kind(of: files[0]).label.uppercased() : ext
    }

    func angle(_ index: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) / CGFloat(max(items.count, 1)) * 2 * .pi
    }

    /// Ring radius for the options: roomier when there are many.
    var optionRadius: CGFloat {
        switch items.count {
        case ...3: 54
        case ...5: 58
        default: 63
        }
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
        f.spin += Double(dt) * (phase == .converting ? 1.8 : (kind == .blackHole ? 0.5 : 0.14))

        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = center.y - mouse.y // SwiftUI orientation: y down
        let distance = hypot(dx, dy)

        var target = CGVector.zero
        var sizeGoal: CGFloat = 1

        switch phase {
        case .idle:
            guard !closing else { break }
            let overCenter = canCopy && distance <= Self.deadzone
            if centerHover != overCenter { centerHover = overCenter }

            if distance <= Self.deadzone || items.isEmpty {
                if selected != nil { selected = nil }
                gesture = Gesture(start: CGPoint(x: dx, y: dy), last: CGPoint(x: dx, y: dy), time: f.t, path: 0)
            } else {
                let index = nearestIndex(to: atan2(dy, dx))
                if selected != index {
                    selected = index
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                let amount = min(1, (distance - Self.deadzone) / 90)
                let strength = 0.07 + 0.2 * amount
                let a = angle(index)
                target = CGVector(dx: cos(a) * strength, dy: sin(a) * strength)
                if detectFlick(dx: dx, dy: dy, distance: distance, age: f.t) { launch(index) }
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

    /// A flick is deliberate: it starts at rest in the center, goes out in an almost
    /// straight line, crosses the edge of the blob quickly and travels far enough.
    private func detectFlick(dx: CGFloat, dy: CGFloat, distance: CGFloat, age: Double) -> Bool {
        guard var g = gesture else { return false }
        let p = CGPoint(x: dx, y: dy)
        g.path += hypot(p.x - g.last.x, p.y - g.last.y)
        g.last = p
        let elapsed = age - g.time

        if distance >= Self.flickReach {
            gesture = nil
            let displacement = hypot(p.x - g.start.x, p.y - g.start.y)
            let speed = displacement / CGFloat(max(elapsed, 0.001))
            let straightness = displacement / max(g.path, 1)
            let isFlick = age > 0.25 && elapsed < 0.22 && displacement > 75
                && straightness > 0.9 && speed > Habits.shared.flickThreshold
            if !isFlick { Habits.shared.recordSpeed(Double(speed)) }
            return isFlick
        }
        gesture = elapsed > 0.3 ? nil : g
        return false
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

    /// Center click: copy the file(s), like ⌘C in the Finder.
    func copyFiles() {
        guard phase == .idle, canCopy, !closing else { return }
        let before = PasteboardSnapshot.capture()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        UndoCenter.shared.register(.pasteboard(before))
        canUndo = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        selected = nil
        message = files.count == 1 ? tr("Copiato") : tr("%d copiati", files.count)
        phase = .done
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.requestClose()
        }
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
        if kind != .eco {
            Habits.shared.record(items[index].id, key: habitKey, shown: items.map(\.id))
        }
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
        case .tool(let tool):
            if tool.needsPanel {
                phase = .done
                onPanel(tool, files)
                requestClose()
            } else {
                startTool(tool)
            }
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
                // From the clipboard: the result becomes what you paste (Eco #1),
                // the original moves to Eco #2, what you copied before to #3.
                var before: PasteboardSnapshot?
                if fromClipboard {
                    before = PasteboardSnapshot.capture()
                    ClipboardWriter.put(outs)
                    ClipboardHistory.shared.refresh()
                }
                UndoCenter.shared.register(.files(outs, restoring: before))
                self?.finish(outputs: outs, message: fromClipboard ? tr("Pronto da incollare") : tr("Mostra"))
            } catch {
                self?.fail(error)
            }
        }
    }

    private func startTool(_ tool: Tool) {
        progress = 0
        phase = .converting
        let files = self.files
        let box = WeakModel(self)
        Task { [weak self] in
            do {
                let result = try await ToolRunner.run(tool, on: files) { p in
                    Task { @MainActor in box.value?.bump(p) }
                }
                if let undo = result.undo { UndoCenter.shared.register(undo) }
                self?.finish(outputs: result.outputs, message: result.message, undoable: result.undo != nil)
            } catch {
                self?.fail(error)
            }
        }
    }

    private func finish(outputs outs: [URL], message: String, undoable: Bool = true) {
        outputs = outs
        progress = 1
        canUndo = undoable
        self.message = message
        phase = .done
        NSSound(named: "Glass")?.play()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self?.phase == .done { self?.requestClose() }
        }
    }

    private func fail(_ error: Error) {
        message = error.localizedDescription
        phase = .failed
        NSSound(named: "Basso")?.play()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.requestClose()
        }
    }

    fileprivate func bump(_ p: Double) {
        if phase == .converting { progress = max(progress, p) }
    }

    private func reveal() {
        guard !outputs.isEmpty else { requestClose(); return }
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
    var onPanel: (Tool, [URL]) -> Void = { _, _ in }
    var isVisible: Bool { panel != nil }
    var kind: NebulaModel.Kind? { model?.kind }
    var isHolding: Bool { model?.holding ?? false }

    func present(files urls: [URL], fromClipboard: Bool, at point: NSPoint, holding: Bool) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { NSSound.beep(); return }
        show(NebulaModel(files: files, fromClipboard: fromClipboard, holding: holding), at: point)
    }

    func presentEco(_ entries: [ClipboardHistory.Entry], at point: NSPoint, holding: Bool) {
        show(NebulaModel(entries: entries, holding: holding), at: point)
    }

    func presentTools(_ tools: [Tool], files urls: [URL], kind: NebulaModel.Kind, at point: NSPoint, holding: Bool) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty, !tools.isEmpty else { NSSound.beep(); return }
        show(NebulaModel(tools: tools, files: files, kind: kind, holding: holding), at: point)
    }

    private func show(_ model: NebulaModel, at point: NSPoint) {
        close()
        model.onClose = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }
        model.onPaste = { [weak self] entry in self?.onPaste(entry) }
        model.onPanel = { [weak self] tool, files in self?.onPanel(tool, files) }

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
