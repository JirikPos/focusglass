import AppKit
import ConvertKit
import SwiftUI

/// Formulář sestavený ze schématu voleb nástroje.
struct OptionsForm: View {
    let model: ToolSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.tool.options) { option in
                if option.isVisible(in: model.values) {
                    OptionRow(option: option, model: model)
                        .transition(.opacity)
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: model.values)
    }
}

private struct OptionRow: View {
    let option: ToolOption
    let model: ToolSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch option.kind {
            case .toggle:
                Toggle(option.title, isOn: Binding(get: { model.bool(option.id) }, set: { model.set(option.id, .bool($0)) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color(white: 0.55))
            case .slider(let range, let step, let unit):
                HStack {
                    Text(option.title)
                    Spacer()
                    Text(format(model.double(option.id), unit: unit, step: step))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
                Slider(value: Binding(get: { model.double(option.id) }, set: { model.set(option.id, .double($0)) }),
                       in: range, step: step)
                    .controlSize(.small)
                    .tint(Color(white: 0.6))
                    .onTapGesture(count: 2) {
                        // Dvojklik vrátí výchozí hodnotu.
                        model.set(option.id, option.defaultValue)
                    }
            case .choice(let choices):
                let picker = Picker("", selection: Binding(get: { model.string(option.id) }, set: { model.set(option.id, .string($0)) })) {
                    ForEach(choices) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                // Dlouhé názvy možností by vytlačily popisek – pak je výběr pod ním přes celou šířku.
                if (choices.map(\.title.count).max() ?? 0) + option.title.count > 34 {
                    Text(option.title)
                    picker.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Text(option.title)
                        Spacer()
                        picker.fixedSize()
                    }
                }
            case .text(let placeholder):
                Text(option.title)
                TextField(placeholder, text: Binding(get: { model.string(option.id) }, set: { model.set(option.id, .string($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            case .secret(let placeholder):
                Text(option.title)
                SecureField(placeholder, text: Binding(get: { model.string(option.id) }, set: { model.set(option.id, .string($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            case .number(let range, let unit):
                HStack {
                    Text(option.title)
                    Spacer()
                    TextField("", value: Binding(get: { model.int(option.id) },
                                                 set: { model.set(option.id, .int(min(max($0, range.lowerBound), range.upperBound))) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 78)
                        .controlSize(.small)
                    if !unit.isEmpty { Text(unit).foregroundStyle(.white.opacity(0.55)) }
                }
            case .color:
                HStack {
                    Text(option.title)
                    Spacer()
                    ColorPicker("", selection: Binding(get: { Color(rgba: model.color(option.id)) },
                                                       set: { model.set(option.id, .color(RGBA(color: $0))) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            case .file(let extensions):
                HStack {
                    Text(option.title)
                    Spacer()
                    Button(model.string(option.id).isEmpty ? "Vybrat…" : (model.string(option.id) as NSString).lastPathComponent) {
                        chooseFile(extensions: extensions)
                    }
                    .buttonStyle(GlassPillButtonStyle())
                    .lineLimit(1)
                }
            }
            if let help = option.help {
                Text(help)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12.5))
    }

    private func format(_ value: Double, unit: String, step: Double) -> String {
        let decimals = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2)
        return String(format: "%.\(decimals)f", value) + unit
    }

    private func chooseFile(extensions: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { model.set(option.id, .string(url.path)) }
    }
}

extension Color {
    init(rgba: RGBA) { self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a) }
}

extension RGBA {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
