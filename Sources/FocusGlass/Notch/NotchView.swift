import SwiftUI

// MARK: - Panely notche

/// Registr panelů v rozbaleném notchi.
/// Nová funkce = nová složka s view + jeden `case` tady.
enum NotchTab: CaseIterable, Identifiable {
    case focus
    case media
    case shelf
    case clipboard
    case habits

    var id: Self { self }

    var symbol: String {
        switch self {
        case .focus: "laptopcomputer"
        case .media: "music.note"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .habits: "checklist"
        }
    }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .media: "Hudba"
        case .shelf: "Odkladiště"
        case .clipboard: "Schránka"
        case .habits: "Návyky"
        }
    }

    /// Panel lze v nastavení vypnout.
    @MainActor
    func isAvailable(_ settings: AppSettings) -> Bool {
        switch self {
        case .clipboard: settings.clipboardEnabled
        case .habits: !settings.notionDatabaseID.isEmpty
        default: true
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .focus: FocusNotchView()
        case .media: MediaNotchView()
        case .shelf: ShelfNotchView()
        case .clipboard: ClipboardNotchView()
        case .habits: HabitsNotchView()
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
        let shape = NotchShape(topRadius: expanded ? 10 : 6, bottomRadius: expanded ? 18 : 10)

        ZStack(alignment: .top) {
            shape.fill(.black)

            // Obsah má vždy svou cílovou velikost a odkrývá ho rostoucí tvar
            // (clipShape níže) – nic se neroztahuje ani neujíždí do stran.
            switch notch.mode {
            case .expanded:
                ExpandedNotch()
                    .frame(width: notch.expandedSize.width, height: notch.expandedSize.height)
                    .transition(.revealFromNotch)
            case .peek:
                CompactNotch(content: notch.compact)
                    .frame(width: notch.compactSize.width, height: notch.compactSize.height)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))
                    ))
            case .prompt:
                if let prompt = notch.prompt {
                    PromptNotch(prompt: prompt)
                        .id(notch.promptID)
                        .frame(width: notch.size(for: .prompt).width, height: notch.size(for: .prompt).height)
                        .transition(.revealFromNotch)
                }
            case .battery:
                if let battery = notch.battery {
                    BatteryNotch(info: battery)
                        .frame(width: notch.size(for: .battery).width, height: notch.size(for: .battery).height)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
                }
            case .job:
                if let job = notch.job {
                    JobNotch(info: job)
                        .frame(width: notch.size(for: .job).width, height: notch.size(for: .job).height)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
                }
            case .tasks:
                if let request = notch.taskPicker {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notch.notchSize.height)
                        TaskPickerView(excluded: request.excluded) { notch.resolveTaskPicker($0) }
                            .padding(.horizontal, 26)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                    }
                    .id(notch.tasksID)
                    .frame(width: notch.size(for: .tasks).width, height: notch.size(for: .tasks).height)
                    .transition(.revealFromNotch)
                }
            case .review:
                if let request = notch.taskReview {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notch.notchSize.height)
                        TaskReviewView(items: request.items, compact: true) { notch.resolveTaskReview($0) }
                            .padding(.horizontal, 26)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                    }
                    .id(notch.tasksID)
                    .frame(width: notch.size(for: .review).width, height: notch.size(for: .review).height)
                    .transition(.revealFromNotch)
                }
            case .intent:
                if let request = notch.intent {
                    IntentNotch(request: request)
                        .id(notch.intentID)
                        .frame(width: notch.size(for: .intent).width, height: notch.size(for: .intent).height)
                        .transition(.revealFromNotch)
                }
            case .alert:
                if let alert = notch.alert {
                    AlertNotch(alert: alert)
                        .frame(width: notch.size(for: .alert).width, height: notch.size(for: .alert).height)
                        .transition(.revealFromNotch)
                }
            case .idle:
                EmptyView()
            }

            if notch.isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .padding(EdgeInsets(top: notch.notchSize.height + 4, leading: 22, bottom: 8, trailing: 22))
                    .transition(.opacity)
            }
        }
        .frame(width: notch.shapeSize.width, height: notch.shapeSize.height)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(expanded ? 0.12 : 0.1), lineWidth: 1))
        .contentShape(shape)
        .compositingGroup()
        // Slabá záře. Její dosah (~3× radius) musí zůstat uvnitř okraje okna
        // (`glowMargin` / `shadowMargin`), jinak ji okno ořízne do viditelného obdélníku.
        .shadow(color: .white.opacity(expanded ? 0.12 : 0.1), radius: expanded ? 5 : 3)
        .onTapGesture { notch.click() }
        .onDrop(of: [.fileURL], isTargeted: $bindable.isDropTargeted) { providers in
            model.shelf.accept(providers)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expanded ? NotchState.openAnimation : NotchState.closeAnimation, value: notch.shapeSize)
        .animation(.smooth(duration: 0.25), value: notch.isDropTargeted)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Sbalený notch (náhled)

