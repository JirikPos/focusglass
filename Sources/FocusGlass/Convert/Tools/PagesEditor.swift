import ConvertKit
import SwiftUI

/// Mřížka stránek PDF: výběr kliknutím (⌘ přidá další), řazení přetažením, otáčení, mazání, duplikace.
struct PagesEditor: View {
    let model: ToolSheetModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 18) {
                    ForEach(Array(model.pageSpecs.enumerated()), id: \.element.id) { index, spec in
                        PageCell(model: model, spec: spec, position: index + 1)
                    }
                }
                .padding(20)
                // Pustit za poslední stránku = přesunout na konec.
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.movePage(id, before: nil)
                    return true
                }
            }
            .background(Color(white: 0.1))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { model.rotateSelectedPages(by: -90) } label: { Image(systemName: "rotate.left") }
                .help("Otočit doleva")
            Button { model.rotateSelectedPages(by: 90) } label: { Image(systemName: "rotate.right") }
                .help("Otočit doprava")
            Button { model.duplicateSelectedPages() } label: { Image(systemName: "plus.square.on.square") }
                .help("Zdvojit vybrané")
            Button { model.deleteSelectedPages() } label: { Image(systemName: "trash") }
                .help("Smazat vybrané").keyboardShortcut(.delete, modifiers: [])
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button { model.undoPages() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndoPages).keyboardShortcut("z", modifiers: .command).help("Zpět (⌘Z)")
            Button("Vybrat vše") { model.selectAllPages() }
                .buttonStyle(GlassPillButtonStyle()).keyboardShortcut("a", modifiers: .command)
            Spacer()
            Text("\(model.pageSpecs.count) stran · vybráno \(model.selectedPages.count)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(GlassIconButtonStyle(size: 26))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.35))
    }
}

private struct PageCell: View {
    let model: ToolSheetModel
    let spec: PDFPages.PageSpec
    let position: Int

    var body: some View {
        let selected = model.selectedPages.contains(spec.id)
        VStack(spacing: 6) {
            ZStack {
                if let image = model.thumbnail(for: spec) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
                } else {
                    Rectangle().fill(.white.opacity(0.08))
                }
            }
            .frame(height: 190)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? .white.opacity(0.85) : .clear, lineWidth: 1.5))
            Text("\(position)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.togglePage(spec.id, extend: NSEvent.modifierFlags.contains(.command)) }
        .draggable(spec.id.uuidString) {
            if let image = model.thumbnail(for: spec) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 90) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.movePage(id, before: spec.id)
            return true
        }
        .accessibilityLabel("Stránka \(position)")
    }
}
