import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "clickup")

/// Připojení k ClickUpu (osobní token v Klíčence) a seznam mých otevřených úkolů.
@MainActor
@Observable
final class ClickUpService {
    enum Status: Equatable {
        case notConnected
        case loading
        case ready
        case failed(String)
    }

    private static let tokenKey = "clickUpToken"

    let settings: AppSettings
    /// Moje otevřené úkoly.
    private(set) var tasks: [ClickUpClient.Task] = []
    /// Všechny otevřené úkoly workspace (pro hledání), načtené na pozadí.
    private(set) var allTasks: [ClickUpClient.Task] = []
    private(set) var isLoadingAll = false
    @ObservationIgnored private var allLoadedAt: Date = .distantPast
    private(set) var teams: [ClickUpClient.Team] = []
    private(set) var status: Status = .notConnected

    init(settings: AppSettings) {
        self.settings = settings
        if isConfigured { status = .ready }
    }

    var hasToken: Bool { Keychain.contains(Self.tokenKey) }
    var isConfigured: Bool { hasToken && !settings.clickUpTeamID.isEmpty && settings.clickUpUserID != 0 }
    var client: ClickUpClient? { Keychain.get(Self.tokenKey).map(ClickUpClient.init(token:)) }

    func connect(token: String) async {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenKey)
        guard let client else { return }
        status = .loading
        do {
            settings.clickUpUserID = try await client.userID()
            teams = try await client.teams()
            if settings.clickUpTeamID.isEmpty || !teams.contains(where: { $0.id == settings.clickUpTeamID }) {
                settings.clickUpTeamID = teams.first?.id ?? ""
            }
            status = .ready
            await refreshTasks()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func loadTeams() async {
        guard let client else { return }
        teams = (try? await client.teams()) ?? teams
    }

    func disconnect() {
        Keychain.set(nil, for: Self.tokenKey)
        settings.clickUpTeamID = ""
        settings.clickUpUserID = 0
        tasks = []
        allTasks = []
        allLoadedAt = .distantPast
        teams = []
        status = .notConnected
    }

    /// Načte všechny otevřené úkoly workspace (max. jednou za 5 minut).
    func refreshAllTasks() async {
        guard let client, isConfigured, !isLoadingAll,
              Date().timeIntervalSince(allLoadedAt) > 300 else { return }
        isLoadingAll = true
        defer { isLoadingAll = false }
        do {
            allTasks = try await client.allTasks(team: settings.clickUpTeamID)
            allLoadedAt = Date()
            log.debug("loaded \(self.allTasks.count) workspace tasks")
        } catch {
            log.error("all tasks failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshTasks() async {
        guard let client, isConfigured else { return }
        do {
            tasks = try await client.myTasks(team: settings.clickUpTeamID, user: settings.clickUpUserID)
            log.debug("loaded \(self.tasks.count) my tasks")
            status = .ready
        } catch {
            log.error("tasks failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }
}
