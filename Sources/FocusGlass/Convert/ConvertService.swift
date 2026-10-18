import AppKit
import SwiftUI
import ConvertKit
import Observation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "convert")

/// Kolo souborů: hlídá tažení, otevírá kolo, spouští převody a akce.
@MainActor
@Observable
final class ConvertService {
    /// Běžící a nedávno dokončené úlohy (nejnovější první).
    private(set) var jobs: [JobSnapshot] = []

    @ObservationIgnored let registry = Catalog.makeRegistry()
    @ObservationIgnored let tools = ToolLocator.shared
    @ObservationIgnored let queue = JobQueue()
    @ObservationIgnored let actions = FileActionPerformer()
    /// Hotové soubory (do odkladiště).
    @ObservationIgnored var onFinished: (([URL]) -> Void)?
    /// Souhrnný průběh běžících úloh (0…1, počet); `nil` = nic neběží.
    @ObservationIgnored var onProgress: ((progress: Double, count: Int)?) -> Void = { _ in }
    /// Krátká zpráva v notchi.
    @ObservationIgnored var onMessage: ((_ title: String, _ detail: String) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let watcher = DragWatcher()
    @ObservationIgnored private let wheel = WheelController()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    private static let historyLimit = 50

    init(settings: AppSettings) {
        self.settings = settings
        actions.onMessage = { [weak self] title, detail in self?.onMessage?(title, detail) }

        watcher.onModifiers = { [weak self] flags in self?.modifiersPressed(flags) }
        watcher.onEscape = { [weak self] in self?.wheel.close() }
        watcher.onEnded = { [weak self] in
            // Puštění mimo kolo nebo na střed = nic se nestane.
            // Krátká rezerva: puštění souboru na kolo může dorazit až po puštění tlačítka.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self, self.watcher.selection == nil, !self.wheel.isKeyboard else { return }
                self.wheel.close()
            }
        }

        wheel.onPick = { [weak self] item, selection in self?.run(item, on: selection) }
        wheel.onSwitch = { [weak self] target in self?.switchWheel(to: target) }
        wheel.wheelForFlags = { [weak self] flags in self?.wheel(for: flags) }

        updatesTask = Task { [weak self, queue] in
            for await snapshot in queue.updates {
                self?.apply(snapshot)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? watcher.start() : watcher.stop()
        if !enabled { wheel.close() }
    }

    // MARK: Otevření kola

    /// Klávesnicová cesta: kolo pro soubory vybrané ve Finderu.
    func openForFinderSelection() {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        AppleScriptRunner.run(script) { [weak self] result in
            guard let self else { return }
            let urls = (result ?? "")
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            guard !urls.isEmpty else {
                self.onMessage?("Kolo souborů", "Ve Finderu vyber soubor a stiskni ⌃⌥K znovu")
                return
            }
            let selection = Selection(urls: urls)
            let screen = NSScreen.main?.frame ?? .zero
            self.wheel.present(
                .convert, selection: selection, items: self.items(for: selection, wheel: .convert),
                at: NSPoint(x: screen.midX, y: screen.midY), keyboard: true
            )
            self.wheel.model.keys = self.keyLegend
        }
    }

    /// Vývoj: `--wheel [convert|tools|actions] [soubor]` ukáže kolo uprostřed obrazovky bez tažení.
    func previewWheel(arguments: [String]) {
        let index = arguments.firstIndex(of: "--wheel") ?? 0
        let rest = Array(arguments.dropFirst(index + 1))
        let target = rest.first.flatMap(Wheel.init(rawValue:)) ?? .actions
        let path = rest.dropFirst().first ?? "/tmp/Ukázka.png"
        let selection = Selection(urls: [URL(fileURLWithPath: path)])
        let screen = NSScreen.main?.frame ?? .zero
        wheel.present(target, selection: selection, items: items(for: selection, wheel: target),
                      at: NSPoint(x: screen.midX, y: screen.midY), keyboard: true)
        wheel.model.keys = keyLegend
    }

    /// Vývoj: `--render-wheel <výstup.png> [kolo] [soubor] [zvýraznit]` vykreslí kolo do PNG a skončí
    /// (kontrola vzhledu bez oprávnění k nahrávání obrazovky).
    func renderWheel(arguments: [String]) {
        let index = arguments.firstIndex(of: "--render-wheel") ?? 0
        let rest = Array(arguments.dropFirst(index + 1))
        guard let output = rest.first else { return }
        FileHandle.standardError.write(Data("render-wheel → \(output)\n".utf8))
        let target = rest.dropFirst().first.flatMap(Wheel.init(rawValue:)) ?? .actions
        let path = rest.dropFirst(2).first ?? "/tmp/Ukázka.png"
        let selection = Selection(urls: [URL(fileURLWithPath: path)])
        let model = WheelModel()
        model.show(target, selection: selection, items: items(for: selection, wheel: target))
        model.keys = keyLegend
        model.hovered = rest.dropFirst(3).first.flatMap(Int.init)
        let renderer = ImageRenderer(content: WheelView(model: model, animated: false).background(Color(white: 0.5)))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            do { try png.write(to: URL(fileURLWithPath: output)) } catch {
                FileHandle.standardError.write(Data("render-wheel: \(error)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data("render-wheel: renderer vrátil nil\n".utf8))
        }
        NSApp.terminate(nil)
    }

    private func modifiersPressed(_ flags: NSEvent.ModifierFlags) {
        guard let selection = watcher.selection, let target = wheel(for: flags) else { return }
        let items = items(for: selection, wheel: target)
        if wheel.isOpen {
            wheel.update(target, selection: selection, items: items)
        } else {
            wheel.present(target, selection: selection, items: items, at: NSEvent.mouseLocation, keyboard: false)
            wheel.model.keys = keyLegend
            log.debug("wheel \(target.rawValue, privacy: .public) for \(selection.count) files")
        }
    }

    private func switchWheel(to target: Wheel) {
        let selection = wheel.model.selection
        wheel.update(target, selection: selection, items: items(for: selection, wheel: target))
    }

    /// Kolo pro nově stisknuté modifikátory (při více najednou vyhrává pořadí kol).
    private func wheel(for flags: NSEvent.ModifierFlags) -> Wheel? {
        Wheel.allCases.first { flags.contains(settings.key(for: $0).flag) }
    }

    private var keyLegend: [(Wheel, WheelKey)] {
        Wheel.allCases.map { ($0, settings.key(for: $0)) }
    }

    /// Lístky pro výběr a kolo. Akce jsou vždy všechny; převody a nástroje podle druhu souborů.
    func items(for selection: Selection, wheel: Wheel) -> [WheelItem] {
        if wheel == .actions { return FileAction.allCases.map(\.item) }
        return registry.operations(for: selection, wheel: wheel).map { operation in
            var hint: String?
            if case .missing(let missing) = operation.availability(for: selection, tools: tools) { hint = missing }
            return WheelItem(
                id: operation.id, title: operation.title, symbol: operation.symbol,
                target: .operation(operation.id), hint: hint, approximate: operation.isApproximate(for: selection)
            )
        }
    }

    // MARK: Spuštění

    private func run(_ item: WheelItem, on selection: Selection) {
        switch item.target {
        case .action(let action):
            actions.perform(action, on: selection)
        case .operation(let id):
            guard let operation = registry.operation(id: id) else { return }
            submit(operation, selection: selection)
        case .more:
            break
        }
    }

    func submit(_ operation: any FileOperation, selection: Selection, options: [String: OptionValue] = [:]) {
        let output = settings.convertOutput
        Task { await queue.submit(operation, selection: selection, output: output, tools: tools, options: options) }
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(id) }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isDone }
    }

    private func reportProgress() {
        let active = jobs.filter { !$0.state.isDone }
        guard !active.isEmpty else { return onProgress(nil) }
        let total = active.reduce(0.0) { sum, job in
            if case .running(let progress) = job.state { return sum + progress }
            return sum
        }
        onProgress((total / Double(active.count), active.count))
    }

    private func apply(_ snapshot: JobSnapshot) {
        if let index = jobs.firstIndex(where: { $0.id == snapshot.id }) {
            jobs[index] = snapshot
        } else {
            jobs.insert(snapshot, at: 0)
            if jobs.count > Self.historyLimit { jobs.removeLast(jobs.count - Self.historyLimit) }
        }
        reportProgress()
        switch snapshot.state {
        case .finished(let urls):
            onFinished?(urls)
        case .failed(let message, let detail):
            log.error("\(snapshot.operationID, privacy: .public): \(message, privacy: .public) \(detail ?? "", privacy: .public)")
            onMessage?("Nepovedlo se: \(snapshot.title)", message)
        default:
            break
        }
    }
}
