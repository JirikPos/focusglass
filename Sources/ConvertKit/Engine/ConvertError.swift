import Foundation

/// Chyby převodů. `errorDescription` je věta pro uživatele, `failureReason` technický detail do logu.
public enum ConvertError: LocalizedError, Sendable, Equatable {
    case unsupportedInput(String)
    case toolMissing(ExternalTool)
    case appMissing(String)
    case toolFailed(tool: String, status: Int32, detail: String)
    case unreadable(String)
    case writeFailed(String)
    case invalidOutput(String)
    case noAudio(String)
    case passwordRequired(String)
    case wrongPassword(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let name): "Soubor „\(name)“ tímhle převést nejde"
        case .toolMissing(let tool): "Chybí \(tool.displayName) – \(tool.installHint)"
        case .appMissing(let app): "Chybí aplikace \(app)"
        case .toolFailed(let tool, _, _): "\(tool) převod nedokončil"
        case .unreadable(let name): "Soubor „\(name)“ nejde přečíst"
        case .writeFailed(let name): "Výsledek „\(name)“ nejde uložit"
        case .invalidOutput(let name): "Výsledek „\(name)“ je poškozený"
        case .noAudio(let name): "„\(name)“ nemá zvukovou stopu"
        case .passwordRequired(let name): "„\(name)“ je zamčené heslem"
        case .wrongPassword(let name): "Heslo k „\(name)“ není správné"
        case .cancelled: "Zrušeno"
        }
    }

    public var failureReason: String? {
        switch self {
        case .toolFailed(_, let status, let detail): "exit \(status): \(detail)"
        default: nil
        }
    }
}
