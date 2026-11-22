import AppKit
import SwiftUI

// MARK: - Root

struct GalaxyRingView: View {
    @ObservedObject var model: RingModel
    @State private var appeared = false
    @State private var burst = false

    static let side: CGFloat = 560
    static let orbit: CGFloat = 168

    private var shown: Bool { appeared && !model.isClosing }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let elapsed = now.timeIntervalSince(model.start)
            // Seconds spent converting: the galaxy spins faster while working, then calms down.
            let boost = model.convertStart.map { (model.convertEnd ?? now).timeIntervalSince($0) } ?? 0

            ZStack {
                Backdrop()
                    .onTapGesture { model.backgroundTap() }
                NebulaLayer(e: elapsed, energy: model.phase == .converting ? 1 : 0)
                GalaxyCanvas(e: elapsed, boost: boost)
                    .allowsHitTesting(false)
                OrbitTrack(e: elapsed, orbit: Self.orbit)
                    .opacity(model.isEngaged ? 0 : 1)
                    .scaleEffect(model.isEngaged ? 0.6 : 1)
                    .animation(.easeInOut(duration: 0.45), value: model.isEngaged)
                HoverBeam(model: model, orbit: Self.orbit)
                ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                    PlanetButton(model: model, target: target, index: index,
                                 count: model.targets.count, orbit: Self.orbit, e: elapsed)
                }
                CoreView(model: model, e: elapsed)
                Caption(model: model)
                    .offset(y: model.phase == .failed ? 104 : 92)
                if burst {
                    Shockwave(color: model.chosen?.color ?? .white)
                }
            }
            .frame(width: Self.side, height: Self.side)
        }
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 10)
        .animation(model.isClosing ? .easeIn(duration: 0.22) : .spring(response: 0.55, dampingFraction: 0.58), value: shown)
        .onAppear { appeared = true }
        .onChange(of: model.phase) { _, phase in
            if phase == .done { burst = true }
        }
    }
}

enum RingGeometry {
    static func angle(index: Int, count: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) / CGFloat(max(count, 1)) * 2 * .pi
    }
}

enum Palette {
    static let accretion: [Color] = [
        Color(hue: 0.08, saturation: 0.80, brightness: 1.0),
        Color(hue: 0.95, saturation: 0.75, brightness: 1.0),
        Color(hue: 0.78, saturation: 0.70, brightness: 1.0),
        Color(hue: 0.58, saturation: 0.80, brightness: 1.0),
        Color(hue: 0.08, saturation: 0.80, brightness: 1.0)
    ]
}

// MARK: - Background layers

struct Backdrop: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.black.opacity(0.85),
                                          Color(red: 0.03, green: 0.02, blue: 0.09).opacity(0.72),
                                          Color.black.opacity(0)],
                                 center: .center, startRadius: 40, endRadius: 280))
            .contentShape(Circle().scale(0.92))
    }
}

struct NebulaLayer: View {
    let e: Double
    let energy: Double

    var body: some View {
        ZStack {
            blob(Color(hue: 0.76, saturation: 0.80, brightness: 0.90), 360, e * 0.11, 46)
            blob(Color(hue: 0.92, saturation: 0.75, brightness: 0.95), 280, -e * 0.08 + 2.1, 72)
            blob(Color(hue: 0.60, saturation: 0.85, brightness: 0.95), 320, e * 0.06 + 4.2, 58)
            blob(Color(hue: 0.52, saturation: 0.70, brightness: 0.90), 200, -e * 0.13 + 1.0, 96)
        }
        .opacity(0.75 + 0.25 * energy * (0.5 + 0.5 * sin(e * 6)))
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, _ size: CGFloat, _ angle: Double, _ distance: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.5), color.opacity(0.16), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .offset(x: CGFloat(cos(angle)) * distance, y: CGFloat(sin(angle)) * distance)
            .blendMode(.screen)
    }
}

/// Spiral galaxy: twinkling stars + dust along three logarithmic arms
/// with differential rotation (inner regions turn faster).
struct GalaxyCanvas: View {
    let e: Double
    let boost: Double

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let t = CGFloat(e), b = CGFloat(boost)
            ctx.blendMode = .plusLighter

