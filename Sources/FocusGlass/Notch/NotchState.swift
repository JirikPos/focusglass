import AppKit
import Observation
import SwiftUI

/// Rozměry výřezu kamery na dané obrazovce (nebo náhradní „kapsle“ na Macu bez výřezu).
struct NotchGeometry {
    let notchSize: CGSize
    let hasHardwareNotch: Bool

    init(screen: NSScreen) {
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

/// Stav notche: sbalený / rozbalený, vybraný panel, hover a přetahování souborů.
@MainActor
@Observable
final class NotchState {
    struct Compact: Equatable {
        enum Trailing: Equatable {
            case time
            case symbol(String)
        }

        let symbol: String
        let trailing: Trailing
        let wing: CGFloat
    }

    static let expandedWidth: CGFloat = 540
    static let expandedBodyHeight: CGFloat = 150
    /// Prostor kolem rozbaleného notche pro stín.
    static let shadowMargin: CGFloat = 30

    @ObservationIgnored unowned let model: AppModel
    let notchSize: CGSize

    private(set) var isExpanded = false
    var tab: NotchTab = .focus
    var isDropTargeted = false {
        didSet { if isDropTargeted != oldValue { dropTargetChanged() } }
    }

    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var pending: DispatchWorkItem?

    init(model: AppModel, geometry: NotchGeometry) {
        self.model = model
        self.notchSize = geometry.notchSize
    }

    // MARK: - Obsah a rozměry

    /// Co ukázat po stranách výřezu, když je notch sbalený.
    var compact: Compact? {
        let timer = model.timer
        if timer.hasStarted || timer.isAway {
            return Compact(symbol: timer.stateSymbol, trailing: .time, wing: 64)
        }
        if model.media.isPlaying {
            return Compact(symbol: "music.note", trailing: .symbol("waveform"), wing: 38)
        }
        return nil
    }

    var shapeSize: CGSize {
        if isExpanded {
            return CGSize(width: max(Self.expandedWidth, notchSize.width + 240),
                          height: notchSize.height + Self.expandedBodyHeight)
        }
        return CGSize(width: notchSize.width + (compact?.wing ?? 0) * 2, height: notchSize.height)
    }

    /// Velikost okna: sbalené přesně kopíruje tvar, rozbalené má navíc místo na stín.
    var windowSize: CGSize {
        let shape = shapeSize
        guard isExpanded else { return shape }
        return CGSize(width: shape.width + Self.shadowMargin * 2, height: shape.height + Self.shadowMargin)
    }

    /// Panel, který dává při otevření největší smysl.
    private var preferredTab: NotchTab {
        if model.timer.hasStarted || model.timer.isAway { return .focus }
        if model.media.isPlaying { return .media }
        if !model.shelf.items.isEmpty { return .shelf }
        return .focus
    }

    // MARK: - Interakce

    /// Volá hosting view při pohybu myši (souřadnice view, počátek vlevo dole).
    func mouseMoved(to point: CGPoint?, in bounds: CGRect) {
        guard let point else { return setHovering(false) }
        let size = shapeSize
        let shape = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
                           width: size.width, height: size.height)
        setHovering(shape.insetBy(dx: -2, dy: -2).contains(point))
    }

    func collapse() {
        pending?.cancel()
        setExpanded(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        schedule(expanded: hovering, after: hovering ? 0.12 : 0.3)
    }

    private func dropTargetChanged() {
        pending?.cancel()
        if isDropTargeted {
            tab = .shelf
            setExpanded(true, keepTab: true)
        } else if !isHovering {
            schedule(expanded: false, after: 0.6)
        }
    }

    private func schedule(expanded: Bool, after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setExpanded(expanded) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ expanded: Bool, keepTab: Bool = false) {
        guard expanded != isExpanded else { return }
        if expanded && !keepTab { tab = preferredTab }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            isExpanded = expanded
        }
    }
}
