import SwiftUI

/// Accumulates rotation phases so speed changes between stages never make the rings jump.
final class OrbClock {
    private var last: Date?
    var p1 = 0.0, p2 = 0.0, p3 = 0.0, t = 0.0
    /// Smoothed voice level, 0…1 — rises fast, falls gently, so the orb "breathes" with speech.
    var level = 0.0

    struct Spark { var angle: Double; var radius: Double; var speed: Double; var size: Double; var phase: Double }
    let sparks: [Spark] = (0..<160).map { _ in
        Spark(angle: Double.random(in: 0..<(2 * .pi)),
              radius: Double.random(in: 120...205),
              speed: Double.random(in: -0.5...0.5),
              size: Double.random(in: 0.8...2.4),
              phase: Double.random(in: 0..<(2 * .pi)))
    }
    let rays: [Double] = (0..<18).map { _ in Double.random(in: 0..<(2 * .pi)) }

    func advance(to date: Date, speeds: (Double, Double, Double), target: Double) {
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), 0.1)
        last = date
        let boost = 1 + 2.5 * level
        p1 += dt * speeds.0 * boost
        p2 += dt * speeds.1 * boost
        p3 += dt * speeds.2 * boost
        t += dt
        let rate = target > level ? 18.0 : 4.0
        level += (target - level) * min(1, dt * rate)
    }
}

struct OrbView: View {
    var stage: AppState.Stage
    /// Live loudness (0…1) of whoever is talking — you while listening, OLED while speaking.
    var voiceLevel: () -> Double = { 0 }
    @State private var clock = OrbClock()

    private struct Look {
        var speeds: (Double, Double, Double) // rad/s for the three ring groups
        var pulsePeriod: Double
        var brightness: Double
        var halo: Bool
        var ripples: Bool
    }

