import Foundation

/// Soubory, které uživatel táhne (nebo má vybrané ve Finderu).
public struct Selection: Sendable, Hashable {
    public let urls: [URL]
    public let kinds: [FileKind]

    public init(urls: [URL]) {
        // Pořadí zachovat (koláž, sloučení), duplicity pryč.
        var seen = Set<URL>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        self.urls = unique
        self.kinds = unique.map(FileKind.of)
    }

    /// Pro testy a výběry, kde druh známe bez souborového systému.
    public init(urls: [URL], kinds: [FileKind]) {
        precondition(urls.count == kinds.count)
        self.urls = urls
        self.kinds = kinds
    }

    public var isEmpty: Bool { urls.isEmpty }
    public var count: Int { urls.count }
    public var isMultiple: Bool { urls.count > 1 }

    /// Společný druh všech souborů, `nil` u smíšeného výběru.
    public var commonKind: FileKind? {
        guard let first = kinds.first, kinds.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Přípony v malých písmenech (např. pro vynechání převodu PNG → PNG).
    public var extensions: Set<String> {
        Set(urls.map { $0.pathExtension.lowercased() })
    }

    /// Krátký popis do středu kola: „foto.png“ nebo „3 soubory“.
    public var summary: String {
        switch urls.count {
        case 0: return ""
        case 1: return urls[0].lastPathComponent
        default: return Czech.count(urls.count, "soubor", "soubory", "souborů")
        }
    }
}

/// Česká množná čísla (1 soubor, 2–4 soubory, 5+ souborů).
public enum Czech {
    public static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let word: String
        switch n {
        case 1: word = one
        case 2...4: word = few
        default: word = many
        }
        return "\(n) \(word)"
    }
}
