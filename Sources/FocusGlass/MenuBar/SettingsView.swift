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
                    Toggle("", isOn: $settings.eyeCareEnabled)
                }
                Caption("Každých 20 minut práce ztmavne obrazovka na 1 minutu cvičení očí. Časovač se mezitím zastaví.")
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

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 28)
    }
}
