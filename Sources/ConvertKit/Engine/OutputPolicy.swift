import Foundation

/// Kam a pod jakým jménem se ukládají výsledky. Nikdy nepřepíše existující soubor
/// a nikdy nenechá rozepsaný výsledek: zapisuje se do dočasného souboru, který se nakonec přesune.
public struct OutputPolicy: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        /// Vedle původního souboru.
        case besideSource
        /// Do pevné složky (např. ~/Downloads/Převedeno).
        case folder(URL)
    }

    public var location: Location

    public init(location: Location = .besideSource) {
        self.location = location
    }

    /// Složka pro výsledek ze zdrojového souboru.
    public func directory(for source: URL) -> URL {
        switch location {
        case .besideSource: source.deletingLastPathComponent()
        case .folder(let folder): folder
        }
    }

    /// Navržené jméno: „foto (PNG).png“, „foto (komprese).jpg“, bez štítku „foto.png“.
    public static func fileName(for source: URL, tag: String?, extension ext: String) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let name = tag.map { "\(base) (\($0))" } ?? base
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// Cílová URL, která zatím neexistuje.
    public func destination(for source: URL, tag: String?, extension ext: String) -> URL {
        let name = Self.fileName(for: source, tag: tag, extension: ext)
        return Self.unique(directory(for: source).appendingPathComponent(name))
    }

    /// „x.png“ → „x 2.png“ → „x 3.png“… první volné jméno.
    public static func unique(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// Zapíše výsledek atomicky: `body` dostane dočasnou URL (na stejném svazku jako cíl),
    /// po úspěchu se přesune na první volné jméno odvozené z `destination`.
    /// Při chybě nebo zrušení dočasný soubor zmizí a cíl zůstane netknutý.
    public static func write(
        to destination: URL,
        fileManager: FileManager = .default,
        _ body: (URL) async throws -> Void
    ) async throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        )
        defer { try? fileManager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(destination.lastPathComponent)

        try await body(temporary)
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: temporary.path) else {
            throw ConvertError.writeFailed(destination.lastPathComponent)
        }

        // Mezi výběrem jména a přesunem může jméno někdo obsadit – zkusit další.
        for _ in 0..<50 {
            let target = unique(destination, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ConvertError.writeFailed(destination.lastPathComponent)
    }
}
