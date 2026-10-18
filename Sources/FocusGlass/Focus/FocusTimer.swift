import AppKit
import CoreGraphics
import Observation

enum Phase {
    case work
    case rest

    var title: String { self == .work ? "Soustředění" : "Pauza" }
}

/// Pomodoro časovač s detekcí nepřítomnosti. Péči o oči řeší nezávisle `EyeCare`.
///
/// Počítá se vůči cílovému `Date`, takže tik slouží jen k překreslení.
/// Když časovač neběží (a uživatel není „pryč“), neexistuje žádný `Timer` – nulová zátěž CPU.
@MainActor
@Observable
final class FocusTimer {
    /// Těsně před velkou pauzou už mikropauzu pro oči nevyvoláváme.
    static let eyeBreakQuietZone: TimeInterval = 2 * 60

    let settings: AppSettings

    private(set) var profile: FocusProfile
    private(set) var phase: Phase = .work
    private(set) var remaining: TimeInterval
    private(set) var isRunning = false
    private(set) var endDate: Date?
    /// Zastaveno automaticky, protože uživatel odešel od počítače.
    private(set) var isAway = false

    @ObservationIgnored var onPhaseChange: ((_ ended: Phase, _ manual: Bool) -> Void)?
    /// Kolik sekund čisté práce přibylo (záporné = odečíst čas, kdy byl uživatel pryč).
    @ObservationIgnored var onFocusDelta: ((TimeInterval) -> Void)?
    /// Změna běhu (start, pauza, fáze, nepřítomnost).
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored private var lastWorkRemaining: TimeInterval?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var awayPoll: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let profile = FocusProfile.with(id: settings.profileID)
        self.profile = profile
        self.remaining = profile.work
        observeSleep()
        restore()
    }

    var duration: TimeInterval { phase == .work ? profile.work : profile.rest }
    var elapsed: TimeInterval { duration - remaining }
    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }
    var hasStarted: Bool { isRunning || remaining < duration }

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
        lastWorkRemaining = phase == .work ? remaining : nil
        startTicker()
        stateChanged()
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
        stateChanged()
    }

    func skip() {
        advancePhase(manual: true)
    }

    func setProfile(_ newProfile: FocusProfile) {
        profile = newProfile
        reset()
    }

    // MARK: - Interní logika

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)

        if phase == .work {
            if let last = lastWorkRemaining {
                let delta = last - remaining
                if delta > 0 && delta < 10 { onFocusDelta?(delta) }
            }
            lastWorkRemaining = remaining

            if detectAway() { return }
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

        // Pauza začíná vždy sama; nový pracovní blok jen ručně nebo s „po pauze pokračovat“.
        if ended == .work || manual || settings.autoContinue {
            start()
        }
        onPhaseChange?(ended, manual)
        stateChanged()
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
        lastWorkRemaining = nil
        stateChanged()
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
        let before = remaining
        remaining = min(duration, remaining + idle)
        onFocusDelta?(-(remaining - before))
        haltTicker()
        isAway = true
        awayPoll = Self.repeating(every: 1) { [weak self] in self?.checkReturn() }
        stateChanged()
        return true
    }

    private func checkReturn() {
        guard Self.idleSeconds < 2 else { return }
        start()
    }

    private func stopAwayPoll() {
        awayPoll?.invalidate()
        awayPoll = nil
        isAway = false
    }

    // MARK: - Uložení stavu (přežije restart i reinstalaci)

    private static let stateKey = "timerState"

    private func stateChanged() {
        persist()
        onStateChange?()
    }

    private func persist() {
        var state: [String: Any] = [
            "profile": profile.id,
            "phase": phase == .work ? "work" : "rest",
            "remaining": remaining,
        ]
        // Běžící blok si pamatuje cílový čas; „pryč od počítače“ se obnoví jako pauza.
        if let endDate, isRunning { state["endDate"] = endDate.timeIntervalSince1970 }
        UserDefaults.standard.set(state, forKey: Self.stateKey)
    }

    private func restore() {
        guard let state = UserDefaults.standard.dictionary(forKey: Self.stateKey),
              state["profile"] as? String == profile.id,
              let savedRemaining = state["remaining"] as? TimeInterval else { return }
        phase = state["phase"] as? String == "rest" ? .rest : .work

        if let end = state["endDate"] as? TimeInterval {
            let left = Date(timeIntervalSince1970: end).timeIntervalSinceNow
            guard left > 1 else {
                // Blok mezitím doběhl (aplikace neběžela) – začni čistě.
                phase = .work
                remaining = profile.work
                return
            }
            remaining = min(left, duration)
            // Spustit až po napojení callbacků v AppModel.
            DispatchQueue.main.async { [weak self] in self?.start() }
        } else {
            remaining = min(max(0, savedRemaining), duration)
        }
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

// MARK: - Popisky stavu (sdílí okno z lišty i notch)

extension FocusTimer {
    var statusTitle: String {
        if isAway { return "Mimo počítač" }
        if hasStarted && !isRunning { return "Pozastaveno" }
        return phase.title
    }

    /// Symbol aktuálního stavu (lišta, notch).
    var stateSymbol: String {
        if isAway { return "figure.walk" }
        if hasStarted && !isRunning { return "pause.circle" }
        return phase == .work ? "laptopcomputer" : "cup.and.saucer"
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
