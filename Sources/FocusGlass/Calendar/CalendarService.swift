import AppKit
import EventKit
import Observation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "calendar")

/// Nejbližší schůzka z Kalendáře. Načítá se jen při otevření notche a při změně kalendáře,
/// nic se pravidelně nedotazuje.
@MainActor
@Observable
final class CalendarService {
    struct Meeting: Equatable {
        let title: String
        let start: Date
    }

    private(set) var next: Meeting?
    private(set) var status = EKEventStore.authorizationStatus(for: .event)

    var isAuthorized: Bool { status == .fullAccess }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var enabled = false

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard enabled else {
            next = nil
            return
        }
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .notDetermined else { return refresh() }
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] granted, error in
            log.debug("calendar access granted=\(granted) error=\(String(describing: error), privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.status = EKEventStore.authorizationStatus(for: .event)
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        guard enabled, isAuthorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(16 * 3600), calendars: nil)
        let all = store.events(matching: predicate)
        log.debug("calendar events in 3h: \(all.count) calendars=\(self.store.calendars(for: .event).count)")
        let event = all
            .filter { !$0.isAllDay && $0.startDate > now }
            .min { $0.startDate < $1.startDate }
        let meeting = event.map { Meeting(title: $0.title ?? "Schůzka", start: $0.startDate) }
        if meeting != next { next = meeting }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Minuty do schůzky, pokud začíná do hodiny.
    var minutesUntilNext: Int? {
        guard let next else { return nil }
        let minutes = Int((next.start.timeIntervalSinceNow / 60).rounded(.up))
        return (0...60).contains(minutes) ? minutes : nil
    }
}
