import Foundation

/// Tenký klient ClickUp API v2 (https://clickup.com/api). Autorizace osobním tokenem (`pk_…`).
struct ClickUpClient {
    struct Team: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Task: Identifiable, Hashable {
        let id: String
        let name: String
        let listID: String
        let listName: String
        /// Typ stavu: `open`, `custom`, `done`, `closed`.
        let statusType: String
        let due: Date?
        let url: String

        var isClosed: Bool { statusType == "closed" || statusType == "done" }
    }

    enum ClickUpError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(401, _): "Neplatný osobní token ClickUpu."
            case .http(let code, let message): "ClickUp \(code): \(message)"
            }
        }
    }

    let token: String
    private static let base = URL(string: "https://api.clickup.com/api/v2/")!

    func userID() async throws -> Int {
        let json = try await request("GET", "user")
        return ((json["user"] as? [String: Any])?["id"] as? Int) ?? 0
    }

    func teams() async throws -> [Team] {
        let json = try await request("GET", "team")
        return (json["teams"] as? [[String: Any]] ?? []).compactMap { team in
            guard let id = team["id"] as? String else { return nil }
            return Team(id: id, name: team["name"] as? String ?? "Workspace")
        }
    }

    /// Otevřené úkoly přiřazené uživateli (všechny stránky), seřazené podle termínu.
    func myTasks(team: String, user: Int) async throws -> [Task] {
        try await openTasks(team: team, assignee: user, maxPages: 20)
    }

    /// Všechny otevřené úkoly ve workspace (pro hledání), nejvýš `maxPages` × 100.
    func allTasks(team: String, maxPages: Int = 30) async throws -> [Task] {
        try await openTasks(team: team, assignee: nil, maxPages: maxPages)
    }

    private func openTasks(team: String, assignee: Int?, maxPages: Int) async throws -> [Task] {
        var all: [Task] = []
        var page = 0
        while page < maxPages {
            var query = [
                URLQueryItem(name: "subtasks", value: "true"),
                URLQueryItem(name: "include_closed", value: "false"),
                URLQueryItem(name: "order_by", value: "updated"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            if let assignee { query.append(URLQueryItem(name: "assignees[]", value: String(assignee))) }
            let json = try await request("GET", "team/\(team)/task", query: query)
            let tasks = (json["tasks"] as? [[String: Any]] ?? []).compactMap(Self.parseTask)
            // `include_closed=false` pouští stavy typu „done“ (např. „complete“) – ty nechceme.
            all += tasks.filter { !$0.isClosed }
            // ClickUp vrací po 100; `last_page` říká, jestli je konec.
            if json["last_page"] as? Bool == true || tasks.count < 100 { break }
            page += 1
        }
        // Úkoly s termínem první (nejbližší nahoře), bez termínu na konec.
        return all.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    func task(_ id: String) async throws -> Task? {
        Self.parseTask(try await request("GET", "task/\(id)"))
    }

    /// Název „hotového“ stavu v daném listu (každý list může mít jiné názvy stavů).
    func closedStatus(list: String) async throws -> String? {
        let json = try await request("GET", "list/\(list)")
        let statuses = json["statuses"] as? [[String: Any]] ?? []
        let closed = statuses.first { $0["type"] as? String == "closed" }
            ?? statuses.first { $0["type"] as? String == "done" }
        return closed?["status"] as? String
    }

    func setStatus(task: String, status: String) async throws {
        _ = try await request("PUT", "task/\(task)", body: ["status": status])
    }

    /// Záznam odpracovaného času k úkolu.
    func addTime(team: String, task: String, start: Date, seconds: TimeInterval) async throws {
        _ = try await request("POST", "team/\(team)/time_entries", body: [
            "tid": task,
            "start": Int64(start.timeIntervalSince1970 * 1000),
            "duration": Int64(seconds * 1000),
            "description": "FocusGlass – čistý focus",
            "billable": false,
        ])
    }

    // MARK: - Interní

    private static func parseTask(_ json: [String: Any]) -> Task? {
        guard let id = json["id"] as? String else { return nil }
        let list = json["list"] as? [String: Any]
        let status = json["status"] as? [String: Any]
        let due = (json["due_date"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Task(
            id: id,
            name: json["name"] as? String ?? "Úkol",
            listID: list?["id"] as? String ?? "",
            listName: list?["name"] as? String ?? "",
            statusType: status?["type"] as? String ?? "open",
            due: due,
            url: json["url"] as? String ?? ""
        )
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            throw ClickUpError.http(status, json["err"] as? String ?? "")
        }
        return json
    }
}
