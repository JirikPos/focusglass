import Foundation

/// Tenký klient Notion API (https://developers.notion.com). Vidí jen databáze a stránky,
/// které uživatel integraci výslovně nasdílel.
struct NotionClient {
    struct Property: Hashable {
        let name: String
        let type: String
    }

    struct Database: Identifiable, Hashable {
        let id: String
        let title: String
        let properties: [Property]

        func properties(ofType type: String) -> [Property] {
            properties.filter { $0.type == type }.sorted { $0.name < $1.name }
        }
    }

    enum NotionError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(401, _): "Neplatný klíč integrace."
            case .http(404, _): "Databáze nenalezena – je nasdílená integraci (⋯ → Connections)?"
            case .http(let code, let message): "Notion \(code): \(message)"
            }
        }
    }

    let token: String
    private static let base = URL(string: "https://api.notion.com/v1/")!

    // MARK: - Databáze

    /// Všechny databáze nasdílené integraci (i víc než 100 – načítá po stránkách).
    func databases() async throws -> [Database] {
        var all: [Database] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "filter": ["property": "object", "value": "database"],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await request("POST", "search", body: body)
            let results = json["results"] as? [[String: Any]] ?? []
            all += results.map(Self.parseDatabase)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil && all.count < 1000
        return all.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func database(id: String) async throws -> Database {
        Self.parseDatabase(try await request("GET", "databases/\(id)"))
    }

    /// Řádky databáze s daným datem.
    func pages(in database: String, dateProperty: String, date: String) async throws -> [[String: Any]] {
        let json = try await request("POST", "databases/\(database)/query", body: [
            "filter": ["property": dateProperty, "date": ["equals": date]],
            "page_size": 100,
        ])
        return json["results"] as? [[String: Any]] ?? []
    }

    func createPage(in database: String, properties: [String: Any]) async throws -> [String: Any] {
        try await request("POST", "pages", body: ["parent": ["database_id": database], "properties": properties])
    }

    func updatePage(_ id: String, properties: [String: Any]) async throws {
        _ = try await request("PATCH", "pages/\(id)", body: ["properties": properties])
    }

    // MARK: - Čtení hodnot

    static func checkbox(_ page: [String: Any], _ property: String) -> Bool {
        let properties = page["properties"] as? [String: Any]
        return (properties?[property] as? [String: Any])?["checkbox"] as? Bool ?? false
    }

    /// Výsledek vzorce (číslo nebo text), např. sloupec „Score“.
    static func formula(_ page: [String: Any], _ property: String) -> String? {
        let properties = page["properties"] as? [String: Any]
        guard let formula = (properties?[property] as? [String: Any])?["formula"] as? [String: Any] else { return nil }
        if let number = formula["number"] as? Double { return String(format: number == number.rounded() ? "%.0f" : "%.1f", number) }
        return formula["string"] as? String
    }

    static func title(_ page: [String: Any]) -> String {
        let properties = page["properties"] as? [String: [String: Any]] ?? [:]
        guard let title = properties.values.first(where: { $0["type"] as? String == "title" }),
              let parts = title["title"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }

    // MARK: - Interní

    private static func parseDatabase(_ json: [String: Any]) -> Database {
        let titleParts = json["title"] as? [[String: Any]] ?? []
        let title = titleParts.compactMap { $0["plain_text"] as? String }.joined()
        let rawProperties = json["properties"] as? [String: [String: Any]] ?? [:]
        let properties = rawProperties.map { Property(name: $0.key, type: $0.value["type"] as? String ?? "") }
        return Database(id: json["id"] as? String ?? "", title: title.isEmpty ? "Bez názvu" : title,
                        properties: properties)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            throw NotionError.http(status, json["message"] as? String ?? "")
        }
        return json
    }
}
