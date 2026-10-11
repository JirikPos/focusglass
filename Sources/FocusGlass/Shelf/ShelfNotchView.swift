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
                VStack(spacing: 6) {
                    Button { shelf.quickLook() } label: { Image(systemName: "eye") }
                        .buttonStyle(GlassIconButtonStyle(size: 24))
                        .help("Rychlý náhled (mezerník)")
                    Button(action: shelf.clear) { Image(systemName: "trash") }
                        .buttonStyle(GlassIconButtonStyle(size: 24))
                        .help("Vyprázdnit odkladiště")
                }
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let shelf = model.shelf
        let icon = shelf.icon(for: item)
        VStack(spacing: 3) {
            Image(nsImage: icon)
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
        .overlay {
            ShelfDragSource(
                url: item.url,
                icon: icon,
                onHover: { inside in
                    hovering = inside
                    shelf.hovered = inside ? item : (shelf.hovered == item ? nil : shelf.hovered)
                },
                onOpen: { shelf.open(item) },
                onDragCompleted: {
                    if model.settings.shelfRemoveAfterDrag { shelf.remove(item) }
                },
                menu: { menu(shelf) }
            )
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
        }
        .help(item.url.path)
    }

    private func menu(_ shelf: ShelfStore) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Otevřít", symbol: "arrow.up.forward.app") { shelf.open(item) })
        menu.addItem(ClosureMenuItem("Rychlý náhled", symbol: "eye") { shelf.quickLook(item) })
        menu.addItem(ClosureMenuItem("AirDrop", symbol: "airplayaudio") { shelf.airDrop(item) })
        menu.addItem(ClosureMenuItem("Zobrazit ve Finderu", symbol: "folder") { shelf.revealInFinder(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Odebrat z odkladiště", symbol: "xmark") { shelf.remove(item) })
        return menu
    }
}
