import AppKit
import Observation

/// Co právě hraje v Apple Music nebo Spotify.
///
/// Čte se z distribuovaných notifikací, které obě aplikace samy posílají při každé změně –
/// žádné dotazování, nulová zátěž. Ovládání jde přes AppleScript (macOS se jednou zeptá na svolení).
@MainActor
@Observable
final class NowPlaying {
    enum Player: String {
        case music = "Music"
        case spotify = "Spotify"

        var notification: Notification.Name {
            switch self {
            case .music: Notification.Name("com.apple.Music.playerInfo")
            case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
            }
        }
    }

    private(set) var player: Player?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false

    init() {
        let center = DistributedNotificationCenter.default()
        for player in [Player.music, .spotify] {
            center.addObserver(forName: player.notification, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let state = info["Player State"] as? String ?? ""
                let title = info["Name"] as? String ?? ""
                let artist = info["Artist"] as? String ?? ""
                MainActor.assumeIsolated {
                    self?.update(player: player, state: state, title: title, artist: artist)
                }
            }
        }
    }

    func togglePlay() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func update(player: Player, state: String, title: String, artist: String) {
        if state == "Stopped" {
            if self.player == player { clear() }
            return
        }
        // Když hrají obě aplikace, vyhrává ta, která naposledy začala hrát.
        if state != "Playing" && self.player != nil && self.player != player { return }
        self.player = player
        self.isPlaying = state == "Playing"
        if !title.isEmpty { self.title = title }
        self.artist = artist
    }

    private func clear() {
        player = nil
        title = ""
        artist = ""
        isPlaying = false
    }

    private func send(_ command: String) {
        guard let player else { return }
        // Okamžitá odezva v UI; skutečný stav dorazí notifikací.
        if command == "playpause" { isPlaying.toggle() }
        let source = "tell application \"\(player.rawValue)\" to \(command)"
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
