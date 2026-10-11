import AppKit
import CoreGraphics
import Observation

enum Phase {
    case work
    case rest

    var title: String { self == .work ? "Soustředění" : "Pauza" }
}

/// Pomodoro časovač s mikropauzami pro oči (20-20-1) a detekcí nepřítomnosti.
///
/// Počítá se vůči cílovému `Date`, takže tik slouží jen k překreslení.
/// Když časovač neběží (a uživatel není „pryč“), neexistuje žádný `Timer` – nulová zátěž CPU.
@MainActor
@Observable
final class FocusTimer {
    static let eyeInterval: TimeInterval = 20 * 60
    static let eyeBreakDuration: TimeInterval = 60
    /// Těsně před velkou pauzou už mikropauzu nevyvoláváme.
    private static let eyeBreakQuietZone: TimeInterval = 2 * 60

    let settings: AppSettings

    private(set) var profile: FocusProfile
    private(set) var phase: Phase = .work
    private(set) var remaining: TimeInterval
    private(set) var isRunning = false
    private(set) var endDate: Date?
    /// Uplynulý pracovní čas (s), kdy nastane další péče o oči.
    private(set) var nextEyeBreak: TimeInterval = eyeInterval
    /// Zastaveno automaticky, protože uživatel odešel od počítače.
    private(set) var isAway = false

    @ObservationIgnored var onEyeBreak: (() -> Void)?
    @ObservationIgnored var onPhaseChange: ((_ ended: Phase, _ manual: Bool) -> Void)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var awayPoll: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let profile = FocusProfile.with(id: settings.profileID)
        self.profile = profile
        self.remaining = profile.work
        observeSleep()
    }

    var duration: TimeInterval { phase == .work ? profile.work : profile.rest }
    var elapsed: TimeInterval { duration - remaining }
    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }
    var hasStarted: Bool { isRunning || remaining < duration }

    /// Čas do další péče o oči, nebo `nil`, pokud v tomto bloku už žádná nebude.
    var timeUntilEyeBreak: TimeInterval? {
        guard phase == .work, settings.eyeCareEnabled,
              nextEyeBreak < profile.work - Self.eyeBreakQuietZone else { return nil }
        return max(0, nextEyeBreak - elapsed)
    }

    // MARK: - Ovládání

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        stopAwayPoll()
        guard !isRunning else { return }
        if remaining <= 0 { remaining = duration }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
    }

    func pause() {
        stopAwayPoll()
        guard isRunning else { return }
        tick()
        haltTicker()
    }

    func reset() {
        stopAwayPoll()
        haltTicker()
        phase = .work
        remaining = profile.work
        nextEyeBreak = Self.eyeInterval
    }

    func skip() {
        advancePhase(manual: true)
    }

    func setProfile(_ newProfile: FocusProfile) {
        profile = newProfile
        reset()
    }

    /// Oči si právě odpočinuly – další připomínka až za 20 minut práce.
    func eyesRested() {
        guard phase == .work else { return }
        nextEyeBreak = elapsed + Self.eyeInterval
    }

    // MARK: - Interní logika

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)

        if phase == .work {
            if detectAway() { return }

            if settings.eyeCareEnabled && elapsed >= nextEyeBreak {
                let late = elapsed - nextEyeBreak
                repeat { nextEyeBreak += Self.eyeInterval } while nextEyeBreak <= elapsed
                // Zmeškané připomínky (spánek apod.) nedoháníme.
                if late < 30 && remaining > Self.eyeBreakQuietZone {
                    onEyeBreak?()
                }
            }
        }

        if remaining <= 0 {
            advancePhase(manual: false)
        }
    }

    private func advancePhase(manual: Bool) {
        let ended = phase
        stopAwayPoll()
        haltTicker()
        phase = ended == .work ? .rest : .work
        remaining = duration
        nextEyeBreak = Self.eyeInterval

        // Pauza začíná vždy sama; nový pracovní blok jen ručně nebo s „po pauze pokračovat“.
        if ended == .work || manual || settings.autoContinue {
            start()
        }
        onPhaseChange?(ended, manual)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Self.repeating(every: 1) { [weak self] in self?.tick() }
    }

    private func haltTicker() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        endDate = nil
    }

    // MARK: - Nepřítomnost

    /// Sekundy od posledního pohybu myši / stisku klávesy. Nevyžaduje žádná oprávnění.
    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func detectAway() -> Bool {
        guard settings.awayDetection else { return false }
        let idle = Self.idleSeconds
        guard idle >= TimeInterval(settings.awayMinutes * 60) else { return false }

        // Čas strávený mimo počítač se do práce nepočítá.
        remaining = min(duration, remaining + idle)
        haltTicker()
        isAway = true
        awayPoll = Self.repeating(every: 1) { [weak self] in self?.checkReturn() }
        return true
    }

    private func checkReturn() {
        guard Self.idleSeconds < 2 else { return }
        // Při odchodu si oči odpočinuly, další připomínka až za 20 minut.
        nextEyeBreak = elapsed + Self.eyeInterval
        start()
    }

    private func stopAwayPoll() {
        awayPoll?.invalidate()
        awayPoll = nil
        isAway = false
    }

    // MARK: - Pomocné

    private static func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Při uspání Macu nebo vypnutí displeje se práce pozastaví.
    /// Pokud je uživatel už „pryč“, necháme běžet hlídání návratu.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAway else { return }
                    self.pause()
                }
            }
        }
    }
}

extension TimeInterval {
    /// Formát `m:ss` (zaokrouhleno nahoru, aby 0:00 znamenalo opravdu konec).
    var clock: String {
        let total = Int(rounded(.up))
        let seconds = total % 60
        return "\(total / 60):" + (seconds < 10 ? "0" : "") + "\(seconds)"
    }
}
