import AppKit
import ConvertKit

/// Modifikátor, který během tažení otevře kolo.
enum WheelKey: String, CaseIterable, Identifiable {
    case shift
    case command
    case control
    case option

    var id: Self { self }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    var title: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        }
    }

    static func defaultKey(for wheel: Wheel) -> WheelKey {
        switch wheel {
        case .convert: .shift
        case .tools: .command
        case .actions: .control
        }
    }
}
