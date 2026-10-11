import AppKit
import SwiftUI

enum OverlayMode {
    /// Minuta pro oči s cvičením.
    case eyes
    /// Velká pauza po pracovním bloku.
    case rest

    var headline: String {
        switch self {
        case .eyes: "Rest your eyes"
        case .rest: "Take a break"
        }
    }
}

// MARK: - Panel

/// Bezrámový průhledný panel, který přijímá klávesnici, aniž by aktivoval aplikaci.
private final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Ztmaví všechny obrazovky. Obsah ukáže na té, kde je myš; mimo zobrazení nedrží nic v paměti.
@MainActor
final class OverlayController {
    private var panels: [OverlayPanel] = []
    private var keyMonitor: Any?
    private var autoClose: Timer?
    private var onFinish: ((_ finished: Bool) -> Void)?

    func present(
        mode: OverlayMode,
        quote: Quote,
        until end: Date,
        onSkip: (() -> Void)? = nil,
        onFinish: ((_ finished: Bool) -> Void)? = nil
    ) {
        dismiss(animated: false)
        self.onFinish = onFinish

        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let start = Date()

        for screen in NSScreen.screens {
            let isPrimary = screen == primary
            let view = OverlayView(
                mode: mode,
                quote: quote,
                start: start,
                end: end,
                isPrimary: isPrimary,
                onSkip: onSkip,
                onClose: { [weak self] in self?.dismiss() }
            )
            let panel = OverlayPanel(frame: screen.frame)
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(screen.frame, display: false)
            panel.onEscape = { [weak self] in self?.dismiss() }
            panel.alphaValue = 0
            if isPrimary {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            panels.append(panel)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            for panel in panels { panel.animator().alphaValue = 1 }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }

        let closeTimer = Timer(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(finished: true) }
        }
        RunLoop.main.add(closeTimer, forMode: .common)
        autoClose = closeTimer
    }

    /// - Parameter finished: `true`, pokud overlay doběhl sám (ne Esc / tlačítkem).
    func dismiss(finished: Bool = false, animated: Bool = true) {
        autoClose?.invalidate()
        autoClose = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        let closing = panels
        panels = []
        let callback = onFinish
        onFinish = nil

        for panel in closing { panel.onEscape = nil }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                for panel in closing { panel.animator().alphaValue = 0 }
            } completionHandler: {
                for panel in closing {
                    panel.orderOut(nil)
                    panel.contentView = nil
                }
            }
        } else {
            for panel in closing {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }

        callback?(finished)
    }
}

// MARK: - SwiftUI obsah

private struct OverlayView: View {
    let mode: OverlayMode
    let quote: Quote
    let start: Date
    let end: Date
    let isPrimary: Bool
    let onSkip: (() -> Void)?
    let onClose: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Backdrop()

            Group {
                if isPrimary {
                    switch mode {
                    case .eyes: EyesContent(quote: quote, start: start, end: end, onClose: onClose)
                    case .rest: RestContent(quote: quote, start: start, end: end, onSkip: onSkip, onClose: onClose)
                    }
                } else {
                    Text(mode.headline)
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .blur(radius: appeared ? 0 : 8)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.easeOut(duration: 1).delay(0.15)) { appeared = true }
        }
    }
}

/// Matně černé sklo přes celou obrazovku.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.86)
            RadialGradient(
                colors: [.white.opacity(0.045), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 760
            )
        }
        .ignoresSafeArea()
    }
}

private struct EyesContent: View {
    let quote: Quote
    let start: Date
    let end: Date
    let onClose: () -> Void

    private var total: TimeInterval { end.timeIntervalSince(start) }
    private var stepLength: TimeInterval { total / Double(EyeStep.allCases.count) }

    private func elapsed(at date: Date) -> TimeInterval {
        min(total, max(0, date.timeIntervalSince(start)))
    }

    var body: some View {
        // Texty se mění jen jednou za sekundu; plynule (30 fps) se kreslí jen animace a linka.
        TimelineView(.periodic(from: start, by: 1)) { context in
            let left = total - elapsed(at: context.date)
            let step = EyeStep(index: Int(elapsed(at: context.date) / stepLength))

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(OverlayMode.eyes.headline)
                    .font(.system(size: 56, weight: .thin))
                    .tracking(0.5)

                StepDots(current: step.rawValue, count: EyeStep.allCases.count)
                    .padding(.top, 24)

                TimelineView(.animation(minimumInterval: 1 / 30)) { frame in
                    let now = elapsed(at: frame.date)
                    let current = EyeStep(index: Int(now / stepLength))
                    EyeExerciseView(step: current, time: now - Double(current.rawValue) * stepLength)
                }
                .frame(width: 460, height: 240)
                .padding(.vertical, 36)

                VStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: 22, weight: .regular))
                    Text(step.detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .id(step)
                .transition(.opacity)

                Spacer(minLength: 0)

                QuoteFooter(quote: quote)

                VStack(spacing: 14) {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { frame in
                        CountdownLine(fraction: 1 - elapsed(at: frame.date) / total)
                    }
                    .frame(height: 2)
                    HStack(spacing: 10) {
                        Text(left.clock)
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                        Button(action: onClose) {
                            HStack(spacing: 8) {
                                Text("Skip")
                                Keycap(text: "esc")
                            }
                        }
                        .buttonStyle(GlassPillButtonStyle())
                    }
                }
                .padding(.top, 36)
            }
            .padding(.vertical, 90)
            .animation(.easeInOut(duration: 0.8), value: step)
        }
    }
}

private struct RestContent: View {
    let quote: Quote
    let start: Date
    let end: Date
    let onSkip: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let total = max(1, end.timeIntervalSince(start))
            let left = max(0, end.timeIntervalSince(context.date))

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(OverlayMode.rest.headline)
                    .font(.system(size: 56, weight: .thin))
                    .tracking(0.5)

                Text(left.clock)
                    .font(.system(size: 128, weight: .ultraLight))
                    .monospacedDigit()
                    .padding(.top, 8)

                Text("Stand up. Walk away. Drink some water. Let your eyes wander.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer(minLength: 0)

                QuoteFooter(quote: quote)

                VStack(spacing: 18) {
                    CountdownLine(fraction: left / total)
                        .animation(.linear(duration: 1), value: left)
                    HStack(spacing: 10) {
                        if let onSkip {
                            Button("Skip break", action: onSkip)
                                .buttonStyle(GlassPillButtonStyle())
                        }
                        Button(action: onClose) {
                            HStack(spacing: 8) {
                                Text("Hide")
                                Keycap(text: "esc")
                            }
                        }
                        .buttonStyle(GlassPillButtonStyle())
                    }
                    Text("The break keeps running in the menu bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.top, 36)
            }
            .padding(.vertical, 90)
        }
    }
}

private struct QuoteFooter: View {
    let quote: Quote

    var body: some View {
        VStack(spacing: 6) {
            Text("“\(quote.text)”")
                .font(.system(size: 15, weight: .light))
                .italic()
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            Text(quote.author.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: 560)
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == current ? 0.9 : 0.2))
                    .frame(width: index == current ? 18 : 5, height: 5)
            }
        }
    }
}
