import AppKit
import Observation

/// Propojuje časovač, nastavení a overlay. Žije po celou dobu běhu aplikace.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let timer: FocusTimer
    let media = NowPlaying()
    let shelf = ShelfStore()
    private(set) var quote = Quotes.random()

    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private var notch: NotchController!

    init() {
        // Celá aplikace je v matně černém stylu bez ohledu na systémový vzhled.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        let settings = AppSettings()
        self.settings = settings
        self.timer = FocusTimer(settings: settings)

        timer.onEyeBreak = { [weak self] in self?.startEyeBreak() }
        timer.onPhaseChange = { [weak self] ended, manual in
            self?.phaseChanged(ended: ended, manual: manual)
        }

        notch = NotchController(model: self)
        // Okna až po dokončení startu aplikace.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notch.setEnabled(self.settings.notchEnabled)
            if CommandLine.arguments.contains("--notch-open") {
                self.notch.expandForPreview()
            }
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

    func shuffleQuote() {
        quote = Quotes.random(excluding: quote)
    }

    /// Minuta pro oči: pozastaví pomodoro, ukáže cvičení a pak časovač zase rozběhne.
    func startEyeBreak() {
        let resumeAfter = timer.isRunning
        timer.pause()
        playSound("Tink")

        overlay.present(
            mode: .eyes,
            quote: Quotes.random(),
            until: Date().addingTimeInterval(FocusTimer.eyeBreakDuration),
            onFinish: { [weak self] finished in
                guard let self else { return }
                if finished { self.playSound("Pop") }
                self.timer.eyesRested()
                if resumeAfter { self.timer.start() }
            }
        )
    }

    private func phaseChanged(ended: Phase, manual: Bool) {
        overlay.dismiss()
        guard !manual else { return }
        playSound("Glass")

        if ended == .work, let end = timer.endDate {
            overlay.present(
                mode: .rest,
                quote: Quotes.random(),
                until: end,
                onSkip: { [weak self] in self?.timer.skip() }
            )
        }
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
