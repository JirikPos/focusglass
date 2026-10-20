import SwiftUI

/// Obsah okna z lišty.
struct ContentView: View {
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            header
            if showSettings {
                ScrollView(showsIndicators: false) {
                    SettingsView()
                }
                .frame(height: 540)
                    .transition(.opacity.combined(with: .offset(x: 16)))
            } else {
                TimerPanel()
                    .transition(.opacity.combined(with: .offset(x: -16)))
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color.black.opacity(0.5))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.35), value: showSettings)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "laptopcomputer")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14, weight: .regular))
            Text(showSettings ? "Nastavení" : "FocusGlass")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(GlassIconButtonStyle(size: 26))
            .help(showSettings ? "Zpět" : "Nastavení")
        }
    }
}

// MARK: - Časovač

private struct TimerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        VStack(spacing: 18) {
            ProfilePicker()

            ZStack {
                ProgressRing(progress: timer.progress)
                VStack(spacing: 6) {
                    Text(timer.statusTitle.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(timer.remaining.clock)
                        .font(.system(size: 54, weight: .ultraLight))
                        .monospacedDigit()
                    Text("z \(Int(timer.duration / 60)) min")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 180, height: 180)

            HStack(spacing: 28) {
                Button(action: timer.reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Reset")

                Button(action: timer.toggle) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .help(timer.isRunning ? "Pozastavit" : "Spustit")

                Button(action: timer.skip) {
                    Image(systemName: "forward.end")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help(timer.phase == .work ? "Přeskočit na pauzu" : "Přeskočit pauzu")
            }

            HStack(alignment: .top, spacing: 10) {
                EyeCard()
                StayAwakeCard()
            }
            SystemCard()
            StatsCard()
            QuoteView()

            HStack {
                Button("by \(Author.name)", action: Author.openProfile)
                    .buttonStyle(.plain)
                    .help("Profil autora")
                Spacer()
                Button("Ukončit FocusGlass") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.3))
        }
    }

}

private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FocusProfile.all) { profile in
                let selected = profile == model.timer.profile
                Button {
                    model.selectProfile(profile)
                } label: {
                    Text(profile.label)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.white.opacity(0.13))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.75))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(Int(profile.work / 60)) min práce, \(Int(profile.rest / 60)) min pauza")
            }
        }
        .padding(3)
        .glassPanel(radius: 20)
        .animation(.smooth(duration: 0.3), value: model.timer.profile)
    }
}

private struct EyeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TileIcon(symbol: "eye", active: false)
                Spacer(minLength: 0)
                Button("Pauza", action: model.startEyeBreak)
                    .buttonStyle(GlassPillButtonStyle(size: 11))
                    .help("Spustí minutové cvičení očí (běžící časovač se mezitím zastaví)")
            }
            TileText(title: "Péče o oči", status: model.eyeCare.status)
        }
        .tile()
    }
}

private struct StayAwakeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let awake = model.stayAwake
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TileIcon(symbol: awake.isOn ? "moon.zzz.fill" : "moon.zzz", active: awake.isOn)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { awake.isOn }, set: { awake.set($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(white: 0.55))
                    .labelsHidden()
                    .disabled(awake.isBusy)
                    .help("Agenti poběží dál i po zavření víka. Vypne se při ukončení aplikace a při baterii pod 20 %.")
            }
            TileText(title: "Nespat při zavřeném víku", status: awake.isOn ? "Zapnuto – Mac nezaspí" : "Vypnuto")
        }
        .tile()
    }
}

private struct TileIcon: View {
    let symbol: String
    let active: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(active ? 1 : 0.7))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(active ? 0.16 : 0.06)))
    }
}

private struct TileText: View {
    let title: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2, reservesSpace: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// Dlaždice ve dvousloupcové mřížce: stejná šířka, sklo.
    func tile() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassPanel(radius: 18)
    }
}

private struct QuoteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: model.shuffleQuote) {
            VStack(spacing: 5) {
                Text("“\(model.quote.text)”")
                    .font(.system(size: 12, weight: .light))
                    .italic()
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.quote.author.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Klikni pro další citát")
    }
}

// MARK: - Systém

/// Zátěž CPU po jádrech, paměť, síť a tepelný stav. Měří se jen, dokud je okno otevřené.
private struct SystemCard: View {
    @State private var stats = SystemStats()
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Systém")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(thermalText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(alignment: .top, spacing: 14) {
                stat("Procesor", value: percent(stats.cpu), bar: stats.cpu)
                stat("Paměť", value: String(format: "%.1f GB", stats.memoryUsed / 1_073_741_824),
                     bar: stats.memoryFraction)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Síť").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    Text("↓ \(rate(stats.download))")
                    Text("↑ \(rate(stats.upload))")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            coreBars
        }
        .padding(10)
        .glassPanel(radius: 18)
        .background(WindowReader(window: $window))
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            if window.occlusionState.contains(.visible) { stats.start() } else { stats.stop() }
        }
    }

    private var thermalText: String {
        switch stats.thermal {
        case .nominal: "Chlad v pořádku"
        case .fair: "Mírně zahřátý"
        case .serious: "Horký"
        case .critical: "Přehřátý"
        @unknown default: "Chlad v pořádku"
        }
    }

    private func stat(_ title: String, value: String, bar: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(.white.opacity(0.75))
                        .frame(width: max(3, proxy.size.width * min(1, max(0, bar))))
                }
            }
            .frame(height: 3)
            .animation(.smooth(duration: 0.6), value: bar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coreBars: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(stats.cores.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(.white.opacity(0.55))
                        .frame(height: max(2, 22 * load))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            }
        }
        .animation(.smooth(duration: 0.6), value: stats.cores)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }

    private func rate(_ bytes: Double) -> String {
        switch bytes {
        case 1_000_000...: String(format: "%.1f MB/s", bytes / 1e6)
        case 1_000...: String(format: "%.0f kB/s", bytes / 1e3)
        default: "0 kB/s"
        }
    }
}

/// Zjistí okno, ve kterém karta leží (kvůli otevření/zavření okna z lišty).
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if window !== view.window { window = view.window } }
    }
}
