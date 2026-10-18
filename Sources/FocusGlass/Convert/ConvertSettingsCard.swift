import AppKit
import ConvertKit
import SwiftUI

/// Nastavení kola souborů: zapnutí, klávesy kol, kam ukládat výsledky, stav volitelných nástrojů.
struct ConvertSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var toolsRefresh = 0

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                icon("circle.circle")
                Text("Kolo souborů").font(.system(size: 12.5))
                Spacer()
                Toggle("", isOn: Binding(get: { settings.convertEnabled }, set: model.setConvertEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color(white: 0.55))
                    .labelsHidden()
            }
            .padding(.vertical, 9)

            if settings.convertEnabled {
                ForEach(Wheel.allCases, id: \.self) { wheel in
                    HStack(spacing: 10) {
                        icon(symbol(for: wheel))
                        Text(wheel.title).font(.system(size: 12.5))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.key(for: wheel) },
                            set: { settings.setKey($0, for: wheel) }
                        )) {
                            ForEach(WheelKey.allCases) { key in
                                Text("\(key.symbol) \(key.title)").tag(key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 118)
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 10) {
                    icon("folder")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Výsledky").font(.system(size: 12.5))
                        Text(settings.convertOutputFolder.isEmpty
                             ? "Vedle originálu"
                             : (settings.convertOutputFolder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if !settings.convertOutputFolder.isEmpty {
                        Button("Vedle") { settings.convertOutputFolder = "" }
                            .buttonStyle(GlassPillButtonStyle())
                            .help("Ukládat vedle původního souboru")
                    }
                    Button("Vybrat…", action: chooseFolder)
                        .buttonStyle(GlassPillButtonStyle())
                }
                .padding(.vertical, 8)

                ToolStatus(tools: model.convert.tools, refresh: toolsRefresh) {
                    model.convert.tools.refresh()
                    toolsRefresh += 1
                }
                .padding(.vertical, 6)

                Text("Začni táhnout soubor a ťukni na klávesu – kolo zůstane otevřené, dokud soubor nepustíš. Na střed nebo Esc = zrušit. ⌃⌥K otevře kolo pro soubory vybrané ve Finderu (šipky, Enter, Tab).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .glassPanel()
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 18)
    }

    private func symbol(for wheel: Wheel) -> String {
        switch wheel {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "slider.horizontal.3"
        case .actions: "bolt"
        }
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Ukládat sem"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.convertOutputFolder = url.path
    }
}

/// Které volitelné nástroje jsou nainstalované (víc formátů videa, WebP, AVIF…).
private struct ToolStatus: View {
    let tools: ToolLocator
    let refresh: Int
    let onRefresh: () -> Void

    private static let shown: [ExternalTool] = [.ffmpeg, .cwebp, .avifenc, .pandoc, .soffice]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Volitelné nástroje")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(GlassIconButtonStyle(size: 18))
                    .help("Znovu vyhledat")
            }
            ForEach(Self.shown, id: \.self) { tool in
                let found = tools.isAvailable(tool)
                HStack(spacing: 6) {
                    Image(systemName: found ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(found ? .green.opacity(0.8) : .white.opacity(0.3))
                    Text(tool.displayName).font(.system(size: 11))
                    Spacer()
                    if !found {
                        Text(tool.installHint)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .id(refresh)
    }
}
