import AppKit

/// Autor aplikace. Podle licence (LICENSE) se tyto údaje nesmí z aplikace odstranit.
enum Author {
    static let name = "Jiří Posavád"
    /// Profil autora. Pozor: LinkedIn profily mají tvar `https://www.linkedin.com/in/<slug>`.
    static let profile = "https://linkedin.com/jiří-posavád"
    static let license = "Osobní nekomerční licence · © 2026"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static func openProfile() {
        // Diakritiku v adrese je potřeba zakódovat, jinak URL nevznikne.
        let encoded = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile
        if let url = URL(string: encoded) { NSWorkspace.shared.open(url) }
    }
}
