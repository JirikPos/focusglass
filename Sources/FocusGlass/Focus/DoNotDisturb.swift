import Foundation

/// Zapíná a vypíná režim Nerušit přes aplikaci Zkratky.
///
/// macOS nemá veřejné API pro režimy soustředění, proto uživatel jednou vytvoří dvě zkratky
/// („FocusGlass On“ / „FocusGlass Off“) s akcí *Nastavit režim soustředění* a my je spouštíme.
@MainActor
final class DoNotDisturb {
    static let onShortcut = "FocusGlass On"
    static let offShortcut = "FocusGlass Off"

    private var isOn = false

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        run(on ? Self.onShortcut : Self.offShortcut)
    }

    private func run(_ shortcut: String) {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", shortcut])
    }
}
