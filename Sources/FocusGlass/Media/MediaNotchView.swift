import SwiftUI

/// Panel „Hudba“ v rozbaleném notchi.
struct MediaNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let media = model.media
        if let player = media.player {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    )
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(media.artist) · \(player.rawValue)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button(action: media.previous) { Image(systemName: "backward.fill") }
                        .buttonStyle(GlassIconButtonStyle(size: 24))
                    Button(action: media.togglePlay) {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PrimaryButtonStyle(size: 32))
                    Button(action: media.next) { Image(systemName: "forward.fill") }
                        .buttonStyle(GlassIconButtonStyle(size: 24))
                }
            }
        } else {
            EmptyNotchState(
                symbol: "music.note",
                title: "Nic nehraje",
                detail: "Apple Music nebo Spotify"
            )
        }
    }
}
