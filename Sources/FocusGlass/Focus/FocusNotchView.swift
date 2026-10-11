import SwiftUI

/// Panel „Focus“ v rozbaleném notchi.
struct FocusNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(progress: timer.progress, lineWidth: 1.5)
                Image(systemName: timer.stateSymbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 34, height: 34)
            .animation(.linear(duration: 0.9), value: timer.progress)

            VStack(alignment: .leading, spacing: 0) {
                Text(timer.remaining.clock)
                    .font(.system(size: 24, weight: .ultraLight))
                    .monospacedDigit()
                Text(timer.eyeStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(action: model.startEyeBreak) { Image(systemName: "eye") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Pauza pro oči teď")
                Button(action: timer.reset) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Reset")
                Button(action: timer.toggle) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PrimaryButtonStyle(size: 32))
                Button(action: timer.skip) { Image(systemName: "forward.end") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Přeskočit")
            }
        }
    }
}
