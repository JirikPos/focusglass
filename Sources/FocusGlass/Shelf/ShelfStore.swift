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

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
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
