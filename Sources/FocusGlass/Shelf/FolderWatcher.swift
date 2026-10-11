import Foundation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "shelf")

/// Hlídá složku a hlásí nově vzniklé soubory (screenshoty, dokončená stahování).
///
/// Systém (kqueue) ozná změnu ve složce – nic se pravidelně nekontroluje. Dočasné soubory
/// (`.Snímek…`, `.crdownload`, `.download`, `.part`) se ignorují; nahlásí se až hotový soubor.
@MainActor
final class FolderWatcher {
    enum Kind {
        case screenshots
        case downloads

        /// Aktuální složka (screenshoty: podle nastavení macOS, jinak Plocha).
        var folder: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .downloads:
                return home.appendingPathComponent("Downloads", isDirectory: true)
            case .screenshots:
                if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
                    return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                }
                return home.appendingPathComponent("Desktop", isDirectory: true)
            }
        }
    }

    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]
    private static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "pdf"]

    private let kind: Kind
    private let onNewFile: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pendingCheck: DispatchWorkItem?

    init(kind: Kind, onNewFile: @escaping (URL) -> Void) {
        self.kind = kind
        self.onNewFile = onNewFile
    }

    func setEnabled(_ enabled: Bool) {
        stop()
        guard enabled else { return }
        let folder = kind.folder
        known = Set(contents(of: folder))

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("cannot watch \(folder.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
        pendingCheck?.cancel()
    }

    /// Víc událostí za sebou (zápis + přejmenování) → zkontroluj jednou, až se soubor dopíše.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func check() {
        let folder = kind.folder
        let current = contents(of: folder)
        let new = current.filter { !known.contains($0) }
        known = Set(current)

        for name in new where accepts(name) {
            let url = folder.appendingPathComponent(name)
            log.debug("new file: \(name, privacy: .public)")
            onNewFile(url)
        }
    }

    private func accepts(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        switch kind {
        case .downloads:
            return !Self.partialExtensions.contains(ext)
        case .screenshots:
            return Self.screenshotExtensions.contains(ext)
        }
    }

    private func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}
