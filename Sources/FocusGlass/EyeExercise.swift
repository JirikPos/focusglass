import SwiftUI

/// Tři kroky minutového cvičení očí.
enum EyeStep: Int, CaseIterable {
    case far
    case follow
    case close

    init(index: Int) {
        self = EyeStep(rawValue: min(max(0, index), EyeStep.allCases.count - 1)) ?? .far
    }

    var title: String {
        switch self {
        case .far: "Look far away"
        case .follow: "Follow the dot"
        case .close: "Close your eyes"
        }
    }

    var detail: String {
        switch self {
        case .far: "Find a point at least 6 meters away. Let your focus soften."
        case .follow: "Move only your eyes. Keep your head still."
        case .close: "Breathe slowly. A soft sound will bring you back."
        }
    }
}

/// Animace cvičení, kreslená přes `Canvas` (jen po dobu zobrazení overlaye).
struct EyeExerciseView: View {
    let step: EyeStep
    /// Sekundy od začátku aktuálního kroku.
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            switch step {
            case .far: drawFarFocus(in: &context, center: center)
            case .follow: drawFollowDot(in: &context, size: size, center: center)
            case .close: drawBreathing(in: &context, center: center)
            }
        }
        .id(step)
        .transition(.opacity)
    }

    /// Kruhy, které se pomalu stahují do dálky k jednomu bodu.
    private func drawFarFocus(in context: inout GraphicsContext, center: CGPoint) {
        let rings = 5
        for index in 0..<rings {
            let phase = (time / 7 + Double(index) / Double(rings)).truncatingRemainder(dividingBy: 1)
            let radius = 115 * (1 - phase)
            let opacity = sin(phase * .pi) * 0.45
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)), lineWidth: 1)
        }
        dot(in: &context, at: center, radius: 3, glow: 0.5)
    }

    /// Tečka putující po ležaté osmičce, za ní slábnoucí stopa.
    private func drawFollowDot(in context: inout GraphicsContext, size: CGSize, center: CGPoint) {
        let width = size.width / 2 - 20
        let height = size.height / 2 - 20
        let period = 7.0

        func point(_ t: TimeInterval) -> CGPoint {
            let angle = 2 * .pi * t / period
            return CGPoint(x: center.x + width * sin(angle),
                           y: center.y + height * sin(angle) * cos(angle) * 1.6)
        }

        var guide = Path()
        for i in 0...200 {
            let p = point(Double(i) / 200 * period)
            i == 0 ? guide.move(to: p) : guide.addLine(to: p)
        }
        context.stroke(guide, with: .color(.white.opacity(0.07)), lineWidth: 1)

        for i in stride(from: 12, through: 1, by: -1) {
            let p = point(time - Double(i) * 0.04)
            dot(in: &context, at: p, radius: 6 * (1 - Double(i) / 14), opacity: 0.25 * (1 - Double(i) / 12))
        }
        dot(in: &context, at: point(time), radius: 7, glow: 0.8)
    }

    /// Pomalu dýchající kruh (4 s nádech, 4 s výdech).
    private func drawBreathing(in context: inout GraphicsContext, center: CGPoint) {
        let breath = 0.5 - 0.5 * cos(2 * .pi * time / 8)
        let radius = 42 + 52 * breath
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.03 + 0.06 * breath)))
        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.35 + 0.3 * breath)), lineWidth: 1)
    }

    private func dot(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat,
                     opacity: Double = 1, glow: Double = 0) {
        if glow > 0 {
            let halo = radius * 3.5
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.35 * glow), .clear]),
                    center: point, startRadius: 0, endRadius: halo
                )
            )
        }
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(.white.opacity(opacity))
        )
    }
}
