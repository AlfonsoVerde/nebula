import AppKit
import SwiftUI

/// Small circular loader that follows the pointer; fires `completion` when full.
/// Progress is computed from the start time on every frame, so it always lasts
/// exactly `duration` no matter how often the key is pressed.
@MainActor
final class PointerLoader {
    final class LoaderProgress: ObservableObject {
        @Published var value: CGFloat = 0
    }

    private var panel: NebulaPanel?
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 1.5
    private var completion: (() -> Void)?
    private var progress = LoaderProgress()
    private static let size: CGFloat = 64

    var isActive: Bool { panel != nil }

    func start(duration: Double, completion: @escaping () -> Void) {
        cancel()
        self.duration = duration
        self.completion = completion
        startTime = CACurrentMediaTime()
        progress = LoaderProgress()

        let panel = NebulaPanel(contentRect: Self.rect(at: NSEvent.mouseLocation),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.configure()
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: LoaderView(progress: progress))
        panel.orderFrontRegardless()
        self.panel = panel

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        completion = nil
    }

    private func tick() {
        guard let panel else { return }
        panel.setFrame(Self.rect(at: NSEvent.mouseLocation), display: false)
        let p = min(1, (CACurrentMediaTime() - startTime) / duration)
        progress.value = CGFloat(p)
        if p >= 1 {
            let done = completion
            cancel()
            done?()
        }
    }

    private static func rect(at p: NSPoint) -> NSRect {
        NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
    }
}

struct LoaderView: View {
    @ObservedObject var progress: PointerLoader.LoaderProgress
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: 44, height: 44)
                .blur(radius: 6)
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 3)
                .frame(width: 34, height: 34)
            Circle()
                .trim(from: 0, to: progress.value)
                .stroke(AngularGradient(colors: [Color(hue: 0.55, saturation: 0.6, brightness: 1),
                                                 Color(hue: 0.75, saturation: 0.7, brightness: 1),
                                                 Color(hue: 0.92, saturation: 0.6, brightness: 1),
                                                 Color(hue: 0.55, saturation: 0.6, brightness: 1)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 34, height: 34)
                .shadow(color: Color(hue: 0.75, saturation: 0.7, brightness: 1).opacity(0.8), radius: 4)
        }
        .scaleEffect(shown ? 1 : 0.4)
        .opacity(shown ? 1 : 0)
        .frame(width: 64, height: 64)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { shown = true }
        }
    }
}
