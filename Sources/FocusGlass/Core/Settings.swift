import ConvertKit
import Foundation
import Observation

struct FocusProfile: Identifiable, Hashable {
    let id: String
    let work: TimeInterval
    let rest: TimeInterval

    var label: String { "\(Int(work / 60))/\(Int(rest / 60))" }

    static let all: [FocusProfile] = [
        FocusProfile(id: "90-15", work: 90 * 60, rest: 15 * 60),
        FocusProfile(id: "60-10", work: 60 * 60, rest: 10 * 60),
        FocusProfile(id: "45-5", work: 45 * 60, rest: 5 * 60),
    ]

    static let `default` = all[0]

    static func with(id: String) -> FocusProfile {
        all.first { $0.id == id } ?? .default
    }
}

/// Uživatelská nastavení uložená v UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let awayOptions = [1, 2, 5]

    private enum Key {
        static let profile = "profileID"
        static let eyeCare = "eyeCareEnabled"
        static let autoContinue = "autoContinue"
        static let sounds = "soundsEnabled"
        static let timeInMenuBar = "showTimeInMenuBar"
        static let awayDetection = "awayDetection"
        static let awayMinutes = "awayMinutes"
        static let notch = "notchEnabled"
        static let distractionGuard = "distractionGuard"
        static let distractingApps = "distractingApps"
        static let distractingSites = "distractingSites"
        static let blockedApps = "blockedApps"
        static let blockedSites = "blockedSites"
        static let askReason = "askReasonOnBlock"
        static let suggestFocus = "suggestFocus"
        static let notionDatabase = "notionDatabaseID"
        static let eveningReview = "eveningReview"
        static let reviewHour = "eveningReviewHour"
        static let forceReview = "forceEveningReview"
        static let askTasks = "askTasksBeforeBlock"
        static let clickUpTeam = "clickUpTeamID"
        static let clickUpUser = "clickUpUserID"
        static let screenshotsToShelf = "screenshotsToShelf"
        static let downloadsToShelf = "downloadsToShelf"
        static let meetingAlerts = "meetingAlerts"
        static let batteryAlerts = "batteryAlerts"
        static let hogAlerts = "resourceHogAlerts"
        static let workApps = "workApps"
        static let allowMinutes = "allowMinutes"
        static let dailyGoal = "dailyGoalHours"
        static let autoDND = "autoDoNotDisturb"
        static let calendar = "calendarEnabled"
        static let clipboard = "clipboardEnabled"
        static let shelfRemoveAfterDrag = "shelfRemoveAfterDrag"
        static let convertEnabled = "convertEnabled"
        static let convertKey = "convertWheelKey"
        static let toolsKey = "toolsWheelKey"
        static let actionsKey = "actionsWheelKey"
        static let convertOutputFolder = "convertOutputFolder"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var profileID: String { didSet { defaults.set(profileID, forKey: Key.profile) } }
    var eyeCareEnabled: Bool { didSet { defaults.set(eyeCareEnabled, forKey: Key.eyeCare) } }
    var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: Key.autoContinue) } }
    var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.sounds) } }
    var showTimeInMenuBar: Bool { didSet { defaults.set(showTimeInMenuBar, forKey: Key.timeInMenuBar) } }
    var awayDetection: Bool { didSet { defaults.set(awayDetection, forKey: Key.awayDetection) } }
    var awayMinutes: Int { didSet { defaults.set(awayMinutes, forKey: Key.awayMinutes) } }
    var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: Key.notch) } }
    var distractionGuard: Bool { didSet { defaults.set(distractionGuard, forKey: Key.distractionGuard) } }
    /// Názvy aplikací oddělené čárkou.
    var distractingApps: String { didSet { defaults.set(distractingApps, forKey: Key.distractingApps) } }
    /// Domény oddělené čárkou (jen upozornit).
    var distractingSites: String { didSet { defaults.set(distractingSites, forKey: Key.distractingSites) } }
    /// Aplikace, které se během focusu schovají.
    var blockedApps: String { didSet { defaults.set(blockedApps, forKey: Key.blockedApps) } }
    /// Weby (doména, volitelně s cestou, např. `youtube.com/shorts`), které se během focusu zablokují.
    var blockedSites: String { didSet { defaults.set(blockedSites, forKey: Key.blockedSites) } }
    /// Při blokaci se zeptat na důvod a po jeho napsání na chvíli pustit.
    var askReason: Bool { didSet { defaults.set(askReason, forKey: Key.askReason) } }
    var allowMinutes: Int { didSet { defaults.set(allowMinutes, forKey: Key.allowMinutes) } }
    /// Nabídnout spuštění focusu, když pracuješ v pracovní aplikaci a focus neběží.
    var suggestFocus: Bool { didSet { defaults.set(suggestFocus, forKey: Key.suggestFocus) } }
    var workApps: String { didSet { defaults.set(workApps, forKey: Key.workApps) } }
    /// Databáze návyků v Notionu (řádek = den). Klíč integrace je v Klíčence.
    var notionDatabaseID: String { didSet { defaults.set(notionDatabaseID, forKey: Key.notionDatabase) } }
    var eveningReview: Bool { didSet { defaults.set(eveningReview, forKey: Key.eveningReview) } }
    var reviewHour: Int { didSet { defaults.set(reviewHour, forKey: Key.reviewHour) } }
    /// Večerní review přes celou obrazovku, nejde zavřít bez vyplnění.
    var forceReview: Bool { didSet { defaults.set(forceReview, forKey: Key.forceReview) } }
    /// Na začátku bloku se zeptat, na jakých úkolech budeš pracovat.
    var askTasks: Bool { didSet { defaults.set(askTasks, forKey: Key.askTasks) } }
    /// ClickUp workspace (team) a uživatel. Token je v Klíčence.
    var clickUpTeamID: String { didSet { defaults.set(clickUpTeamID, forKey: Key.clickUpTeam) } }
    var clickUpUserID: Int { didSet { defaults.set(clickUpUserID, forKey: Key.clickUpUser) } }
    var screenshotsToShelf: Bool { didSet { defaults.set(screenshotsToShelf, forKey: Key.screenshotsToShelf) } }
    var downloadsToShelf: Bool { didSet { defaults.set(downloadsToShelf, forKey: Key.downloadsToShelf) } }
    var meetingAlerts: Bool { didSet { defaults.set(meetingAlerts, forKey: Key.meetingAlerts) } }
    var batteryAlerts: Bool { didSet { defaults.set(batteryAlerts, forKey: Key.batteryAlerts) } }
    var hogAlerts: Bool { didSet { defaults.set(hogAlerts, forKey: Key.hogAlerts) } }
    static let allowOptions = [5, 10, 15]
    var dailyGoalHours: Int { didSet { defaults.set(dailyGoalHours, forKey: Key.dailyGoal) } }
    var autoDND: Bool { didSet { defaults.set(autoDND, forKey: Key.autoDND) } }
    var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: Key.calendar) } }
    var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: Key.clipboard) } }
    var shelfRemoveAfterDrag: Bool { didSet { defaults.set(shelfRemoveAfterDrag, forKey: Key.shelfRemoveAfterDrag) } }
    /// Kolo pro převod souborů při tažení.
    var convertEnabled: Bool { didSet { defaults.set(convertEnabled, forKey: Key.convertEnabled) } }
    var convertKey: WheelKey { didSet { defaults.set(convertKey.rawValue, forKey: Key.convertKey) } }
    var toolsKey: WheelKey { didSet { defaults.set(toolsKey.rawValue, forKey: Key.toolsKey) } }
    var actionsKey: WheelKey { didSet { defaults.set(actionsKey.rawValue, forKey: Key.actionsKey) } }
    /// Složka pro výsledky převodů; prázdné = vedle originálu.
    var convertOutputFolder: String { didSet { defaults.set(convertOutputFolder, forKey: Key.convertOutputFolder) } }

    init() {
        defaults.register(defaults: [
            Key.profile: FocusProfile.default.id,
            Key.eyeCare: true,
            Key.autoContinue: false,
            Key.sounds: true,
            Key.timeInMenuBar: true,
            Key.awayDetection: true,
            Key.awayMinutes: 2,
            Key.notch: true,
            Key.distractionGuard: true,
            Key.distractingApps: "Discord, Telegram, Messenger, WhatsApp",
            Key.distractingSites: "youtube.com",
            Key.blockedApps: "Instagram, TikTok, Steam",
            Key.blockedSites: "instagram.com, tiktok.com, facebook.com, x.com, twitter.com, reddit.com, netflix.com, youtube.com/shorts",
            Key.askReason: true,
            Key.allowMinutes: 10,
            Key.suggestFocus: true,
            Key.workApps: "Code, Cursor, Xcode, ClickUp, Figma, Notion",
            Key.eveningReview: true,
            Key.reviewHour: 18,
            Key.forceReview: false,
            Key.askTasks: true,
            Key.clickUpTeam: "",
            Key.clickUpUser: 0,
            Key.screenshotsToShelf: true,
            Key.downloadsToShelf: true,
            Key.meetingAlerts: true,
            Key.batteryAlerts: true,
            Key.hogAlerts: true,
            Key.dailyGoal: 4,
            Key.autoDND: false,
            Key.calendar: false,
            Key.clipboard: true,
            Key.shelfRemoveAfterDrag: false,
            Key.convertEnabled: true,
            Key.convertKey: WheelKey.shift.rawValue,
            Key.toolsKey: WheelKey.command.rawValue,
            Key.actionsKey: WheelKey.control.rawValue,
            Key.convertOutputFolder: "",
        ])
        profileID = defaults.string(forKey: Key.profile) ?? FocusProfile.default.id
        eyeCareEnabled = defaults.bool(forKey: Key.eyeCare)
        autoContinue = defaults.bool(forKey: Key.autoContinue)
        soundsEnabled = defaults.bool(forKey: Key.sounds)
        showTimeInMenuBar = defaults.bool(forKey: Key.timeInMenuBar)
        awayDetection = defaults.bool(forKey: Key.awayDetection)
        awayMinutes = defaults.integer(forKey: Key.awayMinutes)
        notchEnabled = defaults.bool(forKey: Key.notch)
        distractionGuard = defaults.bool(forKey: Key.distractionGuard)
        distractingApps = defaults.string(forKey: Key.distractingApps) ?? ""
        // Dřívější výchozí seznam (vše jen upozornit) → sociální sítě teď patří do blokovaných.
        let legacySites = "youtube.com, instagram.com, facebook.com, x.com, twitter.com, tiktok.com, reddit.com, netflix.com"
        if defaults.string(forKey: Key.distractingSites) == legacySites {
            defaults.set("youtube.com", forKey: Key.distractingSites)
        }
        distractingSites = defaults.string(forKey: Key.distractingSites) ?? ""
        blockedApps = defaults.string(forKey: Key.blockedApps) ?? ""
        blockedSites = defaults.string(forKey: Key.blockedSites) ?? ""
        askReason = defaults.bool(forKey: Key.askReason)
        allowMinutes = defaults.integer(forKey: Key.allowMinutes)
        suggestFocus = defaults.bool(forKey: Key.suggestFocus)
        workApps = defaults.string(forKey: Key.workApps) ?? ""
        notionDatabaseID = defaults.string(forKey: Key.notionDatabase) ?? ""
        eveningReview = defaults.bool(forKey: Key.eveningReview)
        reviewHour = defaults.integer(forKey: Key.reviewHour)
        forceReview = defaults.bool(forKey: Key.forceReview)
        askTasks = defaults.bool(forKey: Key.askTasks)
        clickUpTeamID = defaults.string(forKey: Key.clickUpTeam) ?? ""
        clickUpUserID = defaults.integer(forKey: Key.clickUpUser)
        screenshotsToShelf = defaults.bool(forKey: Key.screenshotsToShelf)
        downloadsToShelf = defaults.bool(forKey: Key.downloadsToShelf)
        meetingAlerts = defaults.bool(forKey: Key.meetingAlerts)
        batteryAlerts = defaults.bool(forKey: Key.batteryAlerts)
        hogAlerts = defaults.bool(forKey: Key.hogAlerts)
        dailyGoalHours = max(1, defaults.integer(forKey: Key.dailyGoal))
        autoDND = defaults.bool(forKey: Key.autoDND)
        calendarEnabled = defaults.bool(forKey: Key.calendar)
        clipboardEnabled = defaults.bool(forKey: Key.clipboard)
        shelfRemoveAfterDrag = defaults.bool(forKey: Key.shelfRemoveAfterDrag)
        convertEnabled = defaults.bool(forKey: Key.convertEnabled)
        convertKey = WheelKey(rawValue: defaults.string(forKey: Key.convertKey) ?? "") ?? .shift
        toolsKey = WheelKey(rawValue: defaults.string(forKey: Key.toolsKey) ?? "") ?? .command
        actionsKey = WheelKey(rawValue: defaults.string(forKey: Key.actionsKey) ?? "") ?? .control
        convertOutputFolder = defaults.string(forKey: Key.convertOutputFolder) ?? ""
    }

    // MARK: - Kolo souborů

    func key(for wheel: Wheel) -> WheelKey {
        switch wheel {
        case .convert: convertKey
        case .tools: toolsKey
        case .actions: actionsKey
        }
    }

    /// Nastaví klávesu kola; kolo, které ji mělo dřív, dostane tu uvolněnou (klávesy se nesmí opakovat).
    func setKey(_ key: WheelKey, for wheel: Wheel) {
        let previous = self.key(for: wheel)
        guard previous != key else { return }
        if let other = Wheel.allCases.first(where: { $0 != wheel && self.key(for: $0) == key }) {
            assign(previous, to: other)
        }
        assign(key, to: wheel)
    }

    private func assign(_ key: WheelKey, to wheel: Wheel) {
        switch wheel {
        case .convert: convertKey = key
        case .tools: toolsKey = key
        case .actions: actionsKey = key
        }
    }

    /// Kolo pro modifikátor, nebo `nil`, pokud klávesa žádné kolo neotevírá.
    func wheel(for key: WheelKey) -> Wheel? {
        Wheel.allCases.first { self.key(for: $0) == key }
    }

    var convertOutput: OutputPolicy {
        convertOutputFolder.isEmpty
            ? OutputPolicy(location: .besideSource)
            : OutputPolicy(location: .folder(URL(fileURLWithPath: convertOutputFolder, isDirectory: true)))
    }
}
