import SwiftUI

/// Napojení Notionu (osobní návyky) a večerní review.
struct NotionSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var connecting = false

    var body: some View {
        @Bindable var settings = model.settings
        let habits = model.habits

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18)
                Text("Notion · návyky")
                    .font(.system(size: 12.5))
                Spacer()
                if habits.hasToken {
                    Button("Odpojit", action: habits.disconnect)
                        .buttonStyle(GlassPillButtonStyle(size: 10))
                }
            }
            .padding(.top, 9)

            if !habits.hasToken {
                SecureField("Klíč integrace (ntn_…)", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
                Button(connecting ? "Připojuji…" : "Připojit") {
                    connecting = true
                    Task {
                        await habits.connect(token: token)
                        token = ""
                        connecting = false
                    }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(token.isEmpty || connecting)
                Text("notion.so/profile/integrations → New integration → zkopíruj klíč. V záložce Access vyber stránky nejvyšší úrovně (celý workspace) nebo jen databázi návyků.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Databáze", selection: Binding(
                    get: { settings.notionDatabaseID },
                    set: { id in Task { await habits.selectDatabase(id); model.scheduleEveningReview() } }
                )) {
                    Text("Vyber databázi…").tag("")
                    // Jen databáze s datem a checkboxy (s celým workspace jich je jinak desítky).
                    ForEach(habits.suitableDatabases) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)

                Text(statusText(habits))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Toggle("Večerní review", isOn: Binding(
                        get: { settings.eveningReview },
                        set: { settings.eveningReview = $0; model.scheduleEveningReview() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(white: 0.55))
                    .font(.system(size: 12))
                    Spacer()
                    Button { changeHour(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(GlassIconButtonStyle(size: 20))
                    Text("\(settings.reviewHour):00")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Button { changeHour(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(GlassIconButtonStyle(size: 20))
                }
                .disabled(settings.notionDatabaseID.isEmpty)

                HStack(spacing: 8) {
                    Toggle("Vynutit (celá obrazovka)", isOn: $settings.forceReview)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Color(white: 0.55))
                        .font(.system(size: 12))
                    Spacer()
                    Button("Spustit teď") { model.presentForcedReview() }
                        .help("Skutečné dnešní review – zapíše se do Notionu")
                        .buttonStyle(GlassPillButtonStyle(size: 10))
                }
                .disabled(settings.notionDatabaseID.isEmpty || !settings.eveningReview)
                Text("Review přes všechny obrazovky. Musíš rozhodnout u každého návyku Ano/Ne a uložit – Esc ani ⌘Q nefungují. Nouzový únik: podrž Esc 5 s (zapíše se jako selhání).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .glassPanel()
        .task {
            if habits.hasToken && habits.databases.isEmpty { await habits.loadDatabases() }
        }
    }

    private func changeHour(_ delta: Int) {
        model.settings.reviewHour = min(23, max(12, model.settings.reviewHour + delta))
        model.scheduleEveningReview()
    }

    private func statusText(_ habits: HabitsService) -> String {
        switch habits.status {
        case .failed(let message): return message
        case .loading: return "Načítám…"
        case .notConnected: return "Vyber databázi, kde řádek = den a návyky jsou checkboxy."
        case .ready: return "Dnes \(habits.doneCount)/\(habits.habits.count) návyků · panel Návyky v notchi"
        }
    }
}
