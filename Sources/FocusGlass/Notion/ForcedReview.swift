import AppKit
import SwiftUI

/// Vynucené večerní review přes všechny obrazovky.
///
/// Nejde zavřít Esc ani ⌘Q (viz `AppDelegate`). Jediné cesty ven: vyplnit a uložit,
/// nebo nouzový únik – podržet Esc 5 s (zapíše se do deníku výjimek jako selhání).
@MainActor
final class ForcedReviewController {
    /// Čte `AppDelegate`, aby během review zablokoval ukončení aplikace.
    static private(set) var isActive = false

    private static let escapeHold: TimeInterval = 5

    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var escapeStarted: Date?
    private var keepFrontTimer: Timer?
    private var onClose: ((_ completed: Bool) -> Void)?

    func present(model: AppModel, onClose: @escaping (_ completed: Bool) -> Void) {
        guard !Self.isActive else { return }
        Self.isActive = true
        self.onClose = onClose

        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        for screen in NSScreen.screens {
            let panel = ReviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.appearance = NSAppearance(named: .darkAqua)

            let isPrimary = screen == primary
            let root = ForcedReviewView(isPrimary: isPrimary) { [weak self] completed in
                self?.close(completed: completed)
            }
            .environment(model)
            panel.contentView = NSHostingView(rootView: root)
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            isPrimary ? panel.makeKeyAndOrderFront(nil) : panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            for panel in panels { panel.animator().alphaValue = 1 }
        }

        installKeyMonitor()

        // Pojistka: když jiná aplikace vyskočí dopředu, vrať review nahoru.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.isActive else { return }
                for panel in self.panels { panel.orderFrontRegardless() }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        keepFrontTimer = timer
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let isEscape = event.keyCode == 53
            let isDown = event.type == .keyDown
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isEscape {
                    if isDown {
                        let start = self.escapeStarted ?? Date()
                        self.escapeStarted = start
                        if Date().timeIntervalSince(start) >= Self.escapeHold {
                            self.escapeStarted = nil
                            IntentLog.append(source: "Večerní review", reason: "Nouzový únik bez vyplnění")
                            self.close(completed: false)
                        }
                    } else {
                        self.escapeStarted = nil
                    }
                    return true
                }
                // ⌘Q / ⌘W / ⌘H během review nic nedělají.
                return isDown && modifiers.contains(.command)
            }
            return swallow ? nil : event
        }
    }

    private func close(completed: Bool) {
        guard Self.isActive else { return }
        Self.isActive = false
        keepFrontTimer?.invalidate()
        keepFrontTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            for panel in closing { panel.animator().alphaValue = 0 }
        } completionHandler: {
            for panel in closing {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
        onClose?(completed)
        onClose = nil
    }
}

private final class ReviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Obsah

private struct ForcedReviewView: View {
    let isPrimary: Bool
    let onClose: (_ completed: Bool) -> Void

    @Environment(AppModel.self) private var model
    @State private var answers: [String: Bool] = [:]
    @State private var saving = false
    @State private var error: String?
    @State private var failures = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.9).ignoresSafeArea()
            if isPrimary {
                content
            } else {
                Text("Evening review")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task {
            guard isPrimary else { return }
            await model.habits.refresh(force: true)
            prefill()
        }
    }

    private var habits: [HabitsService.Habit] { model.habits.habits }
    private var answeredAll: Bool { !habits.isEmpty && habits.allSatisfy { answers[$0.id] != nil } }
    private var yesCount: Int { answers.values.filter { $0 }.count }

    private var content: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Text("EVENING REVIEW")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.4))
                Text("No excuses. What did you actually do?")
                    .font(.system(size: 38, weight: .thin))
                Text("Focus \(model.stats.today.focus.hoursMinutes) · ztraceno \(model.stats.today.lost.hoursMinutes) · \(model.stats.verdict)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            if habits.isEmpty {
                loadingOrError
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(habits) { habit in
                            AnswerRow(name: habit.id, answer: answers[habit.id]) { answers[habit.id] = $0 }
                        }
                    }
                }
                .frame(maxWidth: 620, maxHeight: 460)

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                HStack(spacing: 12) {
                    Text(answeredAll ? "\(yesCount)/\(habits.count) splněno" : "Rozhodni u všech: \(answers.count)/\(habits.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                    Button(saving ? "Ukládám…" : "Uložit do Notionu", action: save)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(!answeredAll || saving)
                        .opacity(answeredAll ? 1 : 0.35)
                }
            }

            Text("Nouzový únik: podrž Esc 5 s – zapíše se jako selhání.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 6)
        }
        .padding(48)
    }

    @ViewBuilder
    private var loadingOrError: some View {
        switch model.habits.status {
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Notion nejde načíst: \(message)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 10) {
                    Button("Zkusit znovu") {
                        failures += 1
                        Task { await model.habits.refresh(force: true); prefill() }
                    }
                    .buttonStyle(GlassPillButtonStyle(size: 12))
                    if failures >= 2 {
                        Button("Pokračovat bez Notionu") {
                            IntentLog.append(source: "Večerní review", reason: "Notion nedostupný – review přeskočeno")
                            onClose(false)
                        }
                        .buttonStyle(GlassPillButtonStyle(size: 12))
                    }
                }
            }
        default:
            ProgressView().controlSize(.regular)
        }
    }

    private func prefill() {
        for habit in habits where habit.done && answers[habit.id] == nil {
            answers[habit.id] = true
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await model.habits.save(answers)
                onClose(true)
            } catch {
                self.error = "Uložení selhalo: \(error.localizedDescription)"
                saving = false
            }
        }
    }
}

private struct AnswerRow: View {
    let name: String
    let answer: Bool?
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 14, weight: answer == nil ? .regular : .medium))
                .foregroundStyle(.white.opacity(answer == nil ? 0.75 : 1))
                .lineLimit(2)
            Spacer(minLength: 12)
            choice("Ne", selected: answer == false) { set(false) }
            choice("Ano", selected: answer == true) { set(true) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel(radius: 14)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.7))
                .frame(width: 52, height: 26)
                .background(Capsule().fill(.white.opacity(selected ? 0.95 : 0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.12), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
