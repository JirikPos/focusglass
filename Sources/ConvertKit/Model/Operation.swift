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
    /// Vrací URL vytvořených souborů. Při zrušení hází `CancellationError`.
    func run(_ context: OperationContext) async throws -> [URL]
}

public extension FileOperation {
    var symbol: String? { nil }
    var lane: Lane { .light }
    var requirements: [Requirement] { [] }
    var isApproximate: Bool { false }

    func availability(tools: ToolLocator) -> Availability {
        for requirement in requirements {
            switch requirement {
            case .tool(let tool):
                if !tools.isAvailable(tool) { return .missing(hint: tool.installHint) }
            case .app(let bundleID, let name):
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil {
                    return .missing(hint: "Nainstaluj \(name) z App Storu")
                }
            }
        }
        return .available
    }
}
