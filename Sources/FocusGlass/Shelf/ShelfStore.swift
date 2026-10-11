import AppKit
import Observation

struct ShelfItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Odkladiště souborů v notchi. Drží jen odkazy (soubory se nekopírují) a přežije restart.
@MainActor
@Observable
final class ShelfStore {
    private static let key = "shelfPaths"

    private(set) var items: [ShelfItem] = []
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(ShelfItem.init)
    }

    func add(_ url: URL) {
        guard url.isFileURL, !items.contains(where: { $0.url == url }) else { return }
        items.append(ShelfItem(url: url))
        save()
    }

    /// Přijme soubory přetažené na notch.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.add(url) }
                }
            }
        }
        return !files.isEmpty
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0 == item }
        icons[item.url] = nil
        save()
    }

    func clear() {
        items.removeAll()
        icons.removeAll()
        save()
    }

    /// Soubor, nad kterým je myš (pro náhled mezerníkem).
    @ObservationIgnored var hovered: ShelfItem?

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func quickLook(_ item: ShelfItem? = nil) {
        let selected = item ?? hovered ?? items.first
        guard let selected else { return }
        QuickLook.shared.show(selected.url)
    }

    func airDrop(_ item: ShelfItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
    }

    func icon(for item: ShelfItem) -> NSImage {
        if let icon = icons[item.url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.url] = icon
        return icon
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Self.key)
    }
}
