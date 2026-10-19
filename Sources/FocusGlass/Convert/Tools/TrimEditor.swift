import AVKit
import ConvertKit
import SwiftUI

/// Přehrávač a časová osa se dvěma úchyty: vybraný úsek se přehrává ve smyčce.
struct TrimEditor: View {
    let model: ToolSheetModel
    var state: TrimState { model.trim! }

    var body: some View {
        VStack(spacing: 0) {
            player
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(.white.opacity(0.08))
            VStack(spacing: 10) {
                Timeline(state: state)
                    .frame(height: 76)
                controls
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.black.opacity(0.35))
        }
        .onDisappear { state.pause() }
    }

    @ViewBuilder
    private var player: some View {
        ZStack {
            Checkerboard()
            if state.canPlay, state.isVideo {
                ZStack {
                    // Záloha, než přehrávač vykreslí první snímek.
                    if let frame = model.original {
                        Image(nsImage: NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
                            .resizable().aspectRatio(contentMode: .fit)
                    }
                    PlayerSurface(player: state.player)
                }
                .padding(18)
            } else if !state.isVideo, let wave = model.result ?? model.original {
                Image(nsImage: NSImage(cgImage: wave, size: NSSize(width: wave.width, height: wave.height)))
                    .resizable().aspectRatio(contentMode: .fit).padding(30)
            } else if let frame = model.original {
                VStack(spacing: 10) {
                    Image(nsImage: NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
                        .resizable().aspectRatio(contentMode: .fit)
                    if !state.canPlay, !state.isLoading {
                        Text("Tenhle formát nejde v náhledu přehrát – střih nastav na časové ose nebo čísly vpravo.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(18)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { state.togglePlay() } label: { Image(systemName: state.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(GlassIconButtonStyle(size: 28)).disabled(!state.canPlay)
                .keyboardShortcut(.space, modifiers: [])
                .help("Přehrát / pozastavit (mezerník)")
            Button("Začátek sem") { state.setStartHere() }
                .buttonStyle(GlassPillButtonStyle()).keyboardShortcut("i", modifiers: [])
                .help("Nastavit začátek na aktuální pozici (I)")
            Button("Konec sem") { state.setEndHere() }
                .buttonStyle(GlassPillButtonStyle()).keyboardShortcut("o", modifiers: [])
                .help("Nastavit konec na aktuální pozici (O)")
            Toggle("Smyčka", isOn: Binding(get: { state.loop }, set: { state.loop = $0 }))
                .toggleStyle(.switch).controlSize(.mini).tint(Color(white: 0.55)).font(.system(size: 11.5))
            Spacer()
            Text("\(formatTimecode(state.start)) – \(formatTimecode(state.end))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Text("(\(formatTimecode(state.length)))")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Přehrávací plocha bez ovládacích prvků.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Časová osa: miniatury nebo vlna, vybraný úsek, úchyty a přehrávací značka.
private struct Timeline: View {
    let state: TrimState

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(state.duration, 0.001)
            let x = { (time: Double) -> CGFloat in CGFloat(time / duration) * width }
            ZStack(alignment: .leading) {
                background(width: width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                // Ztlumení mimo vybraný úsek.
                Rectangle().fill(.black.opacity(0.6)).frame(width: x(state.start))
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(width - x(state.end), 0)).offset(x: x(state.end))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white, lineWidth: 2)
                    .frame(width: max(x(state.end) - x(state.start), 2)).offset(x: x(state.start))
                    .allowsHitTesting(false)
                // Přehrávací značka.
                Rectangle().fill(.yellow).frame(width: 2).offset(x: x(state.playhead) - 1)
                    .allowsHitTesting(false)
                handle(at: x(state.start), isStart: true, width: width, duration: duration)
                handle(at: x(state.end), isStart: false, width: width, duration: duration)
            }
            .contentShape(Rectangle())
            // Klik a tažení mimo úchyty posouvá přehrávací značku.
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                state.seek(to: Double(min(max(value.location.x, 0), width) / width) * duration)
            })
        }
    }

    @ViewBuilder
    private func background(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(white: 0.13))
            if state.isVideo {
                HStack(spacing: 0) {
                    ForEach(Array(state.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(max(state.thumbnails.count, 1)), height: height).clipped()
                    }
                }
            } else {
                Canvas { context, size in
                    let peaks = state.waveform
                    guard !peaks.isEmpty else { return }
                    let maximum = max(peaks.max() ?? 1, 0.001)
                    let step = size.width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let level = CGFloat(pow(peak / maximum, 0.7)) * size.height * 0.9
                        let rect = CGRect(x: CGFloat(index) * step, y: (size.height - max(level, 1.5)) / 2, width: max(step - 0.4, 0.6), height: max(level, 1.5))
                        context.fill(Path(rect), with: .color(.white.opacity(0.75)))
                    }
                }
            }
            if state.isLoading { ProgressView().controlSize(.small) }
        }
    }

    private func handle(at position: CGFloat, isStart: Bool, width: CGFloat, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: 10, height: 84)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 2, height: 22))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .position(x: position, y: 38)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // Poloha úchytu při začátku tahu + posun prstu.
                let t = Double(min(max(position + value.translation.width, 0), width) / width) * duration
                if isStart { state.start = min(max(t, 0), state.end - 0.1) } else { state.end = max(min(t, duration), state.start + 0.1) }
                state.seek(to: isStart ? state.start : state.end)
            })
            .help(isStart ? "Začátek" : "Konec")
    }
}

/// Políčka Od / Do v postranním panelu.
struct TrimFields: View {
    let model: ToolSheetModel

    var body: some View {
        if let state = model.trim {
            VStack(alignment: .leading, spacing: 8) {
                Text("Úsek").font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 10) {
                    field("Od", value: state.start) { state.start = min(max($0, 0), max(state.end - 0.1, 0)) }
                    field("Do", value: state.end) { state.end = min(max($0, state.start + 0.1), max(state.duration, state.start + 0.1)) }
                }
                Text("Čas ve tvaru 1:05.3 nebo 65,3.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func field(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            TextField("", text: Binding(get: { formatTimecode(value) }, set: { if let time = parseTimecode($0) { set(time) } }))
                .textFieldStyle(.roundedBorder).controlSize(.small).monospacedDigit()
        }
    }
}
