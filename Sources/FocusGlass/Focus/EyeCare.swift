import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import Observation

/// Péče o oči 20-20-1 nezávislá na pomodoru: počítá souvislý čas u obrazovky,
/// ať pracuješ, nebo se díváš na film.
///
/// Za „u obrazovky“ se bere: displej svítí a buď se dotýkáš myši / klávesnice,
/// nebo nějaká aplikace drží displej vzhůru (přehrávání videa v prohlížeči, QuickTime, IINA…).
/// Uspání, zhasnutý displej, zamčení nebo odchod od počítače počítadlo vynulují – oči si odpočinuly.
@MainActor
@Observable
final class EyeCare {
    static let interval: TimeInterval = 20 * 60
    static let breakDuration: TimeInterval = 60
    private static let tickInterval: TimeInterval = 5

    let settings: AppSettings

    /// Souvislý čas u obrazovky od poslední pauzy pro oči.
    private(set) var screenTime: TimeInterval = 0

    @ObservationIgnored var onEyeBreak: (() -> Void)?
    /// Může se teď pauza pro oči ukázat? Jinak se odloží na další tik.
    @ObservationIgnored var canInterrupt: (() -> Bool)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var isScreenOff = false

    init(settings: AppSettings) {
        self.settings = settings
        observeScreen()
        setEnabled(settings.eyeCareEnabled)
    }

    var timeUntilBreak: TimeInterval { max(0, Self.interval - screenTime) }

    var status: String {
        guard settings.eyeCareEnabled else { return "Připomínky vypnuté" }
        return "Další pauza pro oči za \(Int((timeUntilBreak / 60).rounded(.up))) min"
    }

    func setEnabled(_ enabled: Bool) {
        ticker?.invalidate()
        ticker = nil
        reset()
        guard enabled else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Oči si právě odpočinuly (cvičení, pauza pomodora, odchod) – počítá se znovu od nuly.
    func reset() {
        screenTime = 0
        lastTick = Date()
    }

    // MARK: - Interní logika

    private func tick() {
        let now = Date()
        let delta = now.timeIntervalSince(lastTick ?? now)
        lastTick = now

        guard !isScreenOff else { return }
        // Velká mezera mezi tiky = Mac spal.
        guard delta < 60 else { return reset() }

        let idle = Self.idleSeconds
        if idle >= TimeInterval(settings.awayMinutes * 60) && !Self.isDisplayHeldAwake {
            return reset()
        }

        screenTime += delta
        guard screenTime >= Self.interval, canInterrupt?() ?? true else { return }
        reset()
        onEyeBreak?()
    }

    /// Sekundy od posledního pohybu myši / stisku klávesy.
    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Drží některá aplikace displej vzhůru? Přehrávače videa to dělají po celou dobu přehrávání.
    private static var isDisplayHeldAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Any] else { return false }
        return ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains {
            (dict[$0] as? Int ?? 0) > 0
        }
    }

    /// Zhasnutý displej, spánek nebo zamčení = oči odpočívají.
    private func observeScreen() {
        let center = NSWorkspace.shared.notificationCenter
        let off: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let on: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for (names, screenOff) in [(off, true), (on, false)] {
            for name in names {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isScreenOff = screenOff
                        self?.reset()
                    }
                }
            }
        }
    }
}
