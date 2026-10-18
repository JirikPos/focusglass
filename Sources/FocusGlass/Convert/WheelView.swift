import ConvertKit
import SwiftUI

/// Kolo s lístky. Kreslí jen stav z `WheelModel`; myš a klávesnici řeší `WheelPanel`.
struct WheelView: View {
    let model: WheelModel
    var animated = true
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.82))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .frame(width: 2 * WheelLayout.outerRadius + 12, height: 2 * WheelLayout.outerRadius + 12)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)

                let items = model.visibleItems
                let geometry = model.geometry
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Petal(item: item, index: index, geometry: geometry, highlighted: model.hovered == index)
                }

                CenterLabel(model: model)
            }
            .frame(width: WheelLayout.wheelSide, height: WheelLayout.wheelSide)

            Footer(model: model)
                .frame(height: WheelLayout.footerHeight, alignment: .top)
        }
        .frame(width: WheelLayout.size.width, height: WheelLayout.size.height)
        .scaleEffect(appeared || !animated ? 1 : 0.86, anchor: UnitPoint(x: 0.5, y: WheelLayout.center.y / WheelLayout.size.height))
        .opacity(appeared || !animated ? 1 : 0)
        .animation(.snappy(duration: 0.12), value: model.hovered)
        .animation(.snappy(duration: 0.18), value: model.page)
        .animation(.snappy(duration: 0.18), value: model.wheel)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { appeared = true }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Lístek

private struct Petal: View {
    let item: WheelItem
    let index: Int
    let geometry: WheelGeometry
    let highlighted: Bool

    var body: some View {
        let range = geometry.range(of: index)
        let labelRadius = (geometry.innerRadius + geometry.outerRadius) / 2 + 4
        let position = WheelGeometry.point(
            angle: geometry.midAngle(of: index), radius: labelRadius, center: WheelLayout.center
        )
        ZStack {
            PetalShape(start: range.start, end: range.end, inner: geometry.innerRadius, outer: geometry.outerRadius)
                .fill(fill)
            label
                .position(position)
        }
        .frame(width: WheelLayout.wheelSide, height: WheelLayout.wheelSide)
        .accessibilityElement()
        .accessibilityLabel(item.title)
        .accessibilityHint(item.hint ?? "")
    }

    private var fill: Color {
        if highlighted { return item.isEnabled ? .white.opacity(0.92) : .white.opacity(0.18) }
        return .white.opacity(0.07)
    }

    private var foreground: Color {
        guard item.isEnabled else { return .white.opacity(0.28) }
        return highlighted ? .black : .white.opacity(0.92)
    }

    @ViewBuilder
    private var label: some View {
        if let symbol = item.symbol {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                Text(item.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(foreground)
            .frame(width: 74)
        } else {
            Text(item.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 70)
                .overlay(alignment: .topTrailing) {
                    if item.approximate {
                        Text("≈").font(.system(size: 10, weight: .bold)).foregroundStyle(foreground.opacity(0.7))
                            .offset(x: 2, y: -8)
                    }
                }
        }
    }
}

/// Výseč mezikruží se zaoblenými rohy a stejně širokými mezerami mezi lístky.
private struct PetalShape: Shape {
    let start: Double
    let end: Double
    let inner: CGFloat
    let outer: CGFloat
    var gap: CGFloat = 6
    var corner: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Zúžit o poloměr rohu a pak obtáhnout kulatou čarou → oblé rohy u libovolného tvaru.
        let innerR = inner + corner
        let outerR = outer - corner
        let half = gap / 2 + corner
        guard outerR > innerR else { return Path() }
        let outerStart = start + asin(min(half / outerR, 1))
        let outerEnd = end - asin(min(half / outerR, 1))
        let innerStart = start + asin(min(half / innerR, 1))
        let innerEnd = end - asin(min(half / innerR, 1))
        guard outerEnd > outerStart else { return Path() }

        var core = Path()
        let steps = 32
        for step in 0...steps {
            let angle = outerStart + (outerEnd - outerStart) * Double(step) / Double(steps)
            let point = WheelGeometry.point(angle: angle, radius: outerR, center: center)
            step == 0 ? core.move(to: point) : core.addLine(to: point)
        }
        if innerEnd > innerStart {
            for step in 0...steps {
                let angle = innerEnd - (innerEnd - innerStart) * Double(step) / Double(steps)
                core.addLine(to: WheelGeometry.point(angle: angle, radius: innerR, center: center))
            }
        } else {
            // Úzký lístek u malého vnitřního poloměru – vnitřní hrana se zúží do bodu.
            core.addLine(to: WheelGeometry.point(angle: (start + end) / 2, radius: innerR, center: center))
        }
        core.closeSubpath()
        let rounded = core.strokedPath(StrokeStyle(lineWidth: 2 * corner, lineJoin: .round))
        return core.union(rounded)
    }
}

// MARK: - Střed a patička

private struct CenterLabel: View {
    let model: WheelModel

    var body: some View {
        let item = model.hoveredItem
        VStack(spacing: 3) {
            if model.visibleItems.isEmpty {
                Text("Nic tu není")
                    .font(.system(size: 11, weight: .semibold))
                Text("pro \(model.selection.commonKind?.title.lowercased() ?? "výběr")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.5))
            } else if let item, let hint = item.hint {
                Text(item.title).font(.system(size: 11, weight: .semibold))
                Text(hint)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
            } else {
                Text(item?.title ?? model.wheel.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(model.selection.summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: 2 * WheelLayout.innerRadius - 14, height: 2 * WheelLayout.innerRadius - 14)
        .background(Circle().fill(.white.opacity(0.06)))
        .position(WheelLayout.center)
    }
}

private struct Footer: View {
    let model: WheelModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.keys, id: \.0) { wheel, key in
                let active = wheel == model.wheel
                HStack(spacing: 4) {
                    Text(key.symbol).font(.system(size: 11, weight: .semibold))
                    Text(wheel.title).font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(active ? .black : .white.opacity(0.75))
                .background(Capsule().fill(active ? .white.opacity(0.9) : .black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(.white.opacity(active ? 0 : 0.12), lineWidth: 1))
            }
            if model.pageCount > 1 {
                Text("\(model.page + 1)/\(model.pageCount)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.75)))
            }
        }
    }
}
