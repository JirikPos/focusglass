import AppKit
import Observation
import SwiftUI

/// Rozměry výřezu kamery na dané obrazovce (nebo náhradní „kapsle“ na Macu bez výřezu).
struct NotchGeometry {
    let notchSize: CGSize
    let hasHardwareNotch: Bool
    let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                               height: screen.safeAreaInsets.top)
            hasHardwareNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 180, height: max(menuBar, 24))
            hasHardwareNotch = false
        }
    }

    /// Vestavěný displej s výřezem, jinak hlavní obrazovka.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
}

/// Stav notche: klid → náhled (hover) → otevřený (klik).
@MainActor
@Observable
final class NotchState {
    enum Mode {
        /// Jen černý výřez s jemným obrysem. Nic nepřekrývá lištu.
        case idle
        /// Najetí myší: po stranách výřezu ikona a čas.
        case peek
        /// Kliknutí: celý notch s panely.
        case expanded
        /// Krátké upozornění (např. rozptýlení).
        case alert
        /// Otázka „proč tam chceš jít?“ s textovým polem (blokovaný web / aplikace).
        case intent
        /// Otázka se dvěma tlačítky (např. „Spustit focus?“).
        case prompt
    }

    struct Prompt {
        let symbol: String
        let title: String
        let detail: String
        let primaryTitle: String
        let primary: () -> Void
        let secondaryTitle: String
        let secondary: () -> Void
    }

    /// Žádost o důvod. `submit(reason)` pustí dovnitř, `cancel()` nechá blokaci.
    struct IntentRequest {
        let source: String
        let minutes: Int
        let submit: (String) -> Void
        let cancel: () -> Void
    }

    struct Compact: Equatable {
        let symbol: String
        /// Text vedle ikony vlevo (např. minuty do schůzky).
        let leadingText: String?
        let wing: CGFloat
    }

    struct Alert: Equatable {
        let title: String
        let detail: String
    }

    /// Pružné „vynoření z kamery“ a o něco rychlejší zasunutí zpět.
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let closeAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    static let expandedWidth: CGFloat = 480
    static let alertBodyHeight: CGFloat = 52
    static let intentBodyHeight: CGFloat = 96
    static let promptBodyHeight: CGFloat = 56
    static let minimumReasonLength = 15
    static let expandedBodyHeight: CGFloat = 86
    /// Okraj okna kolem tvaru (rozbalený / sbalený), aby se záře vešla a neořízla.
    static let shadowMargin: CGFloat = 24
    static let glowMargin: CGFloat = 16

    @ObservationIgnored unowned let model: AppModel
    let notchSize: CGSize
    @ObservationIgnored private let screenFrame: CGRect

    private(set) var mode: Mode = .idle
    private(set) var alert: Alert?
    @ObservationIgnored private(set) var intent: IntentRequest?
    @ObservationIgnored private(set) var prompt: Prompt?
    private(set) var promptID = UUID()
    /// Mění se s každou novou žádostí (resetuje textové pole).
    private(set) var intentID = UUID()
    var tab: NotchTab = .focus
    var isDropTargeted = false {
        didSet { if isDropTargeted != oldValue { dropTargetChanged() } }
    }

    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var pending: DispatchWorkItem?
    /// Controller okna: zvětši okno hned teď (synchronně), než začne animace.
    @ObservationIgnored var prepareWindow: ((CGSize) -> Void)?
    /// Controller okna: změna režimu (klávesnice jen v otevřeném notchi).
    @ObservationIgnored var onModeChange: ((Mode) -> Void)?

    init(model: AppModel, geometry: NotchGeometry) {
        self.model = model
        self.notchSize = geometry.notchSize
        self.screenFrame = geometry.screenFrame
    }

    var isExpanded: Bool { mode == .expanded }

    // MARK: - Obsah a rozměry

    /// Co ukázat po stranách výřezu v náhledu.
    var compact: Compact {
        if let minutes = model.calendar.minutesUntilNext, minutes <= 30 {
            return Compact(symbol: "calendar", leadingText: "\(minutes)m", wing: 60)
        }
        return Compact(symbol: model.timer.stateSymbol, leadingText: nil, wing: 60)
    }

    var expandedSize: CGSize {
        CGSize(width: max(Self.expandedWidth, notchSize.width + 290),
               height: notchSize.height + Self.expandedBodyHeight)
    }

    var compactSize: CGSize {
        CGSize(width: notchSize.width + compact.wing * 2, height: notchSize.height)
    }

    var shapeSize: CGSize { size(for: mode) }

    var windowSize: CGSize { windowSize(for: mode) }

    func size(for mode: Mode) -> CGSize {
        switch mode {
        case .idle: notchSize
        case .peek: compactSize
        case .expanded: expandedSize
        case .alert: CGSize(width: expandedSize.width, height: notchSize.height + Self.alertBodyHeight)
        case .intent: CGSize(width: expandedSize.width, height: notchSize.height + Self.intentBodyHeight)
        case .prompt: CGSize(width: expandedSize.width, height: notchSize.height + Self.promptBodyHeight)
        }
    }

