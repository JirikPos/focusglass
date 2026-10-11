import AppKit
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "guard")

/// Během focusu hlídá rušivé aplikace a weby. Dvě úrovně:
/// - **blokovat** – aplikace se schová, web se přesměruje na stránku „Blocked“,
/// - **upozornit** – pustí tě dál, ale notch upozorní a čas se počítá jako ztracený.
///
/// Aplikace: systémová notifikace o přepnutí (žádné dotazování, žádná oprávnění).
/// Weby: jen když je vepředu prohlížeč a běží focus, jednou za 2 s se zeptá na adresu
/// aktivní karty (AppleScript na pozadí; macOS se jednou zeptá na svolení pro každý prohlížeč).
@MainActor
final class DistractionGuard {
    private enum Browser: String {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case arc = "company.thebrowser.Browser"
        case brave = "com.brave.Browser"
        case edge = "com.microsoft.edgemac"

        private var appName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Google Chrome"
            case .arc: "Arc"
            case .brave: "Brave Browser"
            case .edge: "Microsoft Edge"
            }
        }

        private var tab: String { self == .safari ? "current tab of front window" : "active tab of front window" }

        var readURL: String { "tell application \"\(appName)\" to return URL of \(tab)" }

        func redirect(to url: URL) -> String {
            "tell application \"\(appName)\" to set URL of \(tab) to \"\(url.absoluteString)\""
        }
    }

    private static let realertInterval: TimeInterval = 120

    private let settings: AppSettings
    /// Běží teď pracovní blok?
    var isFocusActive: () -> Bool = { false }
    /// Zbývající čas focusu pro stránku „Blocked“.
    var remainingText: () -> String = { "" }
    /// Uživatel přešel na rušivou aplikaci / web (nebo tam zůstává další 2 minuty).
    var onDistraction: ((_ source: String) -> Void)?
    /// Aplikace nebo web byl zablokován.
    var onBlocked: ((_ source: String) -> Void)?
    /// Čas strávený v rušivé aplikaci / webu.
    var onLost: ((TimeInterval) -> Void)?
    /// Zeptá se na důvod; `completion(true)` = uživatel napsal důvod a smí na chvíli dovnitř.
    /// Vrací `false`, pokud se zeptat nejde (např. vypnutý notch) – pak je to tvrdá blokace.
    var askIntent: ((_ source: String, _ completion: @escaping @MainActor (Bool) -> Void) -> Bool)?

    /// Dočasné výjimky (zdroj → do kdy).
    private var allowances: [String: Date] = [:]
    private var pendingIntent: String?

    private var current: String?
    private var since: Date?
    private var lastAlert: Date = .distantPast
    private var browserPoll: Timer?
    private var isQueryingBrowser = false

    init(settings: AppSettings) {
        self.settings = settings
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    /// Přehodnotí aktuální stav (při přepnutí aplikace nebo změně focusu).
    func evaluate() {
        let app = NSWorkspace.shared.frontmostApplication
        log.debug("evaluate app=\(app?.localizedName ?? "-", privacy: .public) focus=\(self.isFocusActive())")
        guard settings.distractionGuard, isFocusActive(), let app else {
            stopBrowserPoll()
            end()
            return
        }

        let name = app.localizedName ?? ""
        if Self.matches(appName: name, list: settings.blockedApps), !isAllowed(name) {
            stopBrowserPoll()
            end()
            app.hide()
            block(name) { [weak app] in
                app?.unhide()
                app?.activate()
            }
            return
        }
        if Self.matches(appName: name, list: settings.distractingApps) {
            stopBrowserPoll()
            begin(name)
            return
        }

        if let browser = app.bundleIdentifier.flatMap(Browser.init(rawValue:)) {
            checkBrowser(browser)
            startBrowserPoll(browser)
        } else {
            stopBrowserPoll()
            end()
        }
    }

    // MARK: - Prohlížeč

    private func checkBrowser(_ browser: Browser) {
        guard !isQueryingBrowser else { return }
        isQueryingBrowser = true
        AppleScriptRunner.run(browser.readURL) { [weak self] address in
            guard let self else { return }
            self.isQueryingBrowser = false
            // Mezitím se mohl změnit prohlížeč vepředu nebo skončit focus.
            guard self.settings.distractionGuard, self.isFocusActive(),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.rawValue else { return }
            log.debug("browser url=\(address ?? "nil", privacy: .public)")
            guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
                return self.end()
            }

            if let site = Self.matchingSite(url, list: self.settings.blockedSites) {
                self.end()
                guard !self.isAllowed(site) else { return }
                let page = BlockPage.write(site: site, remaining: self.remainingText(),
                                           asksReason: self.settings.askReason)
                AppleScriptRunner.run(browser.redirect(to: page))
                self.block(site) {
                    AppleScriptRunner.run(browser.redirect(to: url))
                }
            } else if let site = Self.matchingSite(url, list: self.settings.distractingSites) {
                self.begin(site)
            } else {
                self.end()
            }
        }
    }

    private func startBrowserPoll(_ browser: Browser) {
        stopBrowserPoll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.settings.distractionGuard, self.isFocusActive() else { return self.evaluate() }
                self.checkBrowser(browser)
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        browserPoll = timer
    }

    private func stopBrowserPoll() {
        browserPoll?.invalidate()
        browserPoll = nil
    }

    // MARK: - Blokace a výjimky

    private func isAllowed(_ source: String) -> Bool {
        (allowances[source] ?? .distantPast) > Date()
    }

    /// Zablokuje a případně se zeptá na důvod; po jeho napsání pustí na `allowMinutes` minut.
    private func block(_ source: String, reopen: @escaping @MainActor () -> Void) {
        guard settings.askReason else { return onBlocked?(source) ?? () }
        guard pendingIntent != source else { return }
        pendingIntent = source

        let asked = askIntent?(source) { [weak self] allowed in
            guard let self else { return }
            self.pendingIntent = nil
            guard allowed else { return }
            self.allowances[source] = Date().addingTimeInterval(TimeInterval(self.settings.allowMinutes * 60))
            reopen()
        } ?? false

        if !asked {
            pendingIntent = nil
            onBlocked?(source)
        }
    }

    // MARK: - Upozornění a ztracený čas

    private func begin(_ source: String) {
        let now = Date()
        if current == source {
            if now.timeIntervalSince(lastAlert) >= Self.realertInterval { alert(source, at: now) }
            return
        }
        end()
        current = source
        since = now
        alert(source, at: now)
    }

    private func alert(_ source: String, at date: Date) {
        lastAlert = date
        onDistraction?(source)
    }

    private func end() {
        if let since { onLost?(Date().timeIntervalSince(since)) }
        current = nil
        since = nil
    }

    // MARK: - Porovnání se seznamy

    private static func terms(_ list: String) -> [String] {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func matches(appName: String, list: String) -> Bool {
        let name = appName.lowercased()
        return terms(list).contains { name == $0 || ($0.count >= 4 && name.contains($0)) }
    }

    /// Položka seznamu je doména (`instagram.com`) nebo doména s cestou (`youtube.com/shorts`).
    private static func matchingSite(_ url: URL, list: String) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        return terms(list).first { entry in
            let parts = entry.split(separator: "/", maxSplits: 1)
            let domain = String(parts[0])
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            guard parts.count == 2 else { return true }
            return path.hasPrefix("/" + parts[1])
        }
    }
}

/// Tvrdé hlášky při rozptýlení.
enum DistractionLines {
    static let all = [
        "You said you'd focus. Close it.",
        "This is exactly why you're average.",
        "Nobody's coming to save you. Back to work.",
        "Someone hungrier is working right now.",
        "Your excuses brought you here. Leave.",
        "Comfort is winning. Again.",
        "Is this worth more than your goal?",
    ]

    static func random() -> String { all.randomElement() ?? all[0] }
}
