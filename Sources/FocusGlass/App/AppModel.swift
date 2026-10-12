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
    let clickUp: ClickUpService
    let session = WorkSession()
    let stayAwake = StayAwake()
    @ObservationIgnored private var taskPoll: Timer?
    @ObservationIgnored private lazy var screenshotWatcher = FolderWatcher(kind: .screenshots) { [weak self] url in
        self?.fileArrived(url)
    }
    @ObservationIgnored private lazy var downloadWatcher = FolderWatcher(kind: .downloads) { [weak self] url in
        self?.fileArrived(url)
    }
    @ObservationIgnored private let power = PowerMonitor()
    @ObservationIgnored private let resources = ResourceMonitor()
    @ObservationIgnored private var meetingTimer: Timer?
    @ObservationIgnored private var alertedMeetingID: String?
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
        self.clickUp = ClickUpService(settings: settings)

        timer.onEyeBreak = { [weak self] in self?.startEyeBreak() }
        timer.onPhaseChange = { [weak self] ended, manual in
            self?.phaseChanged(ended: ended, manual: manual)
        }
        timer.onFocusDelta = { [weak self] seconds in
            self?.stats.addFocus(seconds)
            self?.session.add(seconds)
        }
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

        calendar.onChange = { [weak self] in self?.scheduleMeetingAlert() }
        calendar.setEnabled(settings.calendarEnabled)
        clipboard.setEnabled(settings.clipboardEnabled)
        registerHotKeys()
        setUpSystemExtras()

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
            // Vývoj: `--battery` / `--peek` ukážou animaci nabíjení / pasivní odkladiště.
            if CommandLine.arguments.contains("--battery") { self.notch.showBattery(percent: 76, charging: true) }
            if CommandLine.arguments.contains("--peek") { self.notch.peekShelf() }
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
        let review = ended == .work ? finishSession(ask: true) : nil
        guard !manual else {
            // Ručně přeskočený blok: vyhodnocení úkolů v notchi.
            if let review { notch.showTaskReview(review) }
            return
        }
        playSound("Glass")
        if ended == .work { stats.addBlock() }

        if ended == .work, let end = timer.endDate {
            overlay.present(
                mode: .rest,
                quote: Quotes.random(),
                until: end,
                onSkip: { [weak self] in self?.timer.skip() },
                review: review,
                // Pauzu zavřeš bez vyhodnocení → zapíše se aspoň čas.
                onFinish: { _ in review?.save([:]) }
            )
        } else if let review {
            notch.showTaskReview(review)
        }
    }

    // MARK: - Úkoly v bloku (ClickUp + vlastní)

    /// Nový pracovní blok → „Na čem budeš pracovat?“
    private func beginSession() {
        focusLog.debug("begin session, clickUp=\(self.clickUp.isConfigured)")
        session.begin()
        Task {
            if clickUp.isConfigured { await clickUp.refreshTasks() }
            let shown = notch.showTaskPicker(NotchState.TaskPickerRequest(
                excluded: [],
                choose: { [weak self] items in
                    self?.session.choose(items)
                    self?.startTaskPoll()
                },
                skip: { [weak self] in self?.session.skipChoice() }
            ))
            focusLog.debug("task picker shown=\(shown)")
            if !shown { session.skipChoice() }
        }
    }

    /// Přidat úkoly uprostřed bloku (z panelu Focus).
    func addTasksToSession() {
        guard session.isActive else { return }
        notch.showTaskPicker(NotchState.TaskPickerRequest(
            excluded: Set(session.items.map(\.id)),
            choose: { [weak self] items in
                self?.session.append(items)
                self?.startTaskPoll()
            },
            skip: {}
        ))
    }

    /// Ukončí blok. `ask` = vrátí žádost o vyhodnocení, jinak rovnou zapíše čas.
    private func finishSession(ask: Bool) -> NotchState.TaskReviewRequest? {
        stopTaskPoll()
        guard session.isActive else { return nil }
        let items = session.end()
        guard !items.isEmpty else { return nil }

        let once = SaveOnce()
        let request = NotchState.TaskReviewRequest(items: items) { [weak self] answers in
            guard !once.done else { return }
            once.done = true
            self?.saveSession(items, answers: answers)
        }
        if !ask { request.save([:]) }
        return ask ? request : nil
    }

    /// Statistiky + ClickUp: čistý čas jako záznam času, „Ano“ → úkol uzavřít.
    private func saveSession(_ items: [WorkSession.Item], answers: [String: Bool]) {
        let done = items.filter { answers[$0.id] == true || $0.closedInClickUp }.count
        stats.addTasks(planned: items.count, done: done)

        guard clickUp.isConfigured, let client = clickUp.client else { return }
        let team = settings.clickUpTeamID
        Task {
            var failures = 0
            for item in items {
                guard let task = item.clickUp else { continue }
                do {
                    if item.seconds >= 60 {
                        let start = item.firstStart ?? Date().addingTimeInterval(-item.seconds)
                        try await client.addTime(team: team, task: task.id, start: start, seconds: item.seconds)
                    }
                    if answers[item.id] == true, !item.closedInClickUp,
                       let status = try await client.closedStatus(list: task.listID) {
                        try await client.setStatus(task: task.id, status: status)
                    }
                } catch {
                    failures += 1
                }
            }
            if failures > 0 {
                notch.showAlert(title: "ClickUp: \(failures)× zápis selhal",
                                detail: "Zkontroluj připojení v nastavení")
            }
            await clickUp.refreshTasks()
        }
    }

    /// Během bloku se každé 2 minuty podívá, jestli jsi některý úkol neuzavřel přímo v ClickUpu.
    private func startTaskPoll() {
        stopTaskPoll()
        guard session.hasClickUpItems, clickUp.isConfigured else { return }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClosedTasks() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        taskPoll = timer
    }

    private func stopTaskPoll() {
        taskPoll?.invalidate()
        taskPoll = nil
    }

    private func checkClosedTasks() {
        guard session.isActive, let client = clickUp.client else { return stopTaskPoll() }
        let open = session.items.filter { $0.clickUp != nil && !$0.closedInClickUp }
        guard !open.isEmpty else { return stopTaskPoll() }
        Task {
            for item in open {
                guard let task = try? await client.task(item.id), task.isClosed else { continue }
                let next = session.markClosed(item.id)
                if let next {
                    notch.showAlert(title: "„\(item.name)“ je v ClickUpu hotový",
                                    detail: "Čas \(item.seconds.hoursMinutes) zapsán · pokračuješ na „\(next.name)“")
                } else {
                    notch.showPrompt(NotchState.Prompt(
                        symbol: "checkmark.circle",
                        title: "Všechno v bloku je hotové",
                        detail: "Vyber další úkol, ať se čas nikam neztratí",
                        primaryTitle: "Vybrat",
                        primary: { [weak self] in self?.addTasksToSession() },
                        secondaryTitle: "Později",
                        secondary: {}
                    ))
                }
            }
        }
    }

    private final class SaveOnce { var done = false }

    // MARK: - Focus, rozptýlení, Nerušit

    private func focusStateChanged() {
        distractionGuard.evaluate()
        updateDoNotDisturb()
        // Nový pracovní blok → zeptej se na úkoly.
        if settings.askTasks, timer.phase == .work, timer.isRunning, !session.isActive {
            beginSession()
        }
        // Blok zresetovaný uprostřed → aspoň zapiš odpracovaný čas.
        if session.isActive, timer.phase == .work, !timer.hasStarted, !timer.isAway {
            _ = finishSession(ask: false)
        }
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

    // MARK: - Screenshoty, stahování, schůzky, baterie, žrouti výkonu

    private func setUpSystemExtras() {
        stayAwake.resetOnLaunch()
        stayAwake.onError = { [weak self] message in
            self?.notch.showAlert(title: "Zůstat vzhůru", detail: message)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stayAwake.restoreOnQuit() }
        }

        power.onPluggedIn = { [weak self] state in
            guard let self, self.settings.batteryAlerts else { return }
            self.notch.showBattery(percent: state.percent, charging: true)
        }
        power.onLow = { [weak self] state in
            guard let self else { return }
            // Mac v tašce se zavřeným víkem nesmí vybít do nuly.
            if self.stayAwake.isOn {
                self.stayAwake.set(false)
                self.notch.showAlert(title: "Spánek vrácen", detail: "Baterie \(state.percent) %")
                return
            }
            guard self.settings.batteryAlerts else { return }
            self.playSound("Tink")
            self.notch.showAlert(title: "Baterie \(state.percent) %", detail: "Připoj nabíječku")
        }
        power.start()

        resources.onHog = { [weak self] hog in
            guard let self else { return }
            self.notch.showPrompt(NotchState.Prompt(
                symbol: "memorychip",
                title: hog.reason,
                detail: "Ukončení uvolní paměť a ušetří baterii",
                primaryTitle: "Ukončit",
                primary: { hog.app.terminate() },
                secondaryTitle: "Nechat",
                secondary: { [weak self] in self?.resources.ignore(hog) }
            ))
        }
        applyExtras()
    }

    /// Zapne / vypne sledování podle nastavení (volá i nastavení po přepnutí).
    func applyExtras() {
        screenshotWatcher.setEnabled(settings.screenshotsToShelf)
        downloadWatcher.setEnabled(settings.downloadsToShelf)
        resources.setEnabled(settings.hogAlerts)
        scheduleMeetingAlert()
    }

    /// Nový screenshot / stažený soubor → do odkladiště a na chvíli ukázat v notchi.
    private func fileArrived(_ url: URL) {
        shelf.add(url)
        notch.peekShelf()
    }

    /// Jeden časovač na 2 minuty před nejbližší schůzkou (žádné dotazování).
    private func scheduleMeetingAlert() {
        meetingTimer?.invalidate()
        meetingTimer = nil
        guard settings.meetingAlerts, settings.calendarEnabled,
              let meeting = calendar.next, meeting.id != alertedMeetingID,
              meeting.start.timeIntervalSinceNow > -300 else { return }

        let delay = max(1, meeting.start.addingTimeInterval(-120).timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.announce(meeting) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        meetingTimer = timer
    }

    private func announce(_ meeting: CalendarService.Meeting) {
        alertedMeetingID = meeting.id
        let minutes = Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up))
        playSound("Glass")
        notch.showPrompt(NotchState.Prompt(
            symbol: "video",
            title: minutes > 0 ? "\(meeting.title) za \(minutes) min" : "\(meeting.title) právě začíná",
            detail: meeting.joinURL == nil
                ? meeting.start.formatted(date: .omitted, time: .shortened)
                : "\(meeting.start.formatted(date: .omitted, time: .shortened)) · \(meeting.joinURL?.host ?? "")",
            primaryTitle: meeting.joinURL == nil ? "OK" : "Připojit",
            primary: { if let url = meeting.joinURL { NSWorkspace.shared.open(url) } },
            secondaryTitle: "Zavřít",
            secondary: {}
        ))
        // Naplánuj další schůzku.
        calendar.refresh()
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
