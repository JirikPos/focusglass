import AppKit
import SwiftUI

/// Průhledná AppKit vrstva přes dlaždici souboru. SwiftUI `onDrag` neříká, jestli přetažení
/// skončilo úspěšně – tahle vrstva ano, takže umíme soubor po vytažení odebrat.
/// Zároveň řeší dvojklik, hover a kontextové menu.
struct ShelfDragSource: NSViewRepresentable {
    let url: URL
    let icon: NSImage
    var onHover: (Bool) -> Void
    var onOpen: () -> Void
    var onDragCompleted: () -> Void
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: DragSourceView) {
        view.url = url
        view.icon = icon
        view.onHover = onHover
        view.onOpen = onOpen
        view.onDragCompleted = onDragCompleted
        view.makeMenu = menu
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var icon: NSImage?
    var onHover: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onDragCompleted: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    private var mouseDownEvent: NSEvent?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onOpen?()
        } else {
            mouseDownEvent = event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let url else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: down, source: self)
        // Globální monitor tažení z vlastní aplikace nevidí – kolo souborů se to dozví takhle.
        NotificationCenter.default.post(name: .focusGlassDragBegan, object: [url])
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Jen kopie: Finder soubor zkopíruje, originál zůstane na místě.
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NotificationCenter.default.post(name: .focusGlassDragEnded, object: nil)
        // Puštění na kolo souborů soubor jen čte – z odkladiště ho neodebírat.
        if !operation.isEmpty, !WheelDropTracker.consume() { onDragCompleted?() }
    }
}

/// Položka menu s closure místo target/action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
