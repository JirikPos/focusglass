import Foundation
import Security

/// Tajné hodnoty (API klíče) v Klíčence macOS – nikdy v UserDefaults ani v souborech.
///
/// macOS se ptá na heslo jen při čtení *obsahu* položky (a znovu po každém novém podpisu aplikace).
/// Proto: existence se zjišťuje jen z atributů (bez dotazu) a obsah se čte nejvýš jednou za běh.
@MainActor
enum Keychain {
    private static let service = "app.focusglass"
    private static var cache: [String: String?] = [:]

    /// Obsah položky; Klíčenka se zeptá nejvýš jednou za běh aplikace.
    static func get(_ account: String) -> String? {
        if let cached = cache[account] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        // Zamítnutý dotaz neukládat – při dalším použití integrace se zeptá znovu.
        if status == errSecSuccess || status == errSecItemNotFound { cache[account] = value }
        return value
    }

    /// Je položka uložená? Čte jen atributy, takže se macOS na nic neptá.
    static func contains(_ account: String) -> Bool {
        if let cached = cache[account] { return cached != nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        cache[account] = value
        guard let value else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
