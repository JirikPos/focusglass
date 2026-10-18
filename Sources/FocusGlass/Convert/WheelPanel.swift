import AppKit
import ConvertKit
import SwiftUI

/// Průhledný panel s kolem. Je cílem pro puštění souboru; při ovládání klávesnicí bere klávesy,
/// ale nikdy neaktivuje aplikaci (Finder zůstane vpředu).
private final class WheelPanel: NSPanel {
    var acceptsKey = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: WheelLayout.size),
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
        level = .popUpMenu
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// Obsah panelu: SwiftUI kolo + AppKit cíl puštění a klávesnice.
private final class WheelDropView: NSView {
    weak var controller: WheelController?
    private let hosting: NSHostingView<WheelView>

    init(model: WheelModel) {
        hosting = NSHostingView(rootView: WheelView(model: model))
        super.init(frame: NSRect(origin: .zero, size: WheelLayout.size))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Tažení jde vždy do této vrstvy, ne do SwiftUI pod ní.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Lístek pod bodem v souřadnicích okna.
    private func segment(at windowPoint: NSPoint) -> Int? {
        let point = convert(windowPoint, from: nil)
        // Střed kola v AppKitu (y nahoru): kolo je v horní části panelu, pod ním patička.
        let centerY = bounds.height - WheelLayout.center.y
        return controller?.model.geometry.segment(dx: point.x - bounds.midX, dy: point.y - centerY)
    }

    // MARK: Puštění

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.hover(segment(at: sender.draggingLocation))
        return Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        controller?.hover(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        controller?.canDrop(at: segment(at: sender.draggingLocation)) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard let index = segment(at: sender.draggingLocation), !urls.isEmpty else { return false }
        return controller?.drop(at: index, urls: urls) ?? false
    }

    /// Nikdy nepřesouvat originál: přednost má kopie, pak obecná operace.
    /// (S podrženým ⌘ Finder nabízí jen přesun – i tak soubor jen čteme.)
    private static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for candidate: NSDragOperation in [.copy, .generic, .link, .move] where mask.contains(candidate) {
            return candidate
        }
        return []
    }

    // MARK: Klávesnice

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch Int(event.keyCode) {
        case 53: controller.close()                       // Esc
        case 36, 76, 49: controller.pickHovered()          // Enter, numerický Enter, mezerník
        case 124, 125: controller.moveSelection(by: 1)     // → ↓
        case 123, 126: controller.moveSelection(by: -1)    // ← ↑
        case 48: controller.cycleWheel(backwards: event.modifierFlags.contains(.shift)) // Tab
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.modifiersChanged(event.modifierFlags)
    }
}

/// Ví, jestli poslední tažení z vlastní aplikace skončilo na kole (odkladiště pak soubor neodebere).
@MainActor
enum WheelDropTracker {
    private static var dropped = false

    static func markDropped() { dropped = true }

    /// Vrátí a vynuluje příznak.
    static func consume() -> Bool {
        defer { dropped = false }
        return dropped
    }
}

/// Otevírá, umisťuje a zavírá kolo.
@MainActor
final class WheelController {
    let model = WheelModel()
    /// Vybraný lístek (myší i klávesnicí). Kolo je v tu chvíli už zavřené.
    var onPick: ((WheelItem, Selection) -> Void)?
    /// Kolo se přepnulo (klávesou) – volající dodá položky.
    var onSwitch: ((Wheel) -> Void)?
    var onClose: (() -> Void)?
    /// Klávesa → kolo (z nastavení).
    var wheelForFlags: ((NSEvent.ModifierFlags) -> Wheel?)?

    private var panel: WheelPanel?
    private var moreWork: DispatchWorkItem?
    private var lastFlags: NSEvent.ModifierFlags = []
    private(set) var isKeyboard = false

    var isOpen: Bool { panel != nil }

    /// Otevře kolo se středem v `point` (souřadnice obrazovky), případně jen přepne obsah.
    func present(_ wheel: Wheel, selection: Selection, items: [WheelItem], at point: NSPoint, keyboard: Bool) {
        model.show(wheel, selection: selection, items: items)
        if keyboard, model.hovered == nil, !model.visibleItems.isEmpty { model.hovered = 0 }
        guard panel == nil else { return }

        isKeyboard = keyboard
        lastFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let panel = WheelPanel()
        let view = WheelDropView(model: model)
        view.controller = self
        panel.contentView = view
        panel.acceptsKey = keyboard
        panel.setFrame(Self.frame(centeredAt: point), display: false)
        self.panel = panel
        if keyboard {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func update(_ wheel: Wheel, selection: Selection, items: [WheelItem]) {
        model.show(wheel, selection: selection, items: items)
        if isKeyboard, !model.visibleItems.isEmpty { model.hovered = 0 }
    }

    func close() {
        moreWork?.cancel()
        moreWork = nil
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
        onClose?()
    }

    // MARK: Volané z panelu

    fileprivate func hover(_ index: Int?) {
        guard index != model.hovered else { return }
        model.hovered = index
        moreWork?.cancel()
        moreWork = nil
        guard let index, model.visibleItems.indices.contains(index) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // Podržet kurzor nad „Další“ = další stránka (při tažení nejde kliknout).
        if model.visibleItems[index].target == .more {
            let work = DispatchWorkItem { [weak self] in self?.model.nextPage() }
            moreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    fileprivate func canDrop(at index: Int?) -> Bool {
        guard let index, model.visibleItems.indices.contains(index) else { return false }
        let item = model.visibleItems[index]
        return item.isEnabled && item.target != .more
    }

    fileprivate func drop(at index: Int, urls: [URL]) -> Bool {
        guard canDrop(at: index) else { return false }
        let item = model.visibleItems[index]
        // Pasteboard puštění je autoritativní (výběr se mohl změnit od začátku tažení).
        let selection = Selection(urls: urls)
        WheelDropTracker.markDropped()
        DispatchQueue.main.async { [weak self] in
            self?.close()
            self?.onPick?(item, selection)
        }
        return true
    }

    fileprivate func pickHovered() {
        guard let item = model.hoveredItem else { return }
        if item.target == .more { return model.nextPage() }
        guard item.isEnabled else { return NSSound.beep() }
        let selection = model.selection
        close()
        onPick?(item, selection)
    }

    fileprivate func moveSelection(by step: Int) {
        model.hovered = model.geometry.step(from: model.hovered, by: step)
    }

    fileprivate func cycleWheel(backwards: Bool) {
        let all = Wheel.allCases
        let index = all.firstIndex(of: model.wheel) ?? 0
        let next = all[(index + (backwards ? all.count - 1 : 1)) % all.count]
        onSwitch?(next)
    }

    /// Při klávesnicovém ovládání přepíná kola stisk modifikátoru (stejně jako při tažení).
    fileprivate func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        if !pressed.isEmpty, let wheel = wheelForFlags?(pressed), wheel != model.wheel {
            onSwitch?(wheel)
        }
    }

    // MARK: Umístění

    /// Rámec panelu tak, aby střed kola byl v bodě – ale celé kolo na obrazovce.
    private static func frame(centeredAt point: NSPoint) -> NSRect {
        let size = WheelLayout.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - (size.height - WheelLayout.center.y))
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.frame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }
}
