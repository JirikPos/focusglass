import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchMessage: String?

    var body: some View {
        @Bindable var settings = model.settings

        VStack(spacing: 12) {
            VStack(spacing: 0) {
                SettingRow(icon: "power", title: "Spustit po přihlášení") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                }
                if let launchMessage {
                    HStack {
                        Text(launchMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Button("Otevřít", action: LaunchAtLogin.openSystemSettings)
                            .buttonStyle(GlassPillButtonStyle(size: 11))
                    }
                    .padding(.bottom, 8)
                }
                Hairline()
                SettingRow(icon: "rectangle.topthird.inset.filled", title: "Notch") {
                    Toggle("", isOn: Binding(get: { settings.notchEnabled }, set: model.setNotchEnabled))
                }
                Hairline()
                SettingRow(icon: "menubar.rectangle", title: "Čas v liště") {
                    Toggle("", isOn: $settings.showTimeInMenuBar)
                }
                Hairline()
                SettingRow(icon: "speaker.wave.2", title: "Zvuky") {
                    Toggle("", isOn: $settings.soundsEnabled)
                }
                Hairline()
                SettingRow(icon: "arrow.triangle.2.circlepath", title: "Po pauze pokračovat") {
                    Toggle("", isOn: $settings.autoContinue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "eye", title: "Péče o oči 20-20-1") {
                    Toggle("", isOn: Binding(get: { settings.eyeCareEnabled }, set: model.setEyeCareEnabled))
                }
                Caption("Každých 20 minut u obrazovky ztmavne displej na 1 minutu cvičení očí – i bez pomodora, třeba u filmu. Uspání, zhasnutí displeje nebo odchod od počítače počítadlo vynuluje.")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "figure.walk", title: "Detekce odchodu") {
                    Toggle("", isOn: $settings.awayDetection)
                }
                Picker("Po", selection: $settings.awayMinutes) {
                    ForEach(AppSettings.awayOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!settings.awayDetection)
                .padding(.bottom, 8)
                Caption("Když se \(settings.awayMinutes) min nedotkneš myši ani klávesnice, časovač se zastaví a čas mimo počítač se nezapočítá. Po návratu pokračuje sám.")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "sparkles", title: "Nabízet spuštění focusu") {
                    Toggle("", isOn: $settings.suggestFocus)
                }
                ListField(title: "Pracovní aplikace", text: $settings.workApps)
                Caption("Když v některé z těchto aplikací 3 minuty aktivně pracuješ a focus neběží, notch se zeptá, jestli ho spustit. „Teď ne“ = klid na hodinu.")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "hand.raised", title: "Hlídač rozptýlení") {
                    Toggle("", isOn: Binding(get: { settings.distractionGuard }, set: model.setDistractionGuard))
                }
                ListField(title: "Blokovat · weby", text: $settings.blockedSites)
                ListField(title: "Blokovat · aplikace", text: $settings.blockedApps)
                SettingRow(icon: "text.cursor", title: "Zeptat se na důvod") {
                    Toggle("", isOn: $settings.askReason)
                }
                if settings.askReason {
                    Picker("Pustit na", selection: $settings.allowMinutes) {
                        ForEach(AppSettings.allowOptions, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.bottom, 8)
                }
                ListField(title: "Jen upozornit · weby", text: $settings.distractingSites)
                ListField(title: "Jen upozornit · aplikace", text: $settings.distractingApps)
                    .padding(.bottom, 8)
                Caption("Během focusu se blokované weby přesměrují na stránku „Blocked“ a blokované aplikace se schovají. Se „Zeptat se na důvod“ tě notch pustí dovnitř, až napíšeš proč (min. 15 znaků) – důvody se zapisují do deníku výjimek. U „jen upozornit“ tě notch seřve a čas se započítá jako ztracený. Web může mít i cestu, např. youtube.com/shorts. Prohlížeče: Safari, Chrome, Arc, Brave, Edge (macOS se jednou zeptá na svolení).")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "target", title: "Denní cíl") {
                    HStack(spacing: 8) {
                        Button { settings.dailyGoalHours = max(1, settings.dailyGoalHours - 1) } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(GlassIconButtonStyle(size: 22))
                        Text("\(settings.dailyGoalHours) h")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 30)
                        Button { settings.dailyGoalHours = min(12, settings.dailyGoalHours + 1) } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(GlassIconButtonStyle(size: 22))
                    }
                }
                Caption("Kolik hodin čisté práce denně chceš odmakat. Podle toho se počítá dnešní progres, série dní a hodnocení ve statistikách.")
                    .padding(.bottom, 6)
                Hairline()
                SettingRow(icon: "moon", title: "Nerušit během focusu") {
                    Toggle("", isOn: Binding(get: { settings.autoDND }, set: model.setAutoDND))
                }
                Caption("Vytvoř v aplikaci Zkratky dvě zkratky s akcí Nastavit režim soustředění: „\(DoNotDisturb.onShortcut)“ (zapnout) a „\(DoNotDisturb.offShortcut)“ (vypnout). Se „Sdílet mezi zařízeními“ se režim zapne i na iPhonu – a tam může spustit šedou obrazovku (viz README).")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: "calendar", title: "Schůzky z kalendáře") {
                    Toggle("", isOn: Binding(get: { settings.calendarEnabled }, set: model.setCalendarEnabled))
                }
                if settings.calendarEnabled {
                    CalendarStatus()
                }
                Hairline()
                SettingRow(icon: "doc.on.clipboard", title: "Historie schránky") {
                    Toggle("", isOn: Binding(get: { settings.clipboardEnabled }, set: model.setClipboardEnabled))
                }
                Hairline()
                SettingRow(icon: "tray.and.arrow.up", title: "Po vytažení odebrat") {
                    Toggle("", isOn: $settings.shelfRemoveAfterDrag)
                }
                Caption("Zkratky: ⌃⌥ mezerník otevře notch · ⌃⌥ ↩ start/pauza · ⌃⌥ V schránka · ⌃⌥ K kolo souborů. V otevřeném notchi Esc zavře, mezerník v odkladišti ukáže náhled.")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .glassPanel()

            ConvertSettingsCard()

            ExtrasSettingsCard()

            ClickUpSettingsCard()

            NotionSettingsCard()

            AboutCard()
        }
        .onAppear(perform: refreshLaunchState)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchMessage = nil
        } catch {
            launchMessage = "Nelze změnit: \(error.localizedDescription)"
        }
        refreshLaunchState()
    }

    private func refreshLaunchState() {
        launchAtLogin = LaunchAtLogin.isEnabled
        if LaunchAtLogin.status == .requiresApproval {
            launchMessage = "Povol v Přihlašovacích položkách."
        }
    }
}

private struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            control
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color(white: 0.55))
                .labelsHidden()
        }
        .padding(.vertical, 9)
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Stav přístupu ke Kalendáři a nejbližší schůzka – ať je hned vidět, jestli to funguje.
private struct CalendarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = model.calendar
        HStack {
            Text(text(calendar))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
            Spacer()
            if calendar.status == .denied || calendar.status == .restricted || calendar.status == .writeOnly {
                Button("Otevřít", action: calendar.openPrivacySettings)
                    .buttonStyle(GlassPillButtonStyle(size: 11))
            }
        }
        .padding(.bottom, 8)
        .onAppear { calendar.refresh() }
    }

    private func text(_ calendar: CalendarService) -> String {
        switch calendar.status {
        case .fullAccess:
            guard let next = calendar.next else { return "Přístup povolen · dnes už žádná schůzka" }
            return "Další: \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)"
        case .notDetermined:
            return "Čeká na svolení…"
        default:
            return "Přístup ke Kalendáři je zamítnutý. Povol FocusGlass v Soukromí → Kalendáře."
        }
    }
}

/// Autor a licence. Podle licence se nesmí odstranit.
private struct AboutCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text("FocusGlass \(Author.version) · \(Author.name)")
                    .font(.system(size: 12, weight: .medium))
                Text(Author.license)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button("LinkedIn", action: Author.openProfile)
                .buttonStyle(GlassPillButtonStyle(size: 11))
        }
        .padding(12)
        .glassPanel()
    }
}

private struct ListField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.4))
            TextField(title, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...3)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        }
        .padding(.bottom, 6)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 28)
    }
}
