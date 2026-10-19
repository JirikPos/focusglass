import CoreGraphics
import Foundation

/// Komprese obrázků: cílová velikost, snížení o procenta, nebo předvolba. Volitelně i zmenšení rozměrů.
public enum ImageCompress {
    public struct Settings: Sendable {
        public enum Mode: Sendable, Equatable {
            case preset(Preset)
            case targetBytes(Int)
            case percent(Int)
        }

        public enum Preset: String, Sendable, CaseIterable {
            case small, medium, high

            var quality: Double {
                switch self {
                case .small: 0.55
                case .medium: 0.75
                case .high: 0.88
                }
            }

            var maxDimension: Int? {
                switch self {
                case .small: 1920
                case .medium: 2560
                case .high: nil
                }
            }
        }

        public var mode: Mode
        public var maxDimension: Int?
        public var format: Format?
        public var stripMetadata: Bool

        public init(mode: Mode, maxDimension: Int? = nil, format: Format? = nil, stripMetadata: Bool = false) {
            self.mode = mode; self.maxDimension = maxDimension; self.format = format; self.stripMetadata = stripMetadata
        }
    }

    public struct Result: Sendable {
        public let data: Data
        public let format: Format
        public let size: CGSize
        public let originalBytes: Int
        /// Soubor už menší být nemůže – výsledek je kopie originálu.
        public let alreadyOptimal: Bool
    }

    // MARK: Hlavní algoritmus

    public static func compress(_ source: URL, settings: Settings, previewMaxPixel: Int? = nil) throws -> Result {
        let originalBytes = ImageBackend.fileSize(source)
        let format = settings.format ?? ImageBackend.keepFormat(for: source)
        var image = try ImageBackend.load(source)
        let originalSize = CGSize(width: image.width, height: image.height)
        let properties = ImageBackend.carriedProperties(of: source, stripping: settings.stripMetadata)

        var limit = settings.maxDimension
        if case .preset(let preset) = settings.mode { limit = settings.maxDimension ?? preset.maxDimension }
        if let limit { image = try ImageBackend.resized(image, maxPixel: limit) }
        let resized = image.width != Int(originalSize.width)

        let result: (Data, CGImage)
        switch settings.mode {
        case .preset(let preset):
            let data = try ImageBackend.encode(image, as: format, quality: ImageBackend.isLossy(format) ? preset.quality : nil,
                                               properties: properties)
            result = (data, image)
        case .targetBytes(let bytes):
            result = try fit(image, to: max(bytes, 1024), format: format, properties: properties)
        case .percent(let percent):
            let target = Int(Double(originalBytes) * Double(100 - min(max(percent, 1), 95)) / 100)
            result = try fit(image, to: max(target, 1024), format: format, properties: properties)
        }

        // Výsledek větší než originál nemá smysl (např. PNG bez zmenšení) – ponecháme originál.
        let unchanged = !resized && !settings.stripMetadata && format == ImageBackend.keepFormat(for: source)
        if unchanged, result.0.count >= originalBytes, originalBytes > 0, let original = try? Data(contentsOf: source),
           ImageBackend.format(forExtension: source.pathExtension) == format {
            return Result(data: original, format: format, size: originalSize, originalBytes: originalBytes, alreadyOptimal: true)
        }
        return Result(data: result.0, format: format, size: CGSize(width: result.1.width, height: result.1.height),
                      originalBytes: originalBytes, alreadyOptimal: false)
    }

    /// Najde nejvyšší kvalitu, která se vejde do `target` bajtů; když nestačí, zmenšuje rozměry.
    static func fit(_ image: CGImage, to target: Int, format: Format, properties: [CFString: Any]) throws -> (Data, CGImage) {
        var current = image
        let lossy = ImageBackend.isLossy(format)
        for _ in 0..<12 {
            try Task.checkCancellation()
            if lossy {
                if let found = try bestQuality(current, target: target, format: format, properties: properties) {
                    return (found, current)
                }
            } else {
                let data = try ImageBackend.encode(current, as: format, properties: properties)
                if data.count <= target { return (data, current) }
            }
            // Nevejde se ani při nejnižší kvalitě → zmenšit o ~15 % na každé straně.
            let longest = max(current.width, current.height)
            guard longest > 64 else { break }
            current = try ImageBackend.resized(current, maxPixel: Int(Double(longest) * 0.85))
        }
        return (try ImageBackend.encode(current, as: format, quality: lossy ? 0.05 : nil, properties: properties), current)
    }

