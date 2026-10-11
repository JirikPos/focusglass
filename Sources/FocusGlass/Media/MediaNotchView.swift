import SwiftUI

/// Panel „Hudba“ v rozbaleném notchi.
struct MediaNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let media = model.media
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.player == nil ? "Nic nehraje" : media.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(media.player.map { "\(media.artist) · \($0.rawValue)" } ?? "Apple Music nebo Spotify")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if media.player != nil {
                    HStack(spacing: 6) {
                        Button(action: media.previous) { Image(systemName: "backward.fill") }
                            .buttonStyle(GlassIconButtonStyle(size: 24))
                        Button(action: media.togglePlay) {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(PrimaryButtonStyle(size: 30))
                        Button(action: media.next) { Image(systemName: "forward.fill") }
                            .buttonStyle(GlassIconButtonStyle(size: 24))
                    }
                }
            }
            MusicVisualizer(spectrum: model.spectrum)
                .frame(height: 24)
        }
    }
}

/// Zrcadlený vizualizér skutečně hrajícího zvuku: uprostřed basy, ke krajům výšky.
/// Analýza (Core Audio tap + FFT) běží jen po dobu zobrazení panelu.
private struct MusicVisualizer: View {
    let spectrum: AudioSpectrum

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let levels = spectrum.levels()
            let beat = Double(spectrum.beat())
            Canvas { canvas, size in
                let bands = levels.count
                let bars = bands * 2
                let gap: CGFloat = 2.5
                let width = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)

                for index in 0..<bars {
                    // Zrcadlení: od středu ke krajům basy → výšky.
                    let distance = index < bands ? bands - 1 - index : index - bands
                    let level = CGFloat(levels[distance])
                    let height = max(2, size.height * level)
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2,
                                      width: width, height: height)
                    // Na úder se sloupce rozzáří.
                    let brightness = min(1, 0.22 + 0.68 * Double(level) + 0.12 * beat)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                                with: .color(.white.opacity(brightness)))
                }
            }
            // Jemné „bliknutí“ celé vlny na úder.
            .shadow(color: .white.opacity(0.15 * beat), radius: 4)
            .scaleEffect(x: 1, y: 1 + 0.04 * beat)
        }
        .mask(
            LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing)
        )
        .onAppear { spectrum.setActive(true) }
        .onDisappear { spectrum.setActive(false) }
    }
}
