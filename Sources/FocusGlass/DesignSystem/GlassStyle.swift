import SwiftUI

// Monochromatický „matte black glass“ styl: jen bílá v různé průhlednosti nad tmavým sklem.

// MARK: - Skleněný panel

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.white.opacity(0.045), in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.03), .white.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
    }
}

extension View {
    func glassPanel(radius: CGFloat = 18) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

// MARK: - Tlačítka

/// Kulaté skleněné tlačítko s ikonou.
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Hlavní tlačítko: bílý kruh, černá ikona.
struct PrimaryButtonStyle: ButtonStyle {
    var size: CGFloat = 58

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.32, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
            .shadow(color: .white.opacity(0.18), radius: 14)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Skleněná kapsle s textem.
struct GlassPillButtonStyle: ButtonStyle {
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, size)
            .padding(.vertical, size * 0.5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
            .contentShape(Capsule())
    }
}

// MARK: - Indikátory

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .white.opacity(0.35), radius: 4)
        }
    }
}

/// Tenká linka, která se ke středu zkracuje se zbývajícím časem.
struct CountdownLine: View {
    var fraction: Double
    var width: CGFloat = 480

    var body: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.08))
                .frame(width: width, height: 2)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: max(0, width * min(1, fraction)), height: 2)
                .shadow(color: .white.opacity(0.6), radius: 6)
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.2), lineWidth: 0.75))
    }
}
