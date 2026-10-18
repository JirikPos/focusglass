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

    public init(
        searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        self.searchPaths = (searchPaths + fromPath).filter { seen.insert($0).inserted }
        self.environment = environment
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

    public func refresh() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func locate(_ tool: ExternalTool) -> URL? {
        // `FG_NO_FFMPEG=1` apod. – vývoj a testy chování bez nástroje.
        if environment["FG_NO_\(tool.rawValue.uppercased())"] == "1" { return nil }
        let candidates = tool.knownLocations + searchPaths.map { "\($0)/\(tool.rawValue)" }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
