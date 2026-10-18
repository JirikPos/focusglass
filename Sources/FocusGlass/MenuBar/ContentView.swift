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
            .animation(.linear(duration: 0.9), value: timer.progress)

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

            EyeCard()
            StayAwakeCard()
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
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Péče o oči")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.eyeCare.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            Button("Pauza teď", action: model.startEyeBreak)
                .buttonStyle(GlassPillButtonStyle(size: 11))
                .help("Spustí minutové cvičení očí (běžící časovač se mezitím zastaví)")
        }
        .padding(10)
        .glassPanel(radius: 18)
    }
}

private struct StayAwakeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let awake = model.stayAwake
        HStack(spacing: 12) {
            Image(systemName: awake.isOn ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(awake.isOn ? 1 : 0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(awake.isOn ? 0.16 : 0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nespat při zavřeném víku")
                    .font(.system(size: 12, weight: .semibold))
                Text(awake.isOn ? "Zapnuto – Mac nezaspí" : "Vypnuto")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { awake.isOn }, set: { awake.set($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color(white: 0.55))
                .labelsHidden()
                .disabled(awake.isBusy)
                .help("Agenti poběží dál i po zavření víka. Vypne se při ukončení aplikace a při baterii pod 20 %.")
        }
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