            for s in Star.all {
                let a = s.angle + t * 0.012
                let x = cx + cos(a) * s.radius, y = cy + sin(a) * s.radius
                let twinkle = 0.3 + 0.7 * (0.5 + 0.5 * sin(e * s.speed + s.phase))
                let o = twinkle * s.alpha * Galaxy.fade(s.radius)
                if o < 0.02 { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: x - s.size / 2, y: y - s.size / 2, width: s.size, height: s.size)),
                         with: .color(s.color.opacity(o)))
            }

            for d in Dust.all {
                let omega = 0.10 + 0.18 / (1 + d.radius / 55)
                let a = d.angle + (t + b * 5) * omega
                let x = cx + cos(a) * d.radius, y = cy + sin(a) * d.radius
                let o = d.alpha * Galaxy.fade(d.radius)
                ctx.fill(Path(ellipseIn: CGRect(x: x - d.size / 2, y: y - d.size / 2, width: d.size, height: d.size)),
                         with: .color(d.color.opacity(o)))
            }
        }
    }
}

enum Galaxy {
    static func fade(_ r: CGFloat) -> Double {
        Double(min(max((285 - r) / 80, 0), 1))
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Star {
    let radius: CGFloat, angle: CGFloat, size: CGFloat
    let alpha: Double, speed: Double, phase: Double
    let color: Color

    static let all: [Star] = {
        var rng = SeededRNG(seed: 7)
        return (0..<170).map { _ in
            let bluish = Double.random(in: 0...1, using: &rng) < 0.3
            return Star(radius: sqrt(CGFloat.random(in: 0...1, using: &rng)) * 280,
                        angle: CGFloat.random(in: 0...(2 * .pi), using: &rng),
                        size: CGFloat.random(in: 0.6...2.0, using: &rng),
                        alpha: Double.random(in: 0.4...1, using: &rng),
                        speed: Double.random(in: 0.8...3.2, using: &rng),
                        phase: Double.random(in: 0...6.28, using: &rng),
                        color: bluish ? Color(hue: 0.6, saturation: 0.25, brightness: 1) : .white)
        }
    }()
}

struct Dust {
    let radius: CGFloat, angle: CGFloat, size: CGFloat
    let alpha: Double
    let color: Color

    static let all: [Dust] = {
        var rng = SeededRNG(seed: 42)
        let arms = 3
        return (0..<540).map { k in
            let arm = k % arms
            let u = CGFloat.random(in: 0...1, using: &rng)
            let r = 22 + pow(u, 0.8) * 245
            let spread = CGFloat.random(in: -0.35...0.35, using: &rng) * (0.4 + r / 260)
            let angle = CGFloat(arm) * 2 * .pi / CGFloat(arms) + log(r / 22) * 2.1 + spread
            let radius = r + CGFloat.random(in: -6...6, using: &rng)
            let norm = Double(min(max((radius - 22) / 245, 0), 1))
            // warm core → pink/magenta → violet/blue outskirts
            let hue = norm < 0.18 ? 0.07 + norm * 0.3 : 0.95 - (norm - 0.18) * 0.42
            let color = Color(hue: hue, saturation: norm < 0.18 ? 0.5 : 0.62, brightness: 1)
            return Dust(radius: radius, angle: angle,
                        size: CGFloat.random(in: 0.8...2.6, using: &rng),
                        alpha: Double.random(in: 0.25...0.8, using: &rng),
                        color: color)
        }
    }()
}

struct OrbitTrack: View {
    let e: Double
    let orbit: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: orbit * 2, height: orbit * 2)
                .rotationEffect(.radians(e * 0.08))
            Circle()
                .stroke(LinearGradient(colors: [Color(hue: 0.55, saturation: 0.6, brightness: 1).opacity(0.28),
                                                .clear,
                                                Color(hue: 0.90, saturation: 0.6, brightness: 1).opacity(0.28)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
                .frame(width: orbit * 2 + 74, height: orbit * 2 + 74)
                .rotationEffect(.radians(-e * 0.05))
        }
        .allowsHitTesting(false)
    }
}

/// A light beam from the core to the hovered planet.
struct HoverBeam: View {
    @ObservedObject var model: RingModel
    let orbit: CGFloat
    @State private var angle: CGFloat = 0

    private var index: Int? {
        model.hovered.flatMap { model.targets.firstIndex(of: $0) }
    }

    var body: some View {
        let color = model.hovered?.color ?? .white
        let length = orbit - 64 - 32
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0), color.opacity(0.9), .white.opacity(0.9)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: length, height: 2.5)
                .shadow(color: color, radius: 4)
                .offset(x: 64 + length / 2)
        }
        .frame(width: GalaxyRingView.side, height: GalaxyRingView.side)
        .rotationEffect(.radians(angle))
        .opacity(index == nil || model.isEngaged ? 0 : 1)
        .animation(.easeOut(duration: 0.18), value: index)
        .allowsHitTesting(false)
        .onChange(of: index) { _, newIndex in
            guard let newIndex else { return }
            var target = RingGeometry.angle(index: newIndex, count: model.targets.count)
            // Take the short way around.
            while target - angle > .pi { target -= 2 * .pi }
            while angle - target > .pi { target += 2 * .pi }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { angle = target }
        }
    }
}