    private var look: Look {
        let full = 2 * Double.pi
        switch stage {
        case .asleep:
            return Look(speeds: (full / 24, -full / 36, full / 16), pulsePeriod: 4, brightness: 0.78, halo: false, ripples: false)
        case .wake:
            return Look(speeds: (full / 9, -full / 30, full / 12), pulsePeriod: 0.9, brightness: 1.3, halo: true, ripples: false)
        case .listening:
            return Look(speeds: (full / 10, -full / 30, full / 7), pulsePeriod: 0.7, brightness: 1.12, halo: false, ripples: true)
        case .working:
            return Look(speeds: (full / 2.2, -full / 3, full / 1.4), pulsePeriod: 1.6, brightness: 1.2, halo: false, ripples: false)
        case .speaking:
            return Look(speeds: (full / 8, -full / 30, full / 10), pulsePeriod: 0.55, brightness: 1.18, halo: false, ripples: true)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let look = self.look
                let raw = max(0, min(1, voiceLevel()))
                // Asleep it still reacts a little, so you can see it hearing you; busy working it stays steady.
                let target = stage == .working ? 0 : (stage == .asleep ? raw * 0.5 : raw)
                clock.advance(to: timeline.date, speeds: look.speeds, target: target)
                drawVoice(in: &context, size: size)
                draw(in: &context, size: size, look: look)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("OLED orb")
        .accessibilityAddTraits(.isButton)
    }

    private func color(_ hex: UInt32, _ opacity: Double = 1, boost: Double) -> Color {
        Color(hex: hex, opacity: min(1, opacity * boost))
    }

    /// Sparks and light rays that burst outward with the voice.
    private func drawVoice(in context: inout GraphicsContext, size: CGSize) {
        let lv = clock.level
        let s = min(size.width, size.height) / 420
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let t = clock.t
        let alive = 0.25 + 0.75 * lv // a faint spark field is always there; the voice brings it to life

        // Sparks
        for sp in clock.sparks {
            let a = sp.angle + t * sp.speed * (1 + 3 * lv)
            let wobble = 6 * sin(t * 2 + sp.phase)
            let r = (sp.radius + wobble + 55 * lv * (0.6 + 0.4 * sin(t * 9 + sp.phase))) * s
            let x = c.x + CGFloat(r * Foundation.cos(a)), y = c.y + CGFloat(r * Foundation.sin(a))
            let twinkle = 0.5 + 0.5 * sin(t * 3 + sp.phase * 3)
            let d = sp.size * s * (1 + lv)
            context.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                         with: .color(Color(hex: 0x8FE2FF, opacity: min(1, alive * (0.35 + 0.55 * twinkle)))))
        }

        // Rays, only when there's a voice
        guard lv > 0.04 else { return }
        var ctx = context
        ctx.addFilter(.shadow(color: Color(hex: 0x2FB4FF), radius: 6 * s))
        for (i, angle) in clock.rays.enumerated() {
            let a = angle + t * 0.4 * (i % 2 == 0 ? 1 : -1)
            let flicker = 0.5 + 0.5 * sin(t * 13 + Double(i) * 1.7)
            let inner = 130 * s, outer = (150 + 90 * lv * flicker) * s
            var ray = Path()
            ray.move(to: CGPoint(x: c.x + CGFloat(inner * Foundation.cos(a)), y: c.y + CGFloat(inner * Foundation.sin(a))))
            ray.addLine(to: CGPoint(x: c.x + CGFloat(outer * Foundation.cos(a)), y: c.y + CGFloat(outer * Foundation.sin(a))))
            ctx.stroke(ray, with: .color(Color(hex: 0x7FD8FF, opacity: min(1, lv * flicker * 1.2))),
                       style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, look: Look) {
        let s = min(size.width, size.height) / 420 * (1 + 0.08 * clock.level)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let b = look.brightness * (1 + 0.5 * clock.level)
        let t = clock.t

        func circle(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s))
        }
        func centredCircle(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: -r * s, y: -r * s, width: 2 * r * s, height: 2 * r * s))
        }

        // Soft glow behind everything
        context.fill(circle(176), with: .radialGradient(
            Gradient(colors: [
                color(0x7FE0FF, 0.45, boost: b),
                color(0x2FB4FF, 0.4, boost: b),
                color(0x0A4E9A, 0.16, boost: b),
                Color(hex: 0x021A3A, opacity: 0)
            ]),
            center: c, startRadius: 0, endRadius: 176 * s))

        // Wake flash ring
        if look.halo {
            let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
            let opacity = phase < 0.35 ? phase / 0.35 : 1 - (phase - 0.35) / 0.65 * 0.65
            let scale = phase < 0.35 ? 0.6 + 0.45 * (phase / 0.35) : 1.05 - 0.05 * ((phase - 0.35) / 0.65)
            var ctx = context
            ctx.addFilter(.shadow(color: Color(hex: 0x2FB4FF), radius: 14 * s))
            ctx.stroke(circle(170 * scale), with: .color(Color(hex: 0x9FE6FF, opacity: opacity)), lineWidth: 4 * s)
        }

        // Ripples while listening / speaking
        if look.ripples {
            for delay in [0.0, 0.8] {
                let phase = ((t + delay).truncatingRemainder(dividingBy: 1.6)) / 1.6
                let scale = 0.72 + 0.53 * phase
                context.stroke(circle(160 * scale), with: .color(Color(hex: 0x5CC8FF, opacity: 0.7 * (1 - phase))), lineWidth: 2 * s)
            }
        }

        // Outer broken arcs
        do {
            var ctx = context
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: .radians(clock.p2))
            // Each arc is drawn on its own so no straight lines join them.
            for (start, end) in [(-127.0, -98.0), (-82.0, -53.0), (52.0, 80.0), (100.0, 128.0)] {
                let r = 150 * s
                let a0 = start * Double.pi / 180
                var arc = Path()
                let rd = Double(r)
                arc.move(to: CGPoint(x: rd * Foundation.cos(a0), y: rd * Foundation.sin(a0)))
                arc.addArc(center: .zero, radius: r, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                ctx.stroke(arc, with: .color(color(0x3FB8FF, 0.7, boost: b)),
                           style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
            }
        }

        // Glass sphere
        do {
            context.fill(circle(128), with: .radialGradient(
                Gradient(colors: [Color(hex: 0x0D3C78, opacity: 0.55), Color(hex: 0x03142E, opacity: 0.2)]),
                center: CGPoint(x: c.x - 18 * s, y: c.y - 26 * s), startRadius: 0, endRadius: 150 * s))
            var ctx = context
            ctx.addFilter(.shadow(color: Color(hex: 0x2A9CFF, opacity: min(1, 0.9 * b)), radius: 10 * s))
            ctx.stroke(circle(128), with: .color(color(0x38B4FF, 1, boost: b)), lineWidth: 3 * s)
            context.stroke(circle(128), with: .color(Color(hex: 0x8FE2FF, opacity: 0.6)), lineWidth: 1 * s)
        }

        func dashedRing(radius: Double, width: Double, dash: [CGFloat], hex: UInt32, opacity: Double, angle: Double) {
            var ctx = context
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: .radians(angle))
            ctx.stroke(centredCircle(radius),
                       with: .color(color(hex, opacity, boost: b)),
                       style: StrokeStyle(lineWidth: width * s, dash: dash.map { $0 * s }))
        }

        dashedRing(radius: 104, width: 8, dash: [60, 30, 14, 40, 90, 26], hex: 0x2AA6FF, opacity: 0.85, angle: clock.p1)
        dashedRing(radius: 80, width: 5, dash: [70, 22, 30, 18], hex: 0x56C6FF, opacity: 0.9, angle: clock.p3)
        context.stroke(circle(66), with: .color(color(0x2F8FE0, 0.8, boost: b)), lineWidth: 1.2 * s)
        dashedRing(radius: 50, width: 3, dash: [20, 10, 40, 12], hex: 0x7FD8FF, opacity: 0.85, angle: clock.p2)
        context.stroke(circle(36), with: .color(color(0x56C6FF, 0.7, boost: b)), lineWidth: 1 * s)

        // Pulsing core
        let pulse = 0.5 + 0.5 * sin(2 * Double.pi * t / look.pulsePeriod)
        let coreScale = 1 + 0.08 * pulse
        do {
            var ctx = context
            ctx.addFilter(.blur(radius: 6 * s))
            ctx.fill(circle(26 * coreScale), with: .color(Color(hex: 0x2FB4FF, opacity: min(1, (0.35 + 0.25 * pulse) * b))))
        }
        do {
            var ctx = context
            ctx.addFilter(.shadow(color: Color(hex: 0x5CC8FF), radius: 12 * s))
            ctx.fill(circle(13 * coreScale), with: .color(Color(hex: 0xBFF0FF)))
        }
    }
}
