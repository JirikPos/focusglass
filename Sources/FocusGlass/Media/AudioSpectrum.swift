import Foundation

/// Spektrum skutečně přehrávaného zvuku pro vizualizér.
/// Běží jen, když je otevřený panel Hudba – jinak je tap zrušený a nic nestojí.
@MainActor
final class AudioSpectrum {
    private let analyzer = SpectrumAnalyzer()
    /// `SystemAudioTap` (macOS 14.2+); uložený jako `Any`, aby šla aplikace spustit i na 14.0.
    private var tap: Any?
    private var activeViews = 0

    /// Zvuk lze analyzovat (macOS 14.2+).
    var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func levels() -> [Float] { analyzer.levels() }
    func beat() -> Float { analyzer.beat() }

    /// Volá view při zobrazení / skrytí (počítá se, kolik view analýzu potřebuje).
    func setActive(_ active: Bool) {
        guard #available(macOS 14.2, *) else { return }
        activeViews = max(0, activeViews + (active ? 1 : -1))
        let tap = (self.tap as? SystemAudioTap) ?? SystemAudioTap(analyzer: analyzer)
        self.tap = tap
        if activeViews > 0 { tap.start() } else { tap.stop() }
    }
}
