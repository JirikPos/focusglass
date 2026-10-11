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
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var profileID: String { didSet { defaults.set(profileID, forKey: Key.profile) } }
    var eyeCareEnabled: Bool { didSet { defaults.set(eyeCareEnabled, forKey: Key.eyeCare) } }
    var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: Key.autoContinue) } }
    var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.sounds) } }
    var showTimeInMenuBar: Bool { didSet { defaults.set(showTimeInMenuBar, forKey: Key.timeInMenuBar) } }
    var awayDetection: Bool { didSet { defaults.set(awayDetection, forKey: Key.awayDetection) } }
    var awayMinutes: Int { didSet { defaults.set(awayMinutes, forKey: Key.awayMinutes) } }

    init() {
        defaults.register(defaults: [
            Key.profile: FocusProfile.default.id,
            Key.eyeCare: true,
            Key.autoContinue: false,
            Key.sounds: true,
            Key.timeInMenuBar: true,
            Key.awayDetection: true,
            Key.awayMinutes: 2,
        ])
        profileID = defaults.string(forKey: Key.profile) ?? FocusProfile.default.id
        eyeCareEnabled = defaults.bool(forKey: Key.eyeCare)
        autoContinue = defaults.bool(forKey: Key.autoContinue)
        soundsEnabled = defaults.bool(forKey: Key.sounds)
        showTimeInMenuBar = defaults.bool(forKey: Key.timeInMenuBar)
        awayDetection = defaults.bool(forKey: Key.awayDetection)
        awayMinutes = defaults.integer(forKey: Key.awayMinutes)
    }
}
