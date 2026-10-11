import SwiftUI

/// Panel „Schránka“ v rozbaleném notchi.
struct ClipboardNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clipboard = model.clipboard
        if clipboard.items.isEmpty {
            EmptyNotchState(
                symbol: "doc.on.clipboard",
                title: "Schránka je prázdná",
                detail: "Zkopíruj text a objeví se tady"
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(clipboard.items) { item in
                        ClipboardChip(item: item, copied: clipboard.justCopied == item.id) {
                            clipboard.copy(item)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardChip: View {
    let item: ClipboardHistory.Item
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 112, height: 44, alignment: .topLeading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.1 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
                )
                .overlay {
                    if copied {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.75))
                            .overlay(
                                Label("Zkopírováno", systemImage: "checkmark")
                                    .font(.system(size: 10, weight: .medium))
                            )
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: copied)
        .help("Klikni pro zkopírování zpět")
    }
}