// MARK: - Planets

struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(x: configuration.isPressed ? 1.16 : 1, y: configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.36), value: configuration.isPressed)
    }
}

struct PlanetButton: View {
    @ObservedObject var model: RingModel
    let target: ConversionTarget
    let index: Int
    let count: Int
    let orbit: CGFloat
    let e: Double

    @State private var launched = false
    @State private var hovering = false

    var body: some View {
        let angle = RingGeometry.angle(index: index, count: count)
        let engaged = model.isEngaged
        let bob = CGFloat(sin(e * 1.3 + Double(index) * 1.9)) * 3.5
        let radius: CGFloat = (launched && !engaged) ? orbit : 0
        let hot = hovering && !engaged

        Button {
            model.select(target)
        } label: {
            PlanetBody(target: target, hovering: hot, e: e, index: index)
        }
        .buttonStyle(SquishyButtonStyle())
        // jelly hover
        .scaleEffect(x: hot ? 1.22 : 1, y: hot ? 1.16 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: hot)
        // idle floating
        .offset(x: cos(angle) * bob, y: sin(angle) * bob)
        // launch from the core / collapse into it
        .scaleEffect(launched ? 1 : 0.15)
        .scaleEffect(engaged ? 0.05 : 1)
        .opacity(launched && !engaged ? 1 : 0)
        .rotationEffect(.degrees(launched ? 0 : -40))
        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
        .animation(.spring(response: 0.62, dampingFraction: 0.55).delay(0.06 + Double(index) * 0.045), value: launched)
        .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(Double(index) * 0.03), value: engaged)
        .onHover { inside in
            hovering = inside
            if inside {
                model.hovered = target
            } else if model.hovered == target {
                model.hovered = nil
            }
        }
        .allowsHitTesting(!engaged)
        .onAppear { launched = true }
    }
}

struct PlanetBody: View {
    let target: ConversionTarget
    let hovering: Bool
    let e: Double
    let index: Int

    var body: some View {
        let c = target.color
        ZStack {
            // glow
            Circle()
                .fill(c.opacity(hovering ? 0.6 : 0.24))
                .frame(width: 86, height: 86)
                .blur(radius: hovering ? 16 : 12)
            // sphere
            Circle()
                .fill(RadialGradient(colors: [target.light, c, target.dark],
                                     center: UnitPoint(x: 0.3, y: 0.26), startRadius: 1, endRadius: 42))
                .frame(width: 60, height: 60)
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.7 : 0.3), lineWidth: hovering ? 1.2 : 0.7))
            // halo + orbiting moon on hover
            Circle()
                .stroke(c.opacity(0.6), lineWidth: 1)
                .frame(width: 76, height: 76)
                .scaleEffect(hovering ? 1 : 0.8)
                .opacity(hovering ? 1 : 0)
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .shadow(color: c, radius: 3)
                .offset(x: 38)
                .rotationEffect(.radians(e * 3 + Double(index)))
                .opacity(hovering ? 1 : 0)
            // label
            VStack(spacing: 1) {
                Image(systemName: target.symbol)
                    .font(.system(size: 13, weight: .bold))
                Text(target.label)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            .frame(width: 54)
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle().scale(0.72))
    }
}

