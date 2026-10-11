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

    /// Klávesnici bere jen otevřený notch (Esc, mezerník pro náhled).
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view, který hlásí události myši (hover funguje, i když je aplikace neaktivní)
/// a reaguje na první kliknutí bez nutnosti aktivace.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onMouse: (() -> Void)?
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
        onMouse?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouse?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouse?()
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

    /// Vývoj: rozbalí notch bez myši (`--notch-open`).
    func expandForPreview() {
        state?.expand()
    }

    func toggle() { state?.toggle() }
    func open(tab: NotchTab) { state?.open(tab: tab) }
    func showAlert(title: String, detail: String) {
        state?.showAlert(NotchState.Alert(title: title, detail: detail))
    }

    func peekShelf() { state?.peekShelf() }

    func showBattery(percent: Int, charging: Bool) {
        state?.showBattery(NotchState.BatteryInfo(percent: percent, charging: charging))
    }

    @discardableResult
    func showTaskPicker(_ request: NotchState.TaskPickerRequest) -> Bool {
        guard let state else { return false }
        state.showTaskPicker(request)
        return true
    }

    @discardableResult
    func showTaskReview(_ request: NotchState.TaskReviewRequest) -> Bool {
        guard let state else { return false }
        state.showTaskReview(request)
        return true
    }

    /// Vrací `false`, pokud notch neběží.
    @discardableResult
    func showPrompt(_ prompt: NotchState.Prompt) -> Bool {
        guard let state else { return false }
        state.showPrompt(prompt)
        return true
    }

    /// Vrací `false`, pokud notch neběží (pak se zeptat nejde).
    func askIntent(_ request: NotchState.IntentRequest) -> Bool {
        guard let state else { return false }
        state.askIntent(request)
        return true
    }

    private func rebuild() {
        guard panel != nil else { return }
        hide()
        show()
    }

    private func show() {
        guard panel == nil, let screen = NotchGeometry.preferredScreen() else { return }
        let state = NotchState(model: model, geometry: NotchGeometry(screen: screen))

        let host = NotchHostingView(
            rootView: NotchView().environment(model).environment(state).ignoresSafeArea()
        )
        // Okno řídíme sami: hosting view nesmí měnit velikost okna ani řešit
        // bezpečnou oblast kolem výřezu (jinak se layout zacyklí).
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        state.prepareWindow = { [weak self] size in
            self?.growImmediately(to: size)
        }
        state.onModeChange = { [weak self] mode in
            self?.modeChanged(mode)
        }
        host.onMouse = { [weak state] in
            MainActor.assumeIsolated { state?.mouseChanged() }
        }

        let container = NSView()
        container.addSubview(host)

        let panel = NotchPanel()
        panel.contentView = container
        host.frame = container.bounds
        self.panel = panel
        self.state = state
        self.screen = screen
        appliedSize = .zero
        generation += 1

        applyFrame()
        panel.orderFrontRegardless()
        NotchSpace.shared.add(panel)
        observeSize(generation: generation)
    }

    private func hide() {
        removeKeyMonitor()
        shrinkWork?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = nil
        generation += 1
    }

    // MARK: - Klávesnice

    private var keyMonitor: Any?

    /// Otevřený notch převezme klávesnici (Esc zavře, mezerník = rychlý náhled souboru).
    /// Po zavření ji vrátí aplikaci, ve které jsi pracoval.
    private func modeChanged(_ mode: NotchState.Mode) {
        guard let panel else { return }
        if mode.takesKeyboard, state?.passiveExpand != true {
            panel.allowsKey = true
            panel.makeKey()
            installKeyMonitor()
        } else if panel.allowsKey {
            panel.allowsKey = false
            removeKeyMonitor()
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
                NotchSpace.shared.add(panel)
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let state = self.state else { return false }
                if state.mode.isSticky {
                    guard keyCode == 53 else { return false } // jinak píšeš do pole
                    switch state.mode {
                    case .intent: state.resolveIntent(reason: nil)
                    case .tasks: state.resolveTaskPicker(nil)
                    case .review: state.resolveTaskReview([:])
                    default: break
                    }
                    return true
                }
                guard state.isExpanded else { return false }
                switch keyCode {
                case 53: // Esc
                    state.collapseNow()
                    return true
                case 49 where state.tab == .shelf: // mezerník
                    self.model.shelf.quickLook()
                    return true
                default:
                    return false
                }
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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

    /// Zvětší okno okamžitě (jen zvětšuje, zmenšení řeší `applyFrame` po animaci).
    private func growImmediately(to size: CGSize) {
        guard let panel, let screen else { return }
        shrinkWork?.cancel()
        let union = CGSize(width: max(size.width, appliedSize.width),
                           height: max(size.height, appliedSize.height))
        guard union != appliedSize else { return }
        setFrame(union, panel: panel, screen: screen)
        // Ať SwiftUI zná novou velikost dřív, než začne animovat.
        panel.contentView?.layoutSubtreeIfNeeded()
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
