import AppKit
import Foundation

/// Tři kola – každé na jiný modifikátor.
public enum Wheel: String, CaseIterable, Sendable {
    /// Převod do jiného formátu.
    case convert
    /// Nástroje (komprese, ořez, střih…).
    case tools
    /// Akce se souborem (AirDrop, kopírovat, terminál…).
    case actions

    public var title: String {
        switch self {
        case .convert: "Převést"
        case .tools: "Nástroje"
        case .actions: "Akce"
        }
    }
}

/// Co operace potřebuje navíc k frameworkům macOS.
public enum Requirement: Hashable, Sendable {
    case tool(ExternalTool)
    /// Aplikace podle bundle ID (Pages, Keynote, Numbers).
    case app(bundleID: String, name: String)
}

/// Jak náročná operace je – těžké (video, audio) běží po jedné, lehké souběžně.
public extension Requirement {
    static func isMet(_ requirement: Requirement, tools: ToolLocator) -> Bool {
        switch requirement {
        case .tool(let tool): tools.isAvailable(tool)
        case .app(let bundleID, _): NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    /// Co doinstalovat.
    var hint: String {
        switch self {
        case .tool(let tool): tool.installHint
        case .app(_, let name): "Nainstaluj \(name) z App Storu"
        }
    }

    var missingError: ConvertError {
        switch self {
        case .tool(let tool): .toolMissing(tool)
        case .app(_, let name): .appMissing(name)
        }
    }

    static let pages = Requirement.app(bundleID: "com.apple.iWork.Pages", name: "Pages")
    static let keynote = Requirement.app(bundleID: "com.apple.iWork.Keynote", name: "Keynote")
    static let numbers = Requirement.app(bundleID: "com.apple.iWork.Numbers", name: "Numbers")
    static let ffmpeg = Requirement.tool(.ffmpeg)
    static let libreOffice = Requirement.tool(.soffice)
}

public enum Lane: Sendable, Hashable {
    case light
    case heavy
}

public enum Availability: Sendable, Equatable {
    case available
    case missing(hint: String)
}

/// Hodnota nastavení nástroje (z okna s možnostmi nebo z předvolby).
public enum OptionValue: Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case url(URL)
    case color(RGBA)
    /// Složitější data z editorů (anotace, oblasti ke krytí, ořez) jako JSON.
    case data(Data)
}

public struct OperationContext: Sendable {
    public let selection: Selection
    public let output: OutputPolicy
    public let tools: ToolLocator
    public let options: [String: OptionValue]
    /// Průběh 0…1. Volat lze z libovolného vlákna.
    public let progress: @Sendable (Double) -> Void

    public init(
        selection: Selection,
        output: OutputPolicy = OutputPolicy(),
        tools: ToolLocator = .shared,
        options: [String: OptionValue] = [:],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.selection = selection
        self.output = output
        self.tools = tools
        self.options = options
        self.progress = progress
    }

    public func double(_ key: String) -> Double? {
        switch options[key] {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch options[key] {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value) = options[key] { return value }
        return nil
    }

    public func string(_ key: String) -> String? {
        if case .string(let value) = options[key] { return value }
        return nil
    }

    public func url(_ key: String) -> URL? {
        if case .url(let value) = options[key] { return value }
        return nil
    }

    public func color(_ key: String) -> RGBA? {
        if case .color(let value) = options[key] { return value }
        return nil
    }

    /// JSON z editoru; `nil`, když chybí nebo nejde přečíst.
    public func decoded<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard case .data(let data) = options[key] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Jedna položka kola, která vyrobí nové soubory (převod nebo nástroj).
public protocol FileOperation: Sendable {
    /// Stabilní identifikátor, např. `image.convert.png`.
    var id: String { get }
    /// Krátký popisek na lístek kola („PNG“, „Komprese“).
    var title: String { get }
    /// SF Symbol; `nil` = jen text (formáty).
    var symbol: String? { get }
    var wheel: Wheel { get }
    var lane: Lane { get }
    var requirements: [Requirement] { get }
    /// Výsledek je přibližný (např. PDF → DOCX).
    var isApproximate: Bool { get }

    func accepts(_ selection: Selection) -> Bool
    /// Jde to pro tenhle výběr spustit (nástroje, aplikace)?
    func availability(for selection: Selection, tools: ToolLocator) -> Availability
    /// Bude výsledek pro tenhle výběr přibližný?
    func isApproximate(for selection: Selection) -> Bool
    /// Vrací URL vytvořených souborů. Při zrušení hází `CancellationError`.
    func run(_ context: OperationContext) async throws -> [URL]
}

public extension FileOperation {
    var symbol: String? { nil }
    var lane: Lane { .light }
    var requirements: [Requirement] { [] }
    var isApproximate: Bool { false }

    func availability(for selection: Selection, tools: ToolLocator) -> Availability {
        for requirement in requirements where !Requirement.isMet(requirement, tools: tools) {
            return .missing(hint: requirement.hint)
        }
        return .available
    }

    func isApproximate(for selection: Selection) -> Bool { isApproximate }

}
