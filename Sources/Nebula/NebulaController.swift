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
    /// "Same format, smaller": lives in the bottom slot, shown only with Mini on.
    var isSameFormat = false

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
    @Published private(set) var toggleHover = false
    @Published private(set) var miniOn: Bool
    @Published private(set) var canUndo = false
    @Published private(set) var frame = Frame()

    let kind: Kind
    let items: [NebulaItem]
    let files: [URL]
    let fromClipboard: Bool
    let icon: NSImage?
    let badge: String
    let canMiniaturize: Bool
    let canCopy: Bool
    let favoriteID: String?
    let habitKey: String
    private let hasSameSlot: Bool

    /// Nebula center in screen coordinates.
    var center: NSPoint = .zero
    var onClose: () -> Void = {}
    var onPaste: (ClipboardHistory.Entry) -> Void = { _ in }

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
    /// Where the Mini toggle sits, below the blob (SwiftUI coordinates, from the center).
    static let toggleOffset: CGFloat = radius + 26

    init(files: [URL], fromClipboard: Bool, holding: Bool) {
        kind = .files
        self.files = files
        self.fromClipboard = fromClipboard
        self.holding = holding

        let key = Habits.key(for: files)
        habitKey = key
        var targets = ConversionCatalog.targets(for: files)
        let order = Habits.shared.arrange(targets.map(\.id), key: key)
        targets.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        var list = targets.prefix(10).map {
            NebulaItem(id: $0.id, label: $0.label, symbol: $0.symbol, thumbnail: nil, action: .convert($0))
        }

        let firstKind = FileInspector.kind(of: files[0])
        canMiniaturize = !(fromClipboard && [FileKind.plainText, .markdown, .richDocument].contains(firstKind))
        canCopy = !fromClipboard
        if canMiniaturize {
            let exts = Set(files.map { $0.pathExtension.uppercased() })
            let label = exts.count == 1 && !(exts.first ?? "").isEmpty ? exts.first! : "Riduci"
            list.append(NebulaItem(id: "any.same", label: label, symbol: "arrow.down.right.and.arrow.up.left",
                                   thumbnail: nil, action: .convert(ConversionCatalog.mini), isSameFormat: true))
        }
        hasSameSlot = canMiniaturize
        items = list

        icon = NSWorkspace.shared.icon(forFile: files[0].path)
        if files.count == 1 {
            let ext = files[0].pathExtension.uppercased()
            badge = ext.isEmpty ? firstKind.label.uppercased() : ext
        } else {
            badge = "\(files.count) FILE"
        }
        miniOn = canMiniaturize && Habits.shared.mini(for: key)
        favoriteID = Habits.shared.favorite(key: key)
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
        canCopy = false
        hasSameSlot = false
        miniOn = false
        favoriteID = nil
        habitKey = ""
    }

    /// Slot angle. With Mini available the bottom slot is reserved for "same format".
    func angle(_ index: Int) -> CGFloat {
        let n = max(items.count, 1)
        var slot = index
        if hasSameSlot {
            let bottom = n / 2
            if index == n - 1 { slot = bottom } else if index >= bottom { slot = index + 1 }
        }
        return -.pi / 2 + CGFloat(slot) / CGFloat(n) * 2 * .pi
    }

    func isAvailable(_ index: Int) -> Bool {
        index < items.count && (!items[index].isSameFormat || miniOn)
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

        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = center.y - mouse.y // SwiftUI orientation: y down
        let distance = hypot(dx, dy)

        var target = CGVector.zero
        var sizeGoal: CGFloat = 1

        switch phase {
        case .idle:
            guard !closing else { break }
            let overToggle = canMiniaturize && abs(dx) < 40 && abs(dy - Self.toggleOffset) < 16
            if toggleHover != overToggle { toggleHover = overToggle }
            let overCenter = canCopy && distance <= Self.deadzone
            if centerHover != overCenter { centerHover = overCenter }

            if distance <= Self.deadzone || overToggle {
                if selected != nil { selected = nil }
                gesture = distance <= Self.deadzone ? Gesture(start: CGPoint(x: dx, y: dy), last: CGPoint(x: dx, y: dy), time: f.t, path: 0) : nil
            } else if let index = nearestIndex(to: atan2(dy, dx)) {
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
    /// Fidgeting, or fast moves that didn't start from the center, never count.
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

    private func nearestIndex(to phi: CGFloat) -> Int? {
        var best: Int?
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for i in items.indices where isAvailable(i) {
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
        message = files.count == 1 ? "Copiato" : "\(files.count) copiati"
        phase = .done
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.requestClose()
        }
    }

    func toggleMini() {
        guard phase == .idle, canMiniaturize else { return }
        miniOn.toggle()
        Habits.shared.setMini(miniOn, key: habitKey)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let selected, !isAvailable(selected) { self.selected = nil }
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
            guard isAvailable(index) else { return false }
            launch(index)
            return true
        }
    }

    private func launch(_ index: Int) {
        guard phase == .idle, !closing, isAvailable(index) else { return }
        selected = index
        launchedIndex = index
        launchTime = frame.t
        phase = .launching
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if kind == .files {
            let shown = items.filter { !$0.isSameFormat }.map(\.id)
            Habits.shared.record(items[index].id, key: habitKey, shown: shown)
        }
    }

    private func finishLaunch() {
        guard let index = launchedIndex else { return }
        switch items[index].action {
        case .convert(let target):
            startConversion(target, shrink: miniOn && !items[index].isSameFormat)
        case .paste(let entry):
            phase = .done
            onPaste(entry)
            requestClose()
        }
    }

    private func startConversion(_ target: ConversionTarget, shrink: Bool) {
        progress = 0
        phase = .converting

        let files = self.files
        let fromClipboard = self.fromClipboard
        let box = WeakModel(self)
        Task { [weak self] in
            do {
                var outs = try await ConversionEngine.run(target, on: files) { p in
                    Task { @MainActor in box.value?.bump(shrink ? p * 0.85 : p) }
                }
                if shrink && !target.combines {
                    var smaller: [URL] = []
                    for out in outs { smaller.append(await Miniaturizer.shrink(out)) }
                    outs = smaller
                }
                var before: PasteboardSnapshot?
                if fromClipboard {
                    before = PasteboardSnapshot.capture()
                    ClipboardWriter.put(outs)
                }
                UndoCenter.shared.register(.files(outs, restoring: before))
                guard let self else { return }
                self.outputs = outs
                self.progress = 1
                self.canUndo = true
                self.message = fromClipboard ? "Copiato" : "Mostra"
                self.phase = .done
                NSSound(named: "Glass")?.play()
                try? await Task.sleep(nanoseconds: 2_200_000_000)
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
