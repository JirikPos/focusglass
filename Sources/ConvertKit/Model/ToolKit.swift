import CoreGraphics
import Foundation

/// Barva nezávislá na platformě (sRGB, 0…1) – ukládá se do voleb i do JSON z editorů.
public struct RGBA: Sendable, Hashable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let red = RGBA(0.93, 0.2, 0.18)
    public static let yellow = RGBA(1, 0.84, 0.1)

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// „#RRGGBB“ nebo „#RRGGBBAA“.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        self.init(Double((value >> (16 + shift)) & 0xFF) / 255, Double((value >> (8 + shift)) & 0xFF) / 255,
                  Double((value >> shift) & 0xFF) / 255, hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }
}

/// Jedna volba nástroje. Z těchto popisů okno s možnostmi sestaví formulář – nástroj nepíše vlastní UI.
public struct ToolOption: Sendable, Identifiable {
    public struct Choice: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public init(_ id: String, _ title: String) { self.id = id; self.title = title }
    }

    public enum Kind: Sendable {
        case toggle
        case slider(range: ClosedRange<Double>, step: Double, unit: String)
        case choice([Choice])
        case text(placeholder: String)
        /// Heslo: zadává se skrytě a neukládá se.
        case secret(placeholder: String)
        case number(range: ClosedRange<Int>, unit: String)
        case color
        case file(extensions: [String])
    }

    /// Volba se ukáže jen tehdy, když má jiná volba jednu z hodnot (pro ano/ne „true“).
    public struct Condition: Sendable {
        public let optionID: String
        public let values: Set<String>
        public init(_ optionID: String, _ values: String...) { self.optionID = optionID; self.values = Set(values) }
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let defaultValue: OptionValue
    public let visibleWhen: Condition?
    public let help: String?

    public init(_ id: String, _ title: String, _ kind: Kind, default defaultValue: OptionValue,
                visibleWhen: Condition? = nil, help: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.defaultValue = defaultValue
        self.visibleWhen = visibleWhen; self.help = help
    }

    public func isVisible(in values: [String: OptionValue]) -> Bool {
        guard let condition = visibleWhen else { return true }
        switch values[condition.optionID] {
        case .string(let value): return condition.values.contains(value)
        case .bool(let value): return condition.values.contains(value ? "true" : "false")
        default: return false
        }
    }

    // Zkratky pro nejběžnější volby.
    public static func choice(_ id: String, _ title: String, _ choices: [Choice], default value: String,
                              visibleWhen: Condition? = nil, help: String? = nil) -> ToolOption {
        ToolOption(id, title, .choice(choices), default: .string(value), visibleWhen: visibleWhen, help: help)
    }

    public static func toggle(_ id: String, _ title: String, default value: Bool = false,
                              visibleWhen: Condition? = nil, help: String? = nil) -> ToolOption {
        ToolOption(id, title, .toggle, default: .bool(value), visibleWhen: visibleWhen, help: help)
    }

    public static func slider(_ id: String, _ title: String, _ range: ClosedRange<Double>, default value: Double,
                              step: Double = 0.01, unit: String = "", visibleWhen: Condition? = nil,
                              help: String? = nil) -> ToolOption {
        ToolOption(id, title, .slider(range: range, step: step, unit: unit), default: .double(value),
                   visibleWhen: visibleWhen, help: help)
    }

    public static func number(_ id: String, _ title: String, _ range: ClosedRange<Int>, default value: Int,
                              unit: String = "", visibleWhen: Condition? = nil, help: String? = nil) -> ToolOption {
        ToolOption(id, title, .number(range: range, unit: unit), default: .int(value),
                   visibleWhen: visibleWhen, help: help)
    }

    public static func color(_ id: String, _ title: String, default value: RGBA,
                             visibleWhen: Condition? = nil) -> ToolOption {
        ToolOption(id, title, .color, default: .color(value), visibleWhen: visibleWhen)
    }

    public static func text(_ id: String, _ title: String, placeholder: String = "", default value: String = "",
                            visibleWhen: Condition? = nil, help: String? = nil) -> ToolOption {
        ToolOption(id, title, .text(placeholder: placeholder), default: .string(value),
                   visibleWhen: visibleWhen, help: help)
    }

    public static func secret(_ id: String, _ title: String, placeholder: String = "", visibleWhen: Condition? = nil,
                              help: String? = nil) -> ToolOption {
        ToolOption(id, title, .secret(placeholder: placeholder), default: .string(""), visibleWhen: visibleWhen, help: help)
    }

    public static func file(_ id: String, _ title: String, extensions: [String],
                            visibleWhen: Condition? = nil) -> ToolOption {
        ToolOption(id, title, .file(extensions: extensions), default: .string(""), visibleWhen: visibleWhen)
    }
}

