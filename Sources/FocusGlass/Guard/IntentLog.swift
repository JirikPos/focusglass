import Foundation

/// Deník výjimek: kdy, kam a proč sis během focusu dovolil blokovaný web / aplikaci.
enum IntentLog {
    struct Entry: Codable {
        let date: Date
        let source: String
        let reason: String
    }

    private static let key = "intentLog"
    private static let limit = 300

    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func append(source: String, reason: String) {
        var all = entries
        all.append(Entry(date: Date(), source: source, reason: reason))
        if all.count > limit { all.removeFirst(all.count - limit) }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static var todayCount: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }
}
