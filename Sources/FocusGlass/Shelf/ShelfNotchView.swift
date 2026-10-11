import SwiftUI

/// Panel „Odkladiště“ v rozbaleném notchi.
struct ShelfNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shelf = model.shelf
        if shelf.items.isEmpty {
            EmptyNotchState(
                symbol: "tray.and.arrow.down",
                title: "Přetáhni sem soubory",
                detail: "Odsud je pak vytáhneš kamkoli"
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        } else {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                }
                Button(action: shelf.clear) { Image(systemName: "trash") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Vyprázdnit odkladiště")
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: model.shelf.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            Text(item.name)
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 50)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(hovering ? 0.08 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { model.shelf.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { model.shelf.open(item) }
        .contextMenu {
            Button("Otevřít") { model.shelf.open(item) }
            Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Odebrat z odkladiště") { model.shelf.remove(item) }
        }
        .help(item.url.path)
    }
}
