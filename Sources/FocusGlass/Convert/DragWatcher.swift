import AppKit
import ConvertKit

extension Notification.Name {
    /// Tažení souboru z vlastního okna (odkladiště, Float) – globální monitor ho nevidí.
    /// `object` je `[URL]`.
    static let focusGlassDragBegan = Notification.Name("FocusGlassDragBegan")
    static let focusGlassDragEnded = Notification.Name("FocusGlassDragEnded")
}

/// Pozná, že uživatel táhne soubory (odkudkoli), a hlásí nově stisknuté modifikátory.
///
/// Nepotřebuje žádné oprávnění: globální monitor myši + čítač změn tažného pasteboardu
/// (stejný princip jako Dropover). Modifikátory a tlačítko myši se během tažení čtou z globálního
/// stavu klávesnice, protože jiná aplikace má v tu chvíli myš „zabranou“.
@MainActor
final class DragWatcher {
    var onBegan: ((Selection) -> Void)?
    /// Nově stisknuté modifikátory během tažení.
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onEscape: (() -> Void)?
    var onEnded: (() -> Void)?

    private(set) var selection: Selection?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var changeCountAtDown = 0
    private var poll: Timer?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var releasedPolls = 0
    private var escapeDown = false

    private static var dragPasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }) { monitors.append(dragged) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .focusGlassDragBegan, object: nil, queue: .main) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            MainActor.assumeIsolated { self?.begin(urls) }
        })
        observers.append(center.addObserver(forName: .focusGlassDragEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        })
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        end()
    }

    private func mouseDown() {
        changeCountAtDown = Self.dragPasteboard.changeCount
        if selection != nil { end() }
    }

    private func mouseDragged() {
        guard selection == nil else { return }
        let pasteboard = Self.dragPasteboard
        // Pasteboard se změní, až když systém tažení opravdu zahájí (ne při každém posunu myši).
        guard pasteboard.changeCount != changeCountAtDown else { return }
        changeCountAtDown = pasteboard.changeCount
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        begin(urls)
    }

    private func begin(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        selection = Selection(urls: urls)
        // Klávesy držené už před tažením se nepočítají (⌘ při přesunu ve Finderu je běžný).
        lastFlags = Self.currentFlags
        releasedPolls = 0
        escapeDown = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        if let selection { onBegan?(selection) }
    }

    private func tick() {
        let flags = Self.currentFlags
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        if !pressed.isEmpty { onModifiers?(pressed) }

        let escape = CGEventSource.keyState(.combinedSessionState, key: 53)
        if escape, !escapeDown { onEscape?() }
        escapeDown = escape

        // Konec tažení: tlačítko myši puštěné ~100 ms (puštění souboru na kolo mezitím doběhne).
        if NSEvent.pressedMouseButtons & 1 == 0 {
            releasedPolls += 1
            if releasedPolls >= 6 { end() }
        } else {
            releasedPolls = 0
        }
    }

    private func end() {
        poll?.invalidate()
        poll = nil
        guard selection != nil else { return }
        selection = nil
        onEnded?()
    }

    private static var currentFlags: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
    }
}
