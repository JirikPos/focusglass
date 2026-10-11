import AppKit
import CoreGraphics

/// Pozná, že pracuješ, a nabídne spuštění focusu.
///
/// Když je vepředu pracovní aplikace a focus neběží, jednou za 30 s se podívá, jestli jsi
/// aktivní (klávesnice / myš). Po 3 minutách aktivní práce se zeptá. Jinak nic neběží.
@MainActor
final class FocusSuggester {
    private static let checkInterval: TimeInterval = 30
    private static let threshold: TimeInterval = 3 * 60
    /// Po zobrazení otázky se další nejdřív za 25 minut.
    private static let cooldown: TimeInterval = 25 * 60

    private let settings: AppSettings
    /// Smí se teď nabízet? (focus neběží, nejsi pryč, není cvičení očí…)
    var canSuggest: () -> Bool = { false }
    var onSuggest: ((_ appName: String) -> Void)?

    private var poll: Timer?
    private var activeSeconds: TimeInterval = 0
    private var quietUntil: Date = .distantPast

    init(settings: AppSettings) {
        self.settings = settings
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func evaluate() {
        guard settings.suggestFocus, canSuggest(), let name = workAppInFront() else { return stop() }
        guard poll == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(name) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// „Teď ne“ – klid na danou dobu.
    func snooze(minutes: Int) {
        quietUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        activeSeconds = 0
    }

    /// Focus se spustil – začni počítat znovu.
    func reset() {
        activeSeconds = 0
        stop()
    }

    private func check(_ name: String) {
        guard settings.suggestFocus, canSuggest(), workAppInFront() != nil else { return stop() }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < 60 { activeSeconds += Self.checkInterval }

        guard activeSeconds >= Self.threshold, Date() >= quietUntil else { return }
        activeSeconds = 0
        quietUntil = Date().addingTimeInterval(Self.cooldown)
        onSuggest?(workAppInFront() ?? name)
    }

    private func workAppInFront() -> String? {
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName,
              DistractionGuard.matches(appName: name, list: settings.workApps) else { return nil }
        return name
    }

    private func stop() {
        poll?.invalidate()
        poll = nil
    }
}