    private func windowSize(for mode: Mode) -> CGSize {
        let shape = size(for: mode)
        let margin = (mode == .idle || mode == .peek) ? Self.glowMargin : Self.shadowMargin
        return CGSize(width: shape.width + margin * 2, height: shape.height + margin)
    }

    /// Panel, který dává při otevření největší smysl.
    private var preferredTab: NotchTab {
        if model.timer.hasStarted || model.timer.isAway { return .focus }
        if model.media.isPlaying { return .media }
        if !model.shelf.items.isEmpty { return .shelf }
        return .focus
    }

    // MARK: - Interakce

    /// Volá hosting view při jakékoli události myši. Rozhoduje skutečná poloha kurzoru,
    /// ne enter/exit události – ty macOS posílá i při změně velikosti okna.
    func mouseChanged() {
        setHovering(isMouseInside)
    }

    /// Klik na notch v klidu nebo náhledu otevře celý notch.
    func click() {
        guard mode != .expanded else { return }
        pending?.cancel()
        setMode(.expanded)
    }

    /// Vývoj: rovnou otevřít (`--notch-open`).
    func expand() {
        pending?.cancel()
        setMode(.expanded)
    }

    /// Klávesová zkratka: otevřít / zavřít.
    func toggle() {
        pending?.cancel()
        setMode(mode == .expanded ? .idle : .expanded)
    }

    func open(tab: NotchTab) {
        pending?.cancel()
        self.tab = tab
        setMode(.expanded, keepTab: true)
    }

    func collapseNow() {
        pending?.cancel()
        setMode(.idle)
    }

    /// Otázka na důvod. Zůstane otevřená, dokud neodpovíš nebo nezmáčkneš Esc.
    func askIntent(_ request: IntentRequest) {
        intent?.cancel()
        pending?.cancel()
        intent = request
        intentID = UUID()
        setMode(.intent)
    }

    /// `reason == nil` = zrušeno.
    func resolveIntent(reason: String?) {
        guard let request = intent else { return }
        intent = nil
        if let reason { request.submit(reason) } else { request.cancel() }
        setMode(.idle)
    }

    /// Otázka se dvěma tlačítky. Bez reakce se po 15 s sama schová.
    func showPrompt(_ prompt: Prompt) {
        guard mode == .idle || mode == .peek || mode == .alert else { return }
        pending?.cancel()
        self.prompt = prompt
        promptID = UUID()
        setMode(.prompt)
        schedule(.idle, after: 15)
    }

    func resolvePrompt(primary: Bool) {
        guard let prompt else { return }
        self.prompt = nil
        primary ? prompt.primary() : prompt.secondary()
        pending?.cancel()
        setMode(.idle)
    }

    /// Krátké upozornění, které se samo schová (pokud na něm nemáš myš).
    func showAlert(_ alert: Alert) {
        guard mode != .expanded, mode != .intent, mode != .prompt else { return }
        pending?.cancel()
        self.alert = alert
        setMode(.alert)
        schedule(.idle, after: 5)
    }

    private var isMouseInside: Bool {
        let size = shapeSize
        let shape = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        return shape.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        // Otázka na důvod se myší nezavírá.
        guard mode != .intent else { return }
        // Otázka s tlačítky: na myši čeká, po odjetí dá ještě chvíli na rozmyšlenou.
        if mode == .prompt {
            hovering ? pending?.cancel() : schedule(.idle, after: 8)
            return
        }
        if hovering {
            if mode == .idle { schedule(.peek, after: 0.08) } else { pending?.cancel() }
        } else {
            schedule(.idle, after: 0.3)
        }
    }

    private func dropTargetChanged() {
        pending?.cancel()
        if isDropTargeted {
            tab = .shelf
            setMode(.expanded, keepTab: true)
        } else if !isHovering {
            schedule(.idle, after: 0.6)
        }
    }

    private func schedule(_ target: Mode, after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Pojistka: nezavírat, pokud je kurzor pořád na notchi nebo čeká otázka.
                if target == .idle && self.mode == .intent { return }
                if target == .idle && (self.isMouseInside || self.isDropTargeted) {
                    self.isHovering = true
                    return
                }
                self.setMode(target)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setMode(_ newMode: Mode, keepTab: Bool = false) {
        guard newMode != mode else { return }
        if newMode == .expanded && !keepTab { tab = preferredTab }
        if newMode == .expanded || newMode == .peek { model.calendar.refresh() }
        if !tab.isAvailable(model.settings) { tab = .focus }
        let growing = windowSize(for: newMode).height > windowSize.height
            || windowSize(for: newMode).width > windowSize.width
        // Okno zvětšit synchronně ještě před animací, jinak se první snímky oříznou.
        if growing { prepareWindow?(windowSize(for: newMode)) }
        withAnimation(growing ? Self.openAnimation : Self.closeAnimation) {
            mode = newMode
        }
        onModeChange?(newMode)
    }
}