    /// Půlení intervalu kvality 0,05…0,95 (osm kroků stačí na přesnost ~0,4 %).
    private static func bestQuality(_ image: CGImage, target: Int, format: Format,
                                    properties: [CFString: Any]) throws -> Data? {
        var low = 0.05
        var high = 0.95
        var best: Data?
        // Nejdřív nejlepší kvalita: když se vejde, hotovo (nezhoršovat zbytečně).
        let top = try ImageBackend.encode(image, as: format, quality: high, properties: properties)
        if top.count <= target { return top }
        let bottom = try ImageBackend.encode(image, as: format, quality: low, properties: properties)
        guard bottom.count <= target else { return nil }
        best = bottom
        for _ in 0..<8 {
            let middle = (low + high) / 2
            let data = try ImageBackend.encode(image, as: format, quality: middle, properties: properties)
            if data.count <= target {
                best = data
                low = middle
            } else {
                high = middle
            }
        }
        return best
    }

    // MARK: Nástroj

    static func settings(from context: OperationContext) -> Settings {
        let mode: Settings.Mode
        switch context.string("mode") {
        case "target": mode = .targetBytes((context.int("targetKB") ?? 500) * 1024)
        case "percent": mode = .percent(context.int("percent") ?? 50)
        default: mode = .preset(Settings.Preset(rawValue: context.string("preset") ?? "") ?? .medium)
        }
        let maxDimension = context.string("maxDimension").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let format = context.string("format").flatMap { $0 == "keep" ? nil : ImageBackend.format(forExtension: $0) }
        return Settings(mode: mode, maxDimension: maxDimension, format: format, stripMetadata: context.bool("strip") ?? false)
    }

    static let options: [ToolOption] = [
        .choice("mode", "Způsob", [.init("preset", "Předvolba"), .init("target", "Cílová velikost"), .init("percent", "Snížit o")],
                default: "preset"),
        .choice("preset", "Předvolba", [.init("small", "Malý soubor (web)"), .init("medium", "Vyvážená"), .init("high", "Vysoká kvalita")],
                default: "medium", visibleWhen: .init("mode", "preset")),
        .number("targetKB", "Cílová velikost", 20...200_000, default: 500, unit: "KB", visibleWhen: .init("mode", "target"),
                help: "PNG je bezeztrátové – u něj se k cíli zmenšují rozměry."),
        .slider("percent", "Úspora", 10...90, default: 50, step: 5, unit: "%", visibleWhen: .init("mode", "percent")),
        .choice("maxDimension", "Největší rozměr", [.init("0", "Beze změny"), .init("3840", "3840 px"), .init("2560", "2560 px"),
                                                    .init("1920", "1920 px"), .init("1280", "1280 px"), .init("800", "800 px")],
                default: "0"),
        .choice("format", "Formát", [.init("keep", "Stejný"), .init("jpg", "JPG"), .init("heic", "HEIC")], default: "keep"),
        .toggle("strip", "Odstranit metadata a polohu", default: false),
    ]

    public static let tool = Tool(
        id: "image.tool.compress", title: "Komprese", symbol: "arrow.down.right.and.arrow.up.left", options: options,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let result = try compress(request.source, settings: settings(from: context))
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            return PreviewResult(image: image, caption: caption(result))
        },
        run: { context in
            let settings = settings(from: context)
            let format = settings.format
            return try await EachImage.run(
                context, tag: "komprese",
                outputExtension: { (format ?? ImageBackend.keepFormat(for: $0)).ext }
            ) { source, output, progress in
                progress(0.1)
                let result = try compress(source, settings: settings)
                try result.data.write(to: output)
                progress(1)
            }
        }
    )

    /// „2,4 MB → 380 KB (−84 %)“.
    static func caption(_ result: Result) -> String {
        let before = byteString(result.originalBytes)
        let after = byteString(result.data.count)
        if result.alreadyOptimal { return "\(before) – už je optimální" }
        let saved = result.originalBytes > 0
            ? Int((1 - Double(result.data.count) / Double(result.originalBytes)) * 100) : 0
        return "\(before) → \(after) (\(saved >= 0 ? "−" : "+")\(abs(saved)) %) · \(Int(result.size.width))×\(Int(result.size.height))"
    }

    public static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
