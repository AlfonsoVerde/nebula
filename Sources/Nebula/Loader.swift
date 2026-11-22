import AppKit
import SwiftUI

/// Small circular loader that follows the pointer; fires `completion` when full.
@MainActor
final class PointerLoader {
    private var panel: NebulaPanel?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private static let size: CGFloat = 64

    var isActive: Bool { panel != nil }

    func start(duration: Double, completion: @escaping () -> Void) {
        cancel()
        let panel = NebulaPanel(contentRect: Self.rect(at: NSEvent.mouseLocation),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.configure()
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: LoaderView(duration: duration))
        panel.orderFrontRegardless()
        self.panel = panel

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.panel != nil else { return }
            self.cancel()
            completion()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func follow() {
        panel?.setFrame(Self.rect(at: NSEvent.mouseLocation), display: false)
    }

    private static func rect(at p: NSPoint) -> NSRect {
        NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
    }
}

struct LoaderView: View {
    let duration: Double
    @State private var progress: CGFloat = 0
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
                .trim(from: 0, to: progress)
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
            withAnimation(.linear(duration: duration)) { progress = 1 }
        }
    }
}
