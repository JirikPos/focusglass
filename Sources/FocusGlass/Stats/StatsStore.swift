import AppKit
import Observation

struct DayStats: Codable, Equatable {
    /// Sekundy čisté práce (bez pauz a času mimo počítač).
    var focus: TimeInterval = 0
    /// Sekundy strávené v rušivých aplikacích / webech během focusu.
    var lost: TimeInterval = 0
    /// Dokončené pracovní bloky.
    var blocks = 0
    /// Úkoly naplánované / splněné v blocích (volitelné kvůli starším uloženým datům).
    var tasksPlanned: Int?
    var tasksDone: Int?
}

/// Denní statistiky, série a tvrdé hodnocení dne. Uloženo v UserDefaults.
@MainActor
@Observable
final class StatsStore {
    private static let key = "dayStats"

    let settings: AppSettings
    private(set) var days: [String: DayStats]
    @ObservationIgnored private var unsaved: TimeInterval = 0

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(settings: AppSettings) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let days = try? JSONDecoder().decode([String: DayStats].self, from: data) {
            self.days = days
        } else {
            days = [:]
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    // MARK: - Zápis

    func addFocus(_ seconds: TimeInterval) {
        update { $0.focus = max(0, $0.focus + seconds) }
        unsaved += abs(seconds)
        if unsaved >= 30 { save() }
    }

    func addLost(_ seconds: TimeInterval) {
        update { $0.lost += seconds }
        save()
    }

    func addTasks(planned: Int, done: Int) {
        update {
            $0.tasksPlanned = ($0.tasksPlanned ?? 0) + planned
            $0.tasksDone = ($0.tasksDone ?? 0) + done
        }
        save()
    }

    func addBlock() {
        update { $0.blocks += 1 }
        save()
    }

    private func update(_ change: (inout DayStats) -> Void) {
        let key = Self.key(for: Date())
        var day = days[key] ?? DayStats()
        change(&day)
        days[key] = day
    }

    private func save() {
        unsaved = 0
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: - Čtení

    var goal: TimeInterval { TimeInterval(settings.dailyGoalHours) * 3600 }
    var today: DayStats { day(offset: 0) }
    var yesterday: DayStats { day(offset: -1) }

    func day(offset: Int) -> DayStats {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return days[Self.key(for: date)] ?? DayStats()
    }

    /// Posledních 7 dní (nejstarší první) se zkratkou dne v týdnu.
    var week: [(label: String, focus: TimeInterval)] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return (-6...0).map { offset in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            let weekday = Calendar.current.component(.weekday, from: date)
            return (symbols[weekday - 1], day(offset: offset).focus)
        }
    }

    /// Dny v řadě se splněným cílem. Dnešek se započítá, až je cíl splněný.
    var streak: Int {
        var count = today.focus >= goal ? 1 : 0
        var offset = -1
        while day(offset: offset).focus >= goal {
            count += 1
            offset -= 1
        }
        return count
    }

    /// Tvrdé, ale férové hodnocení dne.
    var verdict: String {
        let today = today
        let yesterday = yesterday
        if today.focus >= goal { return "Goal hit. Now do it again tomorrow." }
        if today.focus < 60 { return "Zero work today. Nobody's coming to do it for you." }
        if today.lost >= 15 * 60 { return "\(today.lost.hoursMinutes) lost to distractions today. That's on you." }
        if yesterday.focus > today.focus {
            return "Yesterday \(yesterday.focus.hoursMinutes). Today \(today.focus.hoursMinutes). You're getting softer."
        }
        return "\((goal - today.focus).hoursMinutes) left to hit your goal. Move."
    }

    private static func key(for date: Date) -> String {
        formatter.string(from: date)
    }
}

extension TimeInterval {
    /// „2h 10m“ / „45m“.
    var hoursMinutes: String {
        let minutes = Int(self / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
