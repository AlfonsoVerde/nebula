import AppKit
import SwiftUI

// MARK: - Geometry

enum BlobGeometry {
    /// Radial deformation at angle `theta` for a squish vector `bulge`:
    /// a smooth bulge towards the selection, slight compression on the sides.
    static func factor(_ theta: CGFloat, bulge: CGVector) -> CGFloat {
        let strength = hypot(bulge.dx, bulge.dy)
        guard strength > 0.0001 else { return 0 }
        let x = theta - atan2(bulge.dy, bulge.dx)
        let forward = max(0, cos(x))
        return strength * (1.15 * forward * forward * forward - 0.12 * sin(x) * sin(x))
    }

    /// The whole blob leans a little towards the selection.
    static func shift(_ bulge: CGVector, radius: CGFloat) -> CGSize {
        CGSize(width: bulge.dx * radius * 0.18, height: bulge.dy * radius * 0.18)
    }
}

struct BlobShape: Shape {
    var radius: CGFloat
    var bulge: CGVector
    var t: Double

    func path(in rect: CGRect) -> Path {
        let s = BlobGeometry.shift(bulge, radius: radius)
        let c = CGPoint(x: rect.midX + s.width, y: rect.midY + s.height)
        let time = CGFloat(t)
        var path = Path()
        let steps = 160
        for i in 0...steps {
            let theta = CGFloat(i) / CGFloat(steps) * 2 * .pi
            // tiny organic breathing so it never looks like a perfect circle
            let breathe = 0.011 * sin(3 * theta + time * 1.7) + 0.007 * sin(5 * theta - time * 2.3)
            let r = radius * (1 + BlobGeometry.factor(theta, bulge: bulge) + breathe)
            let p = CGPoint(x: c.x + cos(theta) * r, y: c.y + sin(theta) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Root

struct NebulaView: View {
    @ObservedObject var model: NebulaModel

    static let side: CGFloat = 300
    static let radius: CGFloat = 88

    var body: some View {
        let f = model.frame
        let R = Self.radius * f.size
        let shape = BlobShape(radius: R, bulge: f.bulge, t: f.t)
        let shift = BlobGeometry.shift(f.bulge, radius: R)
        let idle = model.phase == .idle

        ZStack {
            // Near-invisible disc so clicks inside the panel are caught.
            Circle()
                .fill(Color.black.opacity(0.012))
                .frame(width: Self.side, height: Self.side)

            // Blob: lightly transparent glass + a galaxy living inside it.
            ZStack {
                shape.fill(.ultraThinMaterial).opacity(0.82)
                GalaxyFill(t: f.t, spin: f.spin, bulge: f.bulge, radius: R)
                    .clipShape(shape)
                shape.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .white.opacity(0.18)],
                                            startPoint: .top, endPoint: .bottom),
                             lineWidth: 0.8)
            }
            .background(
                shape
                    .fill(Color(hue: 0.72, saturation: 0.75, brightness: 0.95).opacity(0.26))
                    .blur(radius: 20)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)

            if model.phase == .done {
                DoneRipple(radius: R)
            }

            // Options orbit inside the blob and get pushed out by the squish.
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let a = model.angle(index)
                let base: CGFloat = model.items.count > 7 ? 62 : 58
                let r = base * (1 + 0.85 * BlobGeometry.factor(a, bulge: f.bulge))
                let launched = model.launchedIndex == index
                OptionItem(item: item,
                           selected: model.selected == index,
                           dimmed: model.selected != nil && model.selected != index,
                           wide: model.kind == .paste)
                    .position(x: Self.side / 2 + shift.width + cos(a) * r,
                              y: Self.side / 2 + shift.height + sin(a) * r)
                    .scaleEffect(launched ? 1.7 : (idle ? 1 : 0.6))
                    .opacity(idle ? 1 : 0)
                    .animation(.easeOut(duration: launched ? 0.32 : 0.16), value: model.phase)
            }

            CenterContent(model: model)
                .offset(shift)

            // Center tap = Mini.
            if idle && model.canMiniaturize {
                Color.clear
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .onTapGesture { model.miniaturize() }
                    .offset(shift)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .onTapGesture { model.click() }
        .scaleEffect(max(f.scale, 0.001))
        .opacity(Double(min(1, f.scale * 1.6)))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Galaxy inside the blob

struct GalaxyFill: View {
    let t: Double
    let spin: Double
    let bulge: CGVector
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = radius
            let time = CGFloat(t)

            func disc(_ p: CGPoint, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }

            // Deep-space base over the glass.
            ctx.fill(disc(c, R * 1.6), with: .radialGradient(
                Gradient(colors: [Color(red: 0.11, green: 0.06, blue: 0.24).opacity(0.48),
                                  Color(red: 0.02, green: 0.02, blue: 0.07).opacity(0.60)]),
                center: c, startRadius: 0, endRadius: R * 1.35))

            // Slow drifting nebula clouds.
            for g in Cloud.all {
                let a = time * g.speed + g.phase
                let p = CGPoint(x: c.x + cos(a) * R * g.distance, y: c.y + sin(a) * R * g.distance)
                ctx.fill(disc(p, R * g.size), with: .radialGradient(
                    Gradient(colors: [g.color.opacity(0.34), g.color.opacity(0)]),
                    center: p, startRadius: 0, endRadius: R * g.size))
            }

            // Light leaking in the direction you're selecting.
            let strength = hypot(bulge.dx, bulge.dy)
            if strength > 0.005 {
                let dir = CGVector(dx: bulge.dx / strength, dy: bulge.dy / strength)
                let p = CGPoint(x: c.x + dir.dx * R * 0.85, y: c.y + dir.dy * R * 0.85)
                let k = Double(min(1, strength * 3.2))
                ctx.fill(disc(p, R), with: .radialGradient(
                    Gradient(colors: [Color(hue: 0.55, saturation: 0.55, brightness: 1).opacity(0.55 * k),
                                      Color(hue: 0.78, saturation: 0.70, brightness: 1).opacity(0.28 * k),
                                      .clear]),
                    center: p, startRadius: 0, endRadius: R))
            }

            // Star dust in two spiral arms + twinkles.
            ctx.blendMode = .plusLighter
            let s = CGFloat(spin)
            for d in MiniDust.all {
                let a = d.angle + s * (0.5 + 0.9 / (1 + d.radius * 3))
                let r = d.radius * R * 1.2
                let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                ctx.fill(disc(p, d.size), with: .color(d.color.opacity(d.alpha)))
            }
            for st in Twinkle.all {
                let o = st.alpha * (0.35 + 0.65 * (0.5 + 0.5 * sin(t * st.speed + st.phase)))
                let p = CGPoint(x: c.x + st.x * R * 1.3, y: c.y + st.y * R * 1.3)
                ctx.fill(disc(p, st.size), with: .color(.white.opacity(o)))
            }
        }
        .allowsHitTesting(false)
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

struct Cloud {
    let color: Color
    let size: CGFloat, distance: CGFloat, speed: CGFloat, phase: CGFloat

    static let all: [Cloud] = [
        Cloud(color: Color(hue: 0.76, saturation: 0.80, brightness: 0.95), size: 0.95, distance: 0.35, speed: 0.11, phase: 0.0),
        Cloud(color: Color(hue: 0.92, saturation: 0.65, brightness: 0.95), size: 0.70, distance: 0.55, speed: -0.08, phase: 2.1),
        Cloud(color: Color(hue: 0.60, saturation: 0.80, brightness: 0.95), size: 0.80, distance: 0.45, speed: 0.06, phase: 4.2)
    ]
}

struct MiniDust {
    let radius: CGFloat, angle: CGFloat, size: CGFloat
    let alpha: Double
    let color: Color

    static let all: [MiniDust] = {
        var rng = SeededRNG(seed: 11)
        return (0..<300).map { k in
            let arm = CGFloat(k % 2)
            let u = CGFloat.random(in: 0...1, using: &rng)
            let r = 0.06 + pow(u, 0.85) * 0.94
            let spread = CGFloat.random(in: -0.4...0.4, using: &rng) * (0.3 + r)
            let angle = arm * .pi + log(r / 0.06) * 1.9 + spread
            let hue = 0.58 + Double(r) * 0.36   // blue core → violet → pink
            return MiniDust(radius: r, angle: angle,
                            size: CGFloat.random(in: 0.35...1.1, using: &rng),
                            alpha: Double.random(in: 0.2...0.6, using: &rng),
                            color: Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 1))
        }
    }()
}

struct Twinkle {
    let x: CGFloat, y: CGFloat, size: CGFloat
    let alpha: Double, speed: Double, phase: Double

    static let all: [Twinkle] = {
        var rng = SeededRNG(seed: 5)
        return (0..<26).map { _ in
            let r = sqrt(CGFloat.random(in: 0...1, using: &rng))
            let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            return Twinkle(x: cos(a) * r, y: sin(a) * r,
                           size: CGFloat.random(in: 0.5...1.2, using: &rng),
                           alpha: Double.random(in: 0.5...1, using: &rng),
                           speed: Double.random(in: 1...3, using: &rng),
                           phase: Double.random(in: 0...6.28, using: &rng))
        }
    }()
}

// MARK: - Options & center

struct OptionItem: View {
    let item: NebulaItem
    let selected: Bool
    let dimmed: Bool
    let wide: Bool

    var body: some View {
        VStack(spacing: 3) {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .frame(height: 18)
            }
            Text(item.label)
                .font(.system(size: wide ? 8.5 : 9.5, weight: .semibold, design: .rounded))
                .tracking(0.2)
                .multilineTextAlignment(.center)
                .lineLimit(wide ? 2 : 1)
                .frame(maxWidth: wide ? 72 : nil)
                .fixedSize(horizontal: !wide, vertical: true)
        }
        .foregroundStyle(Color.white.opacity(dimmed ? 0.55 : 1))
        .shadow(color: .black.opacity(0.65), radius: 2.5, y: 0.5)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hue: 0.60, saturation: 0.6, brightness: 1).opacity(0.55),
                                                  Color(hue: 0.80, saturation: 0.7, brightness: 1).opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 30))
                    .frame(width: 60, height: 60)
                Capsule().fill(Color.white.opacity(0.16))
            }
            .opacity(selected ? 1 : 0)
        )
        .scaleEffect(selected ? 1.2 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: selected)
        .animation(.easeOut(duration: 0.15), value: dimmed)
    }
}

struct CenterContent: View {
    @ObservedObject var model: NebulaModel

    var body: some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.selected)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.phase)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .launching:
            if let index = model.selected, index < model.items.count {
                VStack(spacing: 1) {
                    Text(model.kind == .paste ? "Incolla" : model.items[index].label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(model.holding ? "rilascia" : "clic")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if model.kind == .paste {
                VStack(spacing: 3) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20, weight: .medium))
                    Text("ULTIMI COPIATI")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                VStack(spacing: 3) {
                    if let icon = model.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 28, height: 28)
                    }
                    Text(model.badge)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    if model.canMiniaturize {
                        Text("clic: mini")
                            .font(.system(size: 7, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
                .frame(maxWidth: 80)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        case .converting:
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: model.progress)
                Text("\(Int(model.progress * 100))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 38, height: 38)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
        case .done:
            VStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.5)))
        case .failed:
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16, weight: .medium))
                Text(model.message)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(width: 124)
            }
            .transition(.opacity)
        }
    }
}

struct DoneRipple: View {
    let radius: CGFloat
    @State private var go = false

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(go ? 0 : 0.45), lineWidth: go ? 0.5 : 1.5)
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(go ? 1.55 : 1)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.9)) { go = true } }
    }
}
