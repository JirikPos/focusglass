import SwiftUI

/// Úkoly v blocích a napojení ClickUpu (pracovní úkoly + zápis času).
struct ClickUpSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var connecting = false

    var body: some View {
        @Bindable var settings = model.settings
        let clickUp = model.clickUp

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18)
                Text("Úkoly v blocích")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle("", isOn: $settings.askTasks)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(white: 0.55))
                    .labelsHidden()
            }
            .padding(.top, 9)

            Text("Na začátku bloku se notch zeptá, na čem budeš pracovat (víc úkolů, z ClickUpu i vlastní). Na konci: „Splnil jsi to?“")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)

            HStack {
                Text("ClickUp")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if clickUp.hasToken {
                    Button("Odpojit", action: clickUp.disconnect)
                        .buttonStyle(GlassPillButtonStyle(size: 10))
                }
            }

            if !clickUp.hasToken {
                SecureField("Osobní token (pk_…)", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
                Button(connecting ? "Připojuji…" : "Připojit") {
                    connecting = true
                    Task {
                        await clickUp.connect(token: token)
                        token = ""
                        connecting = false
                    }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(token.isEmpty || connecting)
                Text("ClickUp → avatar → Settings → Apps → API Token → Generate / Copy. Bez ClickUpu fungují vlastní úkoly (nikam se neukládají).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if clickUp.teams.count > 1 {
                    Picker("Workspace", selection: $settings.clickUpTeamID) {
                        ForEach(clickUp.teams) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                Text(statusText(clickUp))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .glassPanel()
        .task {
            if clickUp.hasToken && clickUp.teams.isEmpty { await clickUp.loadTeams() }
        }
    }

    private func statusText(_ clickUp: ClickUpService) -> String {
        switch clickUp.status {
        case .failed(let message): return message
        case .loading: return "Načítám…"
        case .notConnected: return "Nepřipojeno"
        case .ready:
            return "Připojeno · \(clickUp.tasks.count) otevřených úkolů. Čistý čas se zapíše k úkolu, „Ano“ na konci bloku ho uzavře."
        }
    }
}
