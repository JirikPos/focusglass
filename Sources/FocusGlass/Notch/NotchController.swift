import AppKit
import Observation
import SwiftUI

/// Průhledný panel nad lištou. Nikdy nebere klávesnici ani fokus jiným aplikacím.
private final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
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
        isMovable = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view, který hlásí pohyb myši (hover funguje, i když je aplikace neaktivní)
/// a reaguje na první kliknutí bez nutnosti aktivace.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onMouse: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouse?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouse?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouse?(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Vytváří a umisťuje okno notche. Okno má vždy jen velikost aktuálního tvaru,
/// takže nikde jinde neblokuje kliknutí do lišty ani oken pod ním.
@MainActor
final class NotchController {
    private unowned let model: AppModel
    private var panel: NotchPanel?
    private var state: NotchState?
    private var screen: NSScreen?
    private var appliedSize: CGSize = .zero
    private var shrinkWork: DispatchWorkItem?
    /// Zneplatní sledování starého stavu po přestavění okna.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? show() : hide()
    }

    private func rebuild() {
        guard panel != nil else { return }
        hide()
        show()
    }

    private func show() {
        guard panel == nil, let screen = NotchGeometry.preferredScreen() else { return }
        let state = NotchState(model: model, geometry: NotchGeometry(screen: screen))

        let host = NotchHostingView(rootView: NotchView().environment(model).environment(state))
        host.sizingOptions = []
        host.onMouse = { [weak state, weak host] point in
            guard let host else { return }
            MainActor.assumeIsolated { state?.mouseMoved(to: point, in: host.bounds) }
        }

        let panel = NotchPanel()
        panel.contentView = host
        self.panel = panel
        self.state = state
        self.screen = screen
        appliedSize = .zero
        generation += 1

        applyFrame()
        panel.orderFrontRegardless()
        observeSize(generation: generation)
    }

    private func hide() {
        shrinkWork?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = nil
        generation += 1
    }

    /// Sleduje potřebnou velikost okna bez jakéhokoli dotazování.
    private func observeSize(generation: Int) {
        guard let state, generation == self.generation else { return }
        withObservationTracking {
            _ = state.windowSize
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.applyFrame()
                    self.observeSize(generation: generation)
                }
            }
        }
    }

    /// Zvětšení hned (ať animace nic neořízne), zmenšení až po doběhnutí animace.
    private func applyFrame() {
        guard let panel, let state, let screen else { return }
        let target = state.windowSize
        guard target != appliedSize else { return }

        shrinkWork?.cancel()
        let union = CGSize(width: max(target.width, appliedSize.width),
                           height: max(target.height, appliedSize.height))
        if union != appliedSize {
            setFrame(union, panel: panel, screen: screen)
        }
        guard union != target else { return }

        let work = DispatchWorkItem { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, self.state?.windowSize == target else { return }
                self.setFrame(target, panel: panel, screen: screen)
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func setFrame(_ size: CGSize, panel: NSPanel, screen: NSScreen) {
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height.rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
        panel.setFrame(frame, display: true)
        appliedSize = size
    }
}
