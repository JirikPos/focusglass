import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Malé okno se souborem, které plave nad ostatními okny na všech plochách.
/// Soubor se z něj dá zase vytáhnout (do mailu, prohlížeče…), dvojklik ho otevře.
private final class FloatPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        level = .floating
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatController {
    private static let size = CGSize(width: 132, height: 150)
    private static let maxWindows = 8
    private var panels: [URL: FloatPanel] = [:]

    func show(_ url: URL) {
        if let existing = panels[url] { return existing.orderFrontRegardless() }
        if panels.count >= Self.maxWindows, let oldest = panels.keys.first { close(oldest) }

        let panel = FloatPanel(size: Self.size)
        let view = FloatView(url: url, close: { [weak self] in self?.close(url) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.setFrameOrigin(nextOrigin())
        panel.orderFrontRegardless()
        panels[url] = panel
    }

    func close(_ url: URL) {
        panels.removeValue(forKey: url)?.orderOut(nil)
    }

    /// Okna do sloupce u pravého okraje obrazovky s myší.
    private func nextOrigin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let index = CGFloat(panels.count)
        let x = visible.maxX - Self.size.width - 20
        let y = visible.maxY - (Self.size.height + 12) * (index + 1) - 8
        return NSPoint(x: x, y: max(visible.minY + 8, y))
    }
}

private struct FloatView: View {
    let url: URL
    let close: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        let icon = thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
        VStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Tažení obrázku = tažení souboru; okraj okna slouží k posunutí okna.
                .overlay {
                    ShelfDragSource(
                        url: url,
                        icon: icon,
                        onHover: { _ in },
                        onOpen: { NSWorkspace.shared.open(url) },
                        onDragCompleted: {},
                        menu: { menu }
                    )
                }
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(GlassIconButtonStyle(size: 18))
                    .padding(6)
                    .help("Zavřít")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
        .task(id: url) { thumbnail = await Self.thumbnail(for: url) }
    }

    private var menu: NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Otevřít", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) })
        menu.addItem(ClosureMenuItem("Zobrazit ve Finderu", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Zavřít", symbol: "xmark", handler: close))
        return menu
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 192, height: 192), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
