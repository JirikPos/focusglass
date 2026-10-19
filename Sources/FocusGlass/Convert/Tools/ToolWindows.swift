import AppKit
import ConvertKit
import SwiftUI

/// Otevírá okna nástrojů. Každý nástroj má nejvýš jedno okno; opětovné otevření ho přenese dopředu.
@MainActor
final class ToolWindows: NSObject, NSWindowDelegate {
    /// Uživatel potvrdil volby – spustit nástroj.
    var onApply: ((Tool, Selection, [String: OptionValue]) -> Void)?

    private var windows: [String: (window: NSWindow, model: ToolSheetModel)] = [:]

    func present(_ tool: Tool, selection: Selection) {
        // Nové okno nahradí staré se stejným nástrojem (jiný výběr).
        close(tool.id)

        let model = ToolSheetModel(tool: tool, selection: selection)
        model.onApply = { [weak self] tool, selection, options in self?.onApply?(tool, selection, options) }
        model.onClose = { [weak self] in self?.close(tool.id) }

        let size = Self.size(for: tool)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = tool.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: ToolSheetView(model: model).ignoresSafeArea())
        window.delegate = self
        window.center()
        windows[tool.id] = (window, model)

        // Aplikace žije jen v liště, aby okno dostalo klávesnici, musí se aktivovat.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        guard let entry = windows.removeValue(forKey: id) else { return }
        entry.window.delegate = nil
        entry.window.orderOut(nil)
        entry.window.contentView = nil
    }

    func closeAll() {
        Array(windows.keys).forEach(close)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.window === closing })?.key else { return }
        windows.removeValue(forKey: id)
    }

    private static func size(for tool: Tool) -> NSSize {
        switch tool.editor {
        case .annotate, .crop, .redact: NSSize(width: 1100, height: 720)
        default: NSSize(width: 980, height: 660)
        }
    }
}
