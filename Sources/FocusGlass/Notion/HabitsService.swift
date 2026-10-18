import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "notion")

/// Dnešní návyky z Notionu.
///
/// Databáze typu „řádek = den“ (např. Bad Habit Tracker): sloupec s datem a návyky jako checkboxy.
/// Dnešní řádek se najde podle data (šablona ho obvykle zakládá sama), jinak se založí.
/// Odškrtnutí se hned zapíše zpět do Notionu.
@MainActor
@Observable
final class HabitsService {
    struct Habit: Identifiable, Equatable {
        /// Název checkboxu v Notionu.
        let id: String
        var done: Bool
    }

    enum Status: Equatable {
        case notConnected
        case loading
        case ready
        case failed(String)
    }

    private static let tokenKey = "notionToken"
    /// Název nového řádku, pokud ho FocusGlass zakládá (stejný jako šablona v Notionu).
    private static let newRowTitle = "Úspěšný den"

    let settings: AppSettings
    private(set) var habits: [Habit] = []
    private(set) var status: Status = .notConnected
    private(set) var databases: [NotionClient.Database] = []
    private(set) var lastSync: Date?

    @ObservationIgnored private var database: NotionClient.Database?
    @ObservationIgnored private var todayPageID: String?
    @ObservationIgnored private var loadedDay: String?

    init(settings: AppSettings) {
        self.settings = settings
        if hasToken && !settings.notionDatabaseID.isEmpty { status = .loading }
    }

    // MARK: - Připojení

    var hasToken: Bool { Keychain.contains(Self.tokenKey) }
    var isConfigured: Bool { hasToken && !settings.notionDatabaseID.isEmpty }
    var doneCount: Int { habits.filter(\.done).count }
    var databaseTitle: String? { database?.title ?? databases.first { $0.id == settings.notionDatabaseID }?.title }

    private var client: NotionClient? { Keychain.get(Self.tokenKey).map(NotionClient.init(token:)) }

    /// Uloží klíč integrace a načte databáze, které jsou jí nasdílené.
    func connect(token: String) async {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenKey)
        await loadDatabases()
        // Najdi databázi návyků sám (jediná vhodná, nebo podle názvu).
        if settings.notionDatabaseID.isEmpty, let guess = likelyHabitDatabase {
            await select(databaseID: guess.id)
        }
    }

    func disconnect() {
        Keychain.set(nil, for: Self.tokenKey)
        settings.notionDatabaseID = ""
        database = nil
        databases = []
        habits = []
        todayPageID = nil
        loadedDay = nil
        status = .notConnected
    }

    func loadDatabases() async {
        guard let client else { return status = .notConnected }
        status = .loading
        do {
            databases = try await client.databases()
            status = databases.isEmpty ? .failed("Integrace nevidí žádnou databázi – nasdílej ji (⋯ → Connections).") : .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Databáze vhodné pro návyky: mají datum a aspoň 2 checkboxy.
    var suitableDatabases: [NotionClient.Database] {
        databases.filter { !$0.properties(ofType: "date").isEmpty && $0.properties(ofType: "checkbox").count >= 2 }
    }

    /// S přístupem k celému workspace je databází hodně – zkus poznat tu s návyky.
    private var likelyHabitDatabase: NotionClient.Database? {
        let suitable = suitableDatabases
        if suitable.count == 1 { return suitable[0] }
        let keywords = ["habit", "návyk", "navyk", "tracker"]
        return suitable.first { database in
            keywords.contains { database.title.lowercased().contains($0) }
        }
    }

    func selectDatabase(_ databaseID: String) async {
        await select(databaseID: databaseID)
    }

    func select(databaseID: String) async {
        settings.notionDatabaseID = databaseID
        database = nil
        loadedDay = nil
        await refresh(force: true)
    }

    // MARK: - Dnešek

    /// Načte dnešní řádek. Bez `force` jen jednou za den / po chybě.
    func refresh(force: Bool = false) async {
        guard let client, !settings.notionDatabaseID.isEmpty else { return status = .notConnected }
        let today = Self.dayString(Date())
        if !force, loadedDay == today, status == .ready { return }
        if habits.isEmpty { status = .loading }

        do {
            let database: NotionClient.Database
            if let cached = self.database {
                database = cached
            } else {
                database = try await client.database(id: settings.notionDatabaseID)
            }
            self.database = database
            guard let dateProperty = database.properties(ofType: "date").first?.name else {
                return status = .failed("Databáze nemá sloupec s datem.")
            }
            let checkboxes = database.properties(ofType: "checkbox").map(\.name)

            var page = try await client.pages(in: database.id, dateProperty: dateProperty, date: today).first
            if page == nil {
                let title = database.properties(ofType: "title").first?.name ?? "Name"
                page = try await client.createPage(in: database.id, properties: [
                    title: ["title": [["text": ["content": Self.newRowTitle]]]],
                    dateProperty: ["date": ["start": today]],
                ])
                log.debug("created today's row")
            }
            guard let page else { return }

            todayPageID = page["id"] as? String
            habits = checkboxes.map { Habit(id: $0, done: NotionClient.checkbox(page, $0)) }
            loadedDay = today
            lastSync = Date()
            status = .ready
        } catch {
            log.error("notion refresh failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Zapíše všechny odpovědi z večerního review najednou (jeden požadavek).
    func save(_ answers: [String: Bool]) async throws {
        guard let client else { throw NotionClient.NotionError.http(401, "") }
        if todayPageID == nil { await refresh(force: true) }
        guard let pageID = todayPageID else {
            throw NotionClient.NotionError.http(0, "Dnešní řádek se nepodařilo načíst.")
        }
        try await client.updatePage(pageID, properties: answers.mapValues { ["checkbox": $0] })
        habits = habits.map { Habit(id: $0.id, done: answers[$0.id] ?? $0.done) }
        lastSync = Date()
    }

    /// Odškrtne / zruší návyk a hned to zapíše do Notionu (při chybě se vrátí zpět).
    func toggle(_ habit: Habit) async {
        guard let client, let pageID = todayPageID,
              let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        let newValue = !habits[index].done
        habits[index].done = newValue
        do {
            try await client.updatePage(pageID, properties: [habit.id: ["checkbox": newValue]])
            lastSync = Date()
        } catch {
            habits[index].done = !newValue
            status = .failed(error.localizedDescription)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
