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
    }

    struct Compact: Equatable {
        enum Trailing: Equatable {
            case time
            case symbol(String)
        }

        let symbol: String
        let trailing: Trailing
        let wing: CGFloat
    }

    /// Pružné „vynoření z kamery“ a o něco rychlejší zasunutí zpět.
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let closeAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    static let expandedWidth: CGFloat = 410
    static let expandedBodyHeight: CGFloat = 86
    /// Okraj okna kolem tvaru (rozbalený / sbalený), aby se záře vešla a neořízla.
    static let shadowMargin: CGFloat = 24
    static let glowMargin: CGFloat = 16

    @ObservationIgnored unowned let model: AppModel
    let notchSize: CGSize
    @ObservationIgnored private let screenFrame: CGRect

    private(set) var mode: Mode = .idle
    var tab: NotchTab = .focus
    var isDropTargeted = false {
        didSet { if isDropTargeted != oldValue { dropTargetChanged() } }
    }

    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var pending: DispatchWorkItem?
    /// Controller okna: zvětši okno hned teď (synchronně), než začne animace.
    @ObservationIgnored var prepareWindow: ((CGSize) -> Void)?

    init(model: AppModel, geometry: NotchGeometry) {
        self.model = model
        self.notchSize = geometry.notchSize
        self.screenFrame = geometry.screenFrame
    }

    var isExpanded: Bool { mode == .expanded }

    // MARK: - Obsah a rozměry

    /// Co ukázat po stranách výřezu v náhledu.
    var compact: Compact {
        let timer = model.timer
        if !timer.hasStarted && !timer.isAway && model.media.isPlaying {
            return Compact(symbol: "music.note", trailing: .symbol("waveform"), wing: 38)
        }
        return Compact(symbol: timer.stateSymbol, trailing: .time, wing: 60)
    }

    var expandedSize: CGSize {
        CGSize(width: max(Self.expandedWidth, notchSize.width + 220),
               height: notchSize.height + Self.expandedBodyHeight)
    }

    var compactSize: CGSize {
        CGSize(width: notchSize.width + compact.wing * 2, height: notchSize.height)
    }

    var shapeSize: CGSize { size(for: mode) }

    var windowSize: CGSize { windowSize(for: mode) }

    private func size(for mode: Mode) -> CGSize {
        switch mode {
        case .idle: notchSize
        case .peek: compactSize
        case .expanded: expandedSize
        }
    }

    private func windowSize(for mode: Mode) -> CGSize {
        let shape = size(for: mode)
        let margin = mode == .expanded ? Self.shadowMargin : Self.glowMargin
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

    private var isMouseInside: Bool {
        let size = shapeSize
        let shape = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        return shape.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
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
                // Pojistka: nezavírat, pokud je kurzor pořád na notchi.
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
        let growing = windowSize(for: newMode).height > windowSize.height
            || windowSize(for: newMode).width > windowSize.width
        // Okno zvětšit synchronně ještě před animací, jinak se první snímky oříznou.
        if growing { prepareWindow?(windowSize(for: newMode)) }
        withAnimation(growing ? Self.openAnimation : Self.closeAnimation) {
            mode = newMode
        }
    }
}