private struct CompactNotch: View {
    let content: NotchState.Compact
    @Environment(NotchState.self) private var notch
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: content.symbol)
                    .symbolRenderingMode(.monochrome)
                if let text = content.leadingText {
                    Text(text).monospacedDigit()
                }
            }
            .frame(width: content.wing)
            Spacer(minLength: notch.notchSize.width)
            Text(model.timer.remaining.clock)
                .monospacedDigit()
                .frame(width: content.wing)
        }
        .font(.system(size: 11, weight: .medium))
        .frame(height: notch.notchSize.height)
    }
}

// MARK: - Nabíjení

/// Bílá baterie vlevo, která se „naplní“ na aktuální stav, a procenta vpravo.
/// Průběh převodu souborů: kroužek vlevo, procenta (a počet úloh) vpravo.
private struct JobNotch: View {
    let info: NotchState.JobInfo
    @Environment(NotchState.self) private var notch

    var body: some View {
        HStack(spacing: 0) {
            ProgressRing(progress: info.progress, lineWidth: 2)
                .frame(width: 15, height: 15)
                .animation(.easeOut(duration: 0.25), value: info.progress)
                .frame(maxWidth: .infinity)

            Spacer(minLength: notch.notchSize.width)

            HStack(spacing: 4) {
                Text("\(Int((info.progress * 100).rounded())) %")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if info.count > 1 {
                    Text("×\(info.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: notch.notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Převod \(Int(info.progress * 100)) procent")
    }
}

private struct BatteryNotch: View {
    let info: NotchState.BatteryInfo
    @Environment(NotchState.self) private var notch
    @State private var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: max(2, 22 * fill))
                        .padding(2)
                        .shadow(color: .white.opacity(0.6), radius: 4 * fill)
                }
                .frame(width: 26, height: 13)
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.45)).frame(width: 1.5, height: 4)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: notch.notchSize.width)

            HStack(spacing: 3) {
                if info.charging {
                    Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold))
                }
                Text("\(info.percent) %")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: notch.notchSize.height)
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.15)) {
                fill = CGFloat(info.percent) / 100
            }
        }
    }
}

// MARK: - Otázka s tlačítky

private struct PromptNotch: View {
    let prompt: NotchState.Prompt
    @Environment(NotchState.self) private var notch

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.notchSize.height)
            HStack(spacing: 12) {
                Image(systemName: prompt.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(prompt.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(prompt.secondaryTitle) { notch.resolvePrompt(primary: false) }
                    .buttonStyle(GlassPillButtonStyle(size: 11))
                Button(prompt.primaryTitle) { notch.resolvePrompt(primary: true) }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
            .padding(.horizontal, 26)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Otázka na důvod

private struct IntentNotch: View {
    let request: NotchState.IntentRequest
    @Environment(NotchState.self) private var notch
    @State private var reason = ""
    @FocusState private var focused: Bool

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var missing: Int { max(0, NotchState.minimumReasonLength - trimmed.count) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.notchSize.height)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12))
                    Text("\(request.source) je během focusu zablokovaný")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Keycap(text: "esc")
                }
                HStack(spacing: 8) {
                    TextField("Proč tam chceš jít?", text: $reason)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(focused ? 0.2 : 0.08), lineWidth: 0.75))
                        .focused($focused)
                        .onSubmit(submit)
                    Button("Pustit na \(request.minutes) min", action: submit)
                        .buttonStyle(GlassPillButtonStyle(size: 11))
                        .disabled(missing > 0)
                        .opacity(missing > 0 ? 0.4 : 1)
                }
                Text(missing > 0 ? "Napiš konkrétní důvod – ještě \(missing) znaků." : "Enter = pustit. Důvod se zapíše do deníku výjimek.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 26)
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
        }
    }

    private func submit() {
        guard missing == 0 else { return }
        notch.resolveIntent(reason: trimmed)
    }
}

// MARK: - Upozornění

private struct AlertNotch: View {
    let alert: NotchState.Alert
    @Environment(NotchState.self) private var notch

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.notchSize.height)
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(alert.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .frame(maxHeight: .infinity)
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
                HStack(spacing: 1) {
                    ForEach(NotchTab.allCases.filter { $0.isAvailable(model.settings) }) { tab in
                        TabButton(tab: tab, selected: notch.tab == tab) { notch.tab = tab }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24)

                Color.clear.frame(width: notch.notchSize.width)

                status
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 26)
            }
            .frame(height: notch.notchSize.height)

            notch.tab.content
                .padding(.horizontal, 26)
                .padding(.top, 4)
                .padding(.bottom, 12)
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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        } else {
            Text(notch.tab.title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.6)
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.4))
                .frame(width: 22, height: 18)
                .background(Capsule().fill(.white.opacity(selected ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

// MARK: - Animace

/// Obsah se při otevření rozostřený zjasní, zatímco ho tvar odkrývá od výřezu dolů a do stran.
private struct RevealModifier: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 6)
            .opacity(progress)
    }
}

extension AnyTransition {
    static var revealFromNotch: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RevealModifier(progress: 0), identity: RevealModifier(progress: 1))
                .animation(.easeOut(duration: 0.3).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}
