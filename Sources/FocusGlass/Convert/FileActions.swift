import AppKit
import ConvertKit

/// Akce se soubory (kolo ⌃). Fungují pro cokoli včetně složek a smíšených výběrů.
enum FileAction: String, CaseIterable {
    case airDrop
    case float
    case copy
    case move
    case copyPath
    case terminal

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Kopírovat"
        case .move: "Přesunout"
        case .copyPath: "Cesta"
        case .terminal: "Terminál"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "pip"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }

    var item: WheelItem {
        WheelItem(id: "action.\(rawValue)", title: title, symbol: symbol, target: .action(self))
    }
}

/// Provádí akce. Výsledek hlásí krátkou zprávou (`onMessage`).
@MainActor
final class FileActionPerformer {
    var onMessage: ((_ title: String, _ detail: String) -> Void)?
    let floats = FloatController()

    private static let lastFolderKey = "convertLastFolder"

    func perform(_ action: FileAction, on selection: Selection) {
        let urls = selection.urls
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop:
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                return message("AirDrop", "AirDrop teď není k dispozici")
            }
            service.perform(withItems: urls)
        case .float:
            urls.forEach(floats.show)
        case .copy:
            chooseFolder(prompt: "Kopírovat sem") { [weak self] folder in self?.transfer(urls, to: folder, move: false) }
        case .move:
            chooseFolder(prompt: "Přesunout sem") { [weak self] folder in self?.transfer(urls, to: folder, move: true) }
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            message(urls.count == 1 ? "Cesta zkopírována" : "Cesty zkopírovány", selection.summary)
        case .terminal:
            openTerminal(at: urls[0])
        }
    }

    // MARK: Kopírovat / přesunout

    private func chooseFolder(prompt: String, then: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let last = UserDefaults.standard.string(forKey: Self.lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
            then(folder)
        }
    }

    /// Kopírování velkých souborů nesmí blokovat UI. Existující soubory se nepřepisují („x 2.png“).
    private func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        Task { [weak self] in
            let (title, detail) = await Task.detached(priority: .userInitiated) {
                Self.transferFiles(urls, to: folder, move: move)
            }.value
            self?.message(title, detail)
        }
    }

    /// Vrací titulek a detail zprávy o výsledku.
    private nonisolated static func transferFiles(_ urls: [URL], to folder: URL, move: Bool) -> (String, String) {
        let fm = FileManager.default
        var done = 0
        var failure: String?
        for url in urls {
            // Přesun do stejné složky nic nedělá.
            if move, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                done += 1
                continue
            }
            let target = OutputPolicy.unique(folder.appendingPathComponent(url.lastPathComponent))
            do {
                if move {
                    try fm.moveItem(at: url, to: target)
                } else {
                    try fm.copyItem(at: url, to: target)
                }
                done += 1
            } catch {
                failure = error.localizedDescription
            }
        }
        if let failure { return (move ? "Přesun selhal" : "Kopírování selhalo", failure) }
        return (move ? "Přesunuto" : "Zkopírováno",
                "\(Czech.count(done, "soubor", "soubory", "souborů")) → \(folder.lastPathComponent)")
    }

    // MARK: Terminál

    private func openTerminal(at url: URL) {
        let isFolder = FileKind.of(url) == .folder
        let directory = isFolder ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return message("Terminál", "Aplikace Terminál nebyla nalezena")
        }
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func message(_ title: String, _ detail: String) {
        onMessage?(title, detail)
    }
}
