import Foundation

/// Volitelné nástroje z Homebrew / LibreOffice. Aplikace bez nich funguje, jen nabídne méně formátů.
public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case cwebp
    case avifenc
    case pandoc
    case soffice

    public var displayName: String {
        switch self {
        case .soffice: "LibreOffice"
        default: rawValue
        }
    }

    public var installHint: String {
        switch self {
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        case .cwebp: "brew install webp"
        case .avifenc: "brew install libavif"
        case .pandoc: "brew install pandoc"
        case .soffice: "brew install --cask libreoffice"
        }
    }

    /// Absolutní cesty mimo PATH (aplikace z Docku nedědí PATH ze shellu).
    var knownLocations: [String] {
        switch self {
        case .soffice: ["/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        default: []
        }
    }
}

/// Najde nástroje na disku. Výsledek si pamatuje; `refresh()` po instalaci nástroje.
public final class ToolLocator: @unchecked Sendable {
    public static let shared = ToolLocator()

    private let lock = NSLock()
    private var cache: [ExternalTool: URL?] = [:]
    private let searchPaths: [String]
    private let environment: [String: String]
    /// Nástroje přibalené v aplikaci (`Contents/Resources/bin`) mají přednost před systémovými.
    private let bundledDirectory: String?

    public init(
        searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
    ) {
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        self.searchPaths = (searchPaths + fromPath).filter { seen.insert($0).inserted }
        self.environment = environment
        self.bundledDirectory = bundledDirectory.flatMap(Self.usable)?.path
    }

    /// Přibalené nástroje se použijí jen na architektuře, pro kterou vznikly (`.arch` ve složce);
    /// univerzální aplikace na jiném Macu sáhne po nástrojích ze systému.
    static func usable(_ directory: URL) -> URL? {
        guard let marker = try? String(contentsOf: directory.appendingPathComponent(".arch"), encoding: .utf8) else { return directory }
        #if arch(arm64)
        let current = "arm64"
        #elseif arch(x86_64)
        let current = "x86_64"
        #else
        let current = ""
        #endif
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == current ? directory : nil
    }

    /// Je nástroj součástí aplikace (a ne nainstalovaný v systému)?
    public func isBundled(_ tool: ExternalTool) -> Bool {
        guard let bundledDirectory, let url = url(for: tool) else { return false }
        return url.path.hasPrefix(bundledDirectory + "/")
    }

    public func url(for tool: ExternalTool) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[tool] { return cached }
        let found = locate(tool)
        cache[tool] = found
        return found
    }

    public func isAvailable(_ tool: ExternalTool) -> Bool { url(for: tool) != nil }

    /// Cesta k nástroji, nebo chyba s nápovědou k instalaci.
    public func require(_ tool: ExternalTool) throws -> URL {
        guard let url = url(for: tool) else { throw ConvertError.toolMissing(tool) }
        return url
    }

    public func refresh() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func locate(_ tool: ExternalTool) -> URL? {
        // `FG_NO_FFMPEG=1` apod. – vývoj a testy chování bez nástroje.
        if environment["FG_NO_\(tool.rawValue.uppercased())"] == "1" { return nil }
        let bundled = bundledDirectory.map { ["\($0)/\(tool.rawValue)"] } ?? []
        let candidates = bundled + tool.knownLocations + searchPaths.map { "\($0)/\(tool.rawValue)" }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