/// Jak se nástroj nastavuje: formulářem, nebo interaktivním editorem nad obrázkem.
public enum ToolEditor: Sendable, Hashable {
    /// Jen formulář (volitelně s živým náhledem).
    case form
    /// Tažení rámečku nad obrázkem (ořez).
    case crop
    /// Mřížka stránek PDF: řazení, otáčení, mazání, duplikace.
    case pages
    /// Časová osa se střihem (video, zvuk).
    case trim
    /// Kreslení šipek, tvarů, textu a popisků.
    case annotate
    /// Oblasti ke krytí: automaticky nalezené + ruční.
    case redact
    /// Seznam souborů s řazením (koláž, PDF z obrázků).
    case order
}

public struct PreviewRequest: Sendable {
    public let source: URL
    public let options: [String: OptionValue]
    /// Delší strana náhledu v pixelech.
    public let maxPixel: Int
    /// Všechny vybrané soubory v pořadí (pro nástroje nad víc soubory).
    public let selection: Selection

    public init(source: URL, options: [String: OptionValue], maxPixel: Int, selection: Selection) {
        self.source = source; self.options = options; self.maxPixel = maxPixel; self.selection = selection
    }
}

public struct PreviewResult: @unchecked Sendable {
    public let image: CGImage
    /// Text pod náhledem (např. „2,4 MB → 380 KB“).
    public let caption: String?

    public init(image: CGImage, caption: String? = nil) {
        self.image = image
        self.caption = caption
    }
}

/// Nástroj z kola ⌘: volby, volitelný editor, živý náhled a vlastní zpracování.
public struct Tool: FileOperation {
    public let id: String
    public let title: String
    public let symbol: String?
    public let options: [ToolOption]
    public let editor: ToolEditor
    public let lane: Lane
    public let requirements: [Requirement]
    /// Jen pro víc souborů (koláž, sloučení).
    public let needsMultiple: Bool
    public var wheel: Wheel { .tools }

    private let acceptsBody: @Sendable (Selection) -> Bool
    private let runBody: @Sendable (OperationContext) async throws -> [URL]
    private let previewBody: (@Sendable (PreviewRequest) async throws -> PreviewResult)?

    public init(
        id: String, title: String, symbol: String, options: [ToolOption] = [], editor: ToolEditor = .form,
        lane: Lane = .light, requirements: [Requirement] = [], needsMultiple: Bool = false,
        accepts: @escaping @Sendable (Selection) -> Bool,
        preview: (@Sendable (PreviewRequest) async throws -> PreviewResult)? = nil,
        run: @escaping @Sendable (OperationContext) async throws -> [URL]
    ) {
        self.id = id; self.title = title; self.symbol = symbol; self.options = options; self.editor = editor
        self.lane = lane; self.requirements = requirements; self.needsMultiple = needsMultiple
        self.acceptsBody = accepts; self.previewBody = preview; self.runBody = run
    }

    public func accepts(_ selection: Selection) -> Bool {
        guard !selection.isEmpty, !needsMultiple || selection.isMultiple else { return false }
        return acceptsBody(selection)
    }

    public var hasPreview: Bool { previewBody != nil }

    /// Nástroj potřebuje okno (formulář nebo editor); jinak se spustí rovnou s výchozími hodnotami.
    public var needsDialog: Bool { !options.isEmpty || editor != .form }

    /// Výchozí hodnoty všech voleb.
    public var defaults: [String: OptionValue] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.defaultValue) })
    }

    public func resolved(_ given: [String: OptionValue]) -> [String: OptionValue] {
        defaults.merging(given) { _, new in new }
    }

    public func preview(_ request: PreviewRequest) async throws -> PreviewResult? {
        guard let previewBody else { return nil }
        return try await previewBody(PreviewRequest(source: request.source, options: resolved(request.options),
                                                    maxPixel: request.maxPixel, selection: request.selection))
    }

    public func run(_ context: OperationContext) async throws -> [URL] {
        try await runBody(OperationContext(
            selection: context.selection, output: context.output, tools: context.tools,
            options: resolved(context.options), progress: context.progress
        ))
    }
}