// MARK: - Core (black hole)

struct CoreView: View {
    @ObservedObject var model: RingModel
    let e: Double

    var body: some View {
        let busy = model.phase == .converting
        let pulse = busy ? 1 + 0.035 * sin(e * 9) : 1 + 0.015 * sin(e * 2.2)
        let accent = model.chosen?.color ?? model.hovered?.color ?? Color(hue: 0.8, saturation: 0.6, brightness: 1)
        let showProgress = busy || model.phase == .done

        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hue: 0.08, saturation: 0.45, brightness: 1).opacity(0.85),
                                              Color(hue: 0.90, saturation: 0.70, brightness: 0.9).opacity(0.35),
                                              .clear],
                                     center: .center, startRadius: 30, endRadius: 120))
                .frame(width: 240, height: 240)
            // accretion disk
            Circle()
                .stroke(AngularGradient(colors: Palette.accretion, center: .center), lineWidth: 8)
                .frame(width: 134, height: 134)
                .blur(radius: 5)
                .rotationEffect(.radians(e * (busy ? 5 : 1.4)))
            Circle()
                .stroke(AngularGradient(colors: Palette.accretion.reversed(), center: .center), lineWidth: 1.5)
                .frame(width: 124, height: 124)
                .rotationEffect(.radians(-e * (busy ? 7 : 2.1)))
                .opacity(0.85)
            // event horizon
            Circle()
                .fill(RadialGradient(colors: [.black, .black, Color(white: 0.1)],
                                     center: .center, startRadius: 0, endRadius: 58))
                .frame(width: 116, height: 116)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            // progress
            Circle()
                .trim(from: 0, to: showProgress ? model.progress : 0)
                .stroke(AngularGradient(colors: [accent.opacity(0.4), accent, .white], center: .center),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 148, height: 148)
                .shadow(color: accent, radius: 6)
                .animation(.easeOut(duration: 0.25), value: model.progress)
            content(accent: accent)
                .frame(width: 104, height: 104)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: model.hovered)
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: model.phase)
        }
        .scaleEffect(pulse)
        .contentShape(Circle().scale(0.5))
        .onTapGesture { model.coreTapped() }
    }

    @ViewBuilder
    private func content(accent: Color) -> some View {
        switch model.phase {
        case .idle:
            if let hovered = model.hovered {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(hovered.color)
                    Text(hovered.label)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .id(hovered.id)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                VStack(spacing: 4) {
                    Image(nsImage: model.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 46, height: 46)
                        .shadow(color: .black, radius: 4)
                    Text(model.badge)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        case .converting:
            VStack(spacing: 0) {
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(model.chosen?.label ?? "")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 38, weight: .black))
                .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        }
    }
}

struct Caption: View {
    @ObservedObject var model: RingModel

    private var text: String {
        switch model.phase {
        case .idle: model.title
        case .converting: "Conversione in corso…"
        case .done: "\(model.message) · clicca il nucleo per vederlo"
        case .failed: model.message
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(model.phase == .failed ? 3 : 1)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.4)))
            .frame(maxWidth: 250)
            .allowsHitTesting(false)
    }
}

// MARK: - Supernova

struct Shockwave: View {
    let color: Color
    @State private var go = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: go ? 1 : 10)
                .frame(width: go ? 500 : 120, height: go ? 500 : 120)
                .blur(radius: 2)
                .opacity(go ? 0 : 0.9)
            Circle()
                .stroke(Color.white, lineWidth: go ? 0.5 : 4)
                .frame(width: go ? 420 : 120, height: go ? 420 : 120)
                .opacity(go ? 0 : 0.8)
            ForEach(0..<28, id: \.self) { i in
                let a = CGFloat(i) / 28 * 2 * .pi
                let d: CGFloat = go ? CGFloat(170 + (i % 4) * 24) : 50
                Circle()
                    .fill(i.isMultiple(of: 3) ? Color.white : color)
                    .frame(width: go ? 2 : 6, height: go ? 2 : 6)
                    .offset(x: cos(a) * d, y: sin(a) * d)
                    .opacity(go ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { go = true }
        }
    }
}
