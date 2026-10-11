import SwiftUI

// MARK: - Panely notche

/// Registr panelů v rozbaleném notchi.
/// Nová funkce = nová složka s view + jeden `case` tady.
enum NotchTab: CaseIterable, Identifiable {
    case focus
    case media
    case shelf

    var id: Self { self }

    var symbol: String {
        switch self {
        case .focus: "laptopcomputer"
        case .media: "music.note"
        case .shelf: "tray"
        }
    }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .media: "Hudba"
        case .shelf: "Odkladiště"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .focus: FocusNotchView()
        case .media: MediaNotchView()
        case .shelf: ShelfNotchView()
        }
    }
}

// MARK: - Tvar

/// Tvar výřezu: nahoře konkávní „náběhy“ do lišty, dole zaoblené rohy.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                          control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
                          control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Kořenové view

struct NotchView: View {
    @Environment(NotchState.self) private var notch
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindable = notch
        let expanded = notch.isExpanded
        let shape = NotchShape(topRadius: expanded ? 14 : 6, bottomRadius: expanded ? 24 : 10)

        ZStack(alignment: .top) {
            shape.fill(.black)

            if expanded {
                ExpandedNotch()
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else if let compact = notch.compact {
                CompactNotch(content: compact)
                    .transition(.opacity)
            }

            if notch.isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .padding(EdgeInsets(top: notch.notchSize.height + 6, leading: 24, bottom: 12, trailing: 24))
                    .transition(.opacity)
            }
        }
        .frame(width: notch.shapeSize.width, height: notch.shapeSize.height)
        .clipShape(shape)
        .contentShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 18, y: 8)
        .onDrop(of: [.fileURL], isTargeted: $bindable.isDropTargeted) { providers in
            model.shelf.accept(providers)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: notch.shapeSize)
        .animation(.smooth(duration: 0.25), value: notch.isDropTargeted)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Sbalený notch

private struct CompactNotch: View {
    let content: NotchState.Compact
    @Environment(NotchState.self) private var notch
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: content.symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .medium))
                .frame(width: content.wing)
            Spacer(minLength: notch.notchSize.width)
            trailing
                .frame(width: content.wing)
        }
        .frame(height: notch.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch content.trailing {
        case .time:
            Text(model.timer.remaining.clock)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - Rozbalený notch

private struct ExpandedNotch: View {
    @Environment(NotchState.self) private var notch
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(NotchTab.allCases) { tab in
                        TabButton(tab: tab, selected: notch.tab == tab) { notch.tab = tab }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)

                Color.clear.frame(width: notch.notchSize.width)

                status
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 22)
            }
            .frame(height: notch.notchSize.height)

            notch.tab.content
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(notch.tab)
                .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: notch.tab)
    }

    @ViewBuilder
    private var status: some View {
        let timer = model.timer
        if notch.tab != .focus && (timer.hasStarted || timer.isAway) {
            HStack(spacing: 5) {
                Image(systemName: timer.stateSymbol)
                    .symbolRenderingMode(.monochrome)
                Text(timer.remaining.clock)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        } else {
            Text(notch.tab.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.4))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(.white.opacity(selected ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}
