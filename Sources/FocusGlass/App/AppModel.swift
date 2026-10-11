import AppKit
import Observation
import OSLog

private let focusLog = Logger(subsystem: "app.focusglass", category: "focus")

/// Propojuje všechny funkce (časovač, notch, statistiky, hlídač…). Žije po celou dobu běhu aplikace.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let timer: FocusTimer
    let stats: StatsStore
    let media = NowPlaying()
    let shelf = ShelfStore()
    let calendar = CalendarService()
    let clipboard = ClipboardHistory()
    @ObservationIgnored let spectrum = AudioSpectrum()
    let habits: HabitsService
    @ObservationIgnored private var reviewTimer: Timer?
    @ObservationIgnored private let forcedReview = ForcedReviewController()
    private(set) var quote = Quotes.random()

    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private var notch: NotchController!
    @ObservationIgnored private let distractionGuard: DistractionGuard
    @ObservationIgnored private let doNotDisturb = DoNotDisturb()
    @ObservationIgnored private let suggester: FocusSuggester
    @ObservationIgnored private var isEyeBreakActive = false

    init() {
        // Celá aplikace je v matně černém stylu bez ohledu na systémový vzhled.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        let settings = AppSettings()
        self.settings = settings
        self.timer = FocusTimer(settings: settings)
        self.stats = StatsStore(settings: settings)
        self.distractionGuard = DistractionGuard(settings: settings)
        self.suggester = FocusSuggester(settings: settings)
        self.habits = HabitsService(settings: settings)

        timer.onEyeBreak = { [weak self] in self?.startEyeBreak() }
        timer.onPhaseChange = { [weak self] ended, manual in
            self?.phaseChanged(ended: ended, manual: manual)
        }
        timer.onFocusDelta = { [weak self] seconds in self?.stats.addFocus(seconds) }
        timer.onStateChange = { [weak self] in self?.focusStateChanged() }

        distractionGuard.isFocusActive = { [weak self] in
            guard let self else { return false }
            let active = self.timer.phase == .work && self.timer.isRunning
            if !active {
                focusLog.debug("guard idle: phase=\(self.timer.phase == .work ? "work" : "rest", privacy: .public) running=\(self.timer.isRunning) away=\(self.timer.isAway)")
            }
            return active
        }
        distractionGuard.onDistraction = { [weak self] source in self?.distracted(by: source) }
        distractionGuard.onBlocked = { [weak self] source in self?.blocked(source) }
        distractionGuard.askIntent = { [weak self] source, completion in
            self?.askIntent(for: source, completion: completion) ?? false
        }
        distractionGuard.remainingText = { [weak self] in self?.timer.remaining.clock ?? "" }
        distractionGuard.onLost = { [weak self] seconds in self?.stats.addLost(seconds) }

        suggester.canSuggest = { [weak self] in
            guard let self else { return false }
            return self.timer.phase == .work && !self.timer.isRunning && !self.timer.isAway
                && !self.isEyeBreakActive && self.settings.notchEnabled
        }
        suggester.onSuggest = { [weak self] app in self?.suggestFocus(in: app) }

        calendar.setEnabled(settings.calendarEnabled)
        clipboard.setEnabled(settings.clipboardEnabled)
        registerHotKeys()

        notch = NotchController(model: self)
        // Okna až po dokončení startu aplikace.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notch.setEnabled(self.settings.notchEnabled)
            if CommandLine.arguments.contains("--notch-open") {
                self.notch.expandForPreview()
            }
            self.suggester.evaluate()
            self.scheduleEveningReview()
            Task { await self.habits.refresh() }
            // Vývoj: `--review` rovnou ukáže vynucené review.
            if CommandLine.arguments.contains("--review") {
                self.forcedReview.present(model: self) { _ in }
            }
            // Vývoj: `--suggest` rovnou ukáže nabídku focusu.
            if CommandLine.arguments.contains("--suggest") {
                self.suggestFocus(in: "Code")
            }
        }

        // Vývoj: `--focus` rovnou spustí pracovní blok.
        if CommandLine.arguments.contains("--focus") {
            DispatchQueue.main.async { [weak self] in self?.timer.start() }
        }

        // Vývoj: `make preview` spustí aplikaci rovnou s cvičením očí.
        if CommandLine.arguments.contains("--eye-break") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startEyeBreak()
            }
        }
    }

    func selectProfile(_ profile: FocusProfile) {
        settings.profileID = profile.id
        timer.setProfile(profile)
    }

    func setNotchEnabled(_ enabled: Bool) {
        settings.notchEnabled = enabled
        notch.setEnabled(enabled)
    }

    func setCalendarEnabled(_ enabled: Bool) {
        settings.calendarEnabled = enabled
        calendar.setEnabled(enabled)
    }

    func setClipboardEnabled(_ enabled: Bool) {
        settings.clipboardEnabled = enabled
        clipboard.setEnabled(enabled)
    }

    func setDistractionGuard(_ enabled: Bool) {
        settings.distractionGuard = enabled
        distractionGuard.evaluate()
    }

    func setAutoDND(_ enabled: Bool) {
        settings.autoDND = enabled
        updateDoNotDisturb()
    }

    func shuffleQuote() {
        quote = Quotes.random(excluding: quote)
    }

    /// Minuta pro oči: pozastaví pomodoro, ukáže cvičení a pak časovač zase rozběhne.
    func startEyeBreak() {
        let resumeAfter = timer.isRunning
        isEyeBreakActive = true
        timer.pause()
        playSound("Tink")

        overlay.present(
            mode: .eyes,
            quote: Quotes.random(),
            until: Date().addingTimeInterval(FocusTimer.eyeBreakDuration),
            onFinish: { [weak self] finished in
                guard let self else { return }
                if finished { self.playSound("Pop") }
                self.isEyeBreakActive = false
                self.timer.eyesRested()
                if resumeAfter { self.timer.start() }
            }
        )
    }

    private func phaseChanged(ended: Phase, manual: Bool) {
        overlay.dismiss()
        guard !manual else { return }
        playSound("Glass")
        if ended == .work { stats.addBlock() }

        if ended == .work, let end = timer.endDate {
            overlay.present(
                mode: .rest,
                quote: Quotes.random(),
                until: end,
                onSkip: { [weak self] in self?.timer.skip() }
            )
        }
    }

    // MARK: - Focus, rozptýlení, Nerušit

    private func focusStateChanged() {
        distractionGuard.evaluate()
        updateDoNotDisturb()
        if timer.isRunning { suggester.reset() } else { suggester.evaluate() }
    }

    /// „Pracuješ v Code. Spustit focus?“
    private func suggestFocus(in app: String) {
        let profile = timer.profile
        let started = timer.hasStarted
        playSound("Tink")
        notch.showPrompt(NotchState.Prompt(
            symbol: "laptopcomputer",
            title: started ? "Pracuješ v \(app). Pokračovat ve focusu?" : "Pracuješ v \(app). Spustit focus?",
            detail: started ? "Zbývá \(timer.remaining.clock)" : "\(Int(profile.work / 60)) min práce · hlídač a Nerušit se zapnou",
            primaryTitle: started ? "Pokračovat" : "Spustit",
            primary: { [weak self] in self?.timer.start() },
            secondaryTitle: "Teď ne",
            secondary: { [weak self] in self?.suggester.snooze(minutes: 60) }
        ))
    }

    /// Nerušit drží celý pracovní blok včetně minut pro oči a chvil mimo počítač.
    private func updateDoNotDisturb() {
        let working = timer.phase == .work && (timer.isRunning || timer.isAway || isEyeBreakActive)
        doNotDisturb.set(settings.autoDND && working)
    }

    private func distracted(by source: String) {
        playSound("Basso")
        notch.showAlert(
            title: DistractionLines.random(),
            detail: "\(source) · dnes ztraceno \(stats.today.lost.hoursMinutes)"
        )
    }

    /// Notch se zeptá, proč tam chceš jít. Důvod se zapíše do deníku výjimek.
    private func askIntent(for source: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard settings.notchEnabled else { return false }
        playSound("Basso")
        return notch.askIntent(NotchState.IntentRequest(
            source: source,
            minutes: settings.allowMinutes,
            submit: { reason in
                IntentLog.append(source: source, reason: reason)
                completion(true)
            },
            cancel: { completion(false) }
        ))
    }

    private func blocked(_ source: String) {
        playSound("Basso")
        notch.showAlert(title: DistractionLines.random(), detail: "\(source) je během focusu zablokovaný")
    }

    /// ⌃⌥ mezerník = notch, ⌃⌥ ↩ = start/pauza, ⌃⌥ V = schránka.
    private func registerHotKeys() {
        let modifiers = HotKeys.Modifier.control | HotKeys.Modifier.option
        HotKeys.shared.register(keyCode: 49, modifiers: modifiers) { [weak self] in
            self?.notch.toggle()
        }
        HotKeys.shared.register(keyCode: 36, modifiers: modifiers) { [weak self] in
            self?.timer.toggle()
        }
        HotKeys.shared.register(keyCode: 9, modifiers: modifiers) { [weak self] in
            guard let self, self.settings.clipboardEnabled else { return }
            self.notch.open(tab: .clipboard)
        }
    }

    // MARK: - Večerní review (návyky z Notionu)

    private static let reviewedKey = "eveningReviewDay"

    private var reviewedToday: Bool {
        UserDefaults.standard.string(forKey: Self.reviewedKey) == Self.today
    }

    private static var today: String {
        Date().formatted(.iso8601.year().month().day())
    }

    /// Naplánuje večerní review na nastavenou hodinu (jeden časovač, žádné dotazování).
    func scheduleEveningReview() {
        reviewTimer?.invalidate()
        reviewTimer = nil
        guard settings.eveningReview, habits.isConfigured else { return }

        let calendar = Calendar.current
        let now = Date()
        let todayAt = calendar.date(bySettingHour: settings.reviewHour, minute: 0, second: 0, of: now) ?? now
        // Už je po hodině review a dnes ještě neproběhlo (Mac byl zavřený / spal) → zeptej se hned.
        // Vynucené review platí až do půlnoci, běžná otázka jen do 23:00.
        let stillToday = settings.forceReview || calendar.component(.hour, from: now) < 23
        if todayAt <= now, !reviewedToday, stillToday {
            return scheduleReviewPrompt(after: 10)
        }
        let next = todayAt > now ? todayAt : (calendar.date(byAdding: .day, value: 1, to: todayAt) ?? todayAt)
        scheduleReviewPrompt(after: next.timeIntervalSince(now))
    }

    private func scheduleReviewPrompt(after delay: TimeInterval) {
        reviewTimer?.invalidate()
        let timer = Timer(timeInterval: max(1, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.promptEveningReview() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        reviewTimer = timer
    }

    private func promptEveningReview() {
        guard settings.eveningReview, habits.isConfigured, !reviewedToday else { return scheduleEveningReview() }
        if settings.forceReview { return presentForcedReview() }
        Task {
            await habits.refresh(force: true)
            let done = habits.doneCount
            let total = habits.habits.count
            playSound("Glass")
            notch.showPrompt(NotchState.Prompt(
                symbol: "checklist",
                title: "Večerní review",
                detail: "Návyky dnes \(done)/\(total) · focus \(stats.today.focus.hoursMinutes) · \(stats.verdict)",
                primaryTitle: "Otevřít",
                primary: { [weak self] in self?.openReview() },
                secondaryTitle: "Za 30 min",
                secondary: { [weak self] in self?.scheduleReviewPrompt(after: 30 * 60) }
            ))
            // Když se otázka nezobrazí nebo ji ignoruješ, zeptá se znovu za 30 minut.
            scheduleReviewPrompt(after: 30 * 60)
        }
    }

    /// Přes celou obrazovku; nepustí, dokud review nevyplníš (nebo nouzový únik).
    func presentForcedReview() {
        reviewTimer?.invalidate()
        playSound("Glass")
        forcedReview.present(model: self) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(Self.today, forKey: Self.reviewedKey)
            self.scheduleEveningReview()
        }
    }

    func openReview() {
        UserDefaults.standard.set(Self.today, forKey: Self.reviewedKey)
        notch.open(tab: .habits)
        scheduleEveningReview()
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
