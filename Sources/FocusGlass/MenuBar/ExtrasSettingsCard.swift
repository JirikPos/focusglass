import SwiftUI

/// Screenshoty, stahování, schůzky, baterie a žrouti výkonu.
struct ExtrasSettingsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        VStack(alignment: .leading, spacing: 0) {
            row("camera.viewfinder", "Screenshoty do odkladiště", $settings.screenshotsToShelf)
            row("arrow.down.circle", "Stažené soubory do odkladiště", $settings.downloadsToShelf)
            row("video", "Připojit ke schůzce (2 min předem)", $settings.meetingAlerts)
            row("battery.75percent", "Nabíjení a slabá baterie", $settings.batteryAlerts)
            row("memorychip", "Žrouti výkonu (3 GB / 100 % CPU)", $settings.hogAlerts)
            Text("Schůzky potřebují zapnutý kalendář.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .glassPanel()
    }

    private func row(_ icon: String, _ title: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: Binding(get: { binding.wrappedValue }, set: {
                binding.wrappedValue = $0
                model.applyExtras()
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Color(white: 0.55))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}
