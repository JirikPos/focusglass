import AppKit
import ConvertKit
import SwiftUI

/// Vývojový režim: vykreslí okno nástroje nebo kolo do PNG bez spuštění aplikace.
///   FocusGlass --render-tool <výstup.png> <id-nástroje> <soubor[,soubor…]> [volba=hodnota …]
///   FocusGlass --render-wheel <výstup.png> [convert|tools|actions] [soubor[,soubor…]] [zvýrazněný-lístek]
enum DevRender {
    /// Vrací `true`, když šlo o vykreslení (a aplikace se nemá spouštět).
    static func handle(_ arguments: [String]) -> Bool {
        guard let flag = arguments.first(where: { $0 == "--render-tool" || $0 == "--render-wheel" }),
              let index = arguments.firstIndex(of: flag) else { return false }
        let rest = Array(arguments.dropFirst(index + 1))
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .darkAqua)
            if flag == "--render-tool" { renderTool(rest) } else { renderWheel(rest) }
        }
        return true
    }

    @MainActor
    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Vykreslí pohled ve skutečném (neviditelném) okně – na rozdíl od `ImageRenderer` tak vzniknou
    /// i ovládací prvky AppKitu a obsah `ScrollView`. Nepotřebuje oprávnění k nahrávání obrazovky.
    @MainActor
    private static func write(_ view: some View, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Okno nikdy nezobrazujeme; pohled se jen rozloží a překreslí.
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return fail("render: bitmapa") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return fail("render: PNG") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("render: \(error)") }
    }

    @MainActor
    private static func renderTool(_ arguments: [String]) {
        guard arguments.count >= 3 else { return fail("použití: --render-tool <výstup.png> <id> <soubor[,soubor]> [volba=hodnota…]") }
        let registry = Catalog.makeRegistry()
        guard let tool = registry.operation(id: arguments[1]) as? Tool else { return fail("neznámý nástroj \(arguments[1])") }
        let selection = Selection(urls: arguments[2].split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        let model = ToolSheetModel(tool: tool, selection: selection)
        for pair in arguments.dropFirst(3) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let option = tool.options.first(where: { $0.id == parts[0] }) else { continue }
            model.set(option.id, parse(parts[1], for: option))
        }
        // Načtení zdroje a náhledu běží asynchronně – chvíli točit smyčkou.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if model.original != nil, !model.isWorking, !model.isDetecting, model.result != nil || !tool.hasPreview { break }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        write(ToolSheetView(model: model), size: CGSize(width: 1100, height: 720), to: arguments[0])
    }

    @MainActor
    private static func parse(_ text: String, for option: ToolOption) -> OptionValue {
        switch option.kind {
        case .toggle: return .bool(text == "true" || text == "1")
        case .slider: return .double(Double(text) ?? 0)
        case .number: return .int(Int(text) ?? 0)
        case .color: return .color(RGBA(hex: text) ?? .black)
        default: return .string(text)
        }
    }

    @MainActor
    private static func renderWheel(_ arguments: [String]) {
        guard let output = arguments.first else { return fail("použití: --render-wheel <výstup.png> [kolo] [soubor] [zvýrazněný]") }
        let wheel = arguments.dropFirst().first.flatMap(Wheel.init(rawValue:)) ?? .actions
        let urls = (arguments.dropFirst(2).first ?? "/tmp/Ukázka.png").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let service = ConvertService(settings: AppSettings())
        let selection = Selection(urls: urls)
        let model = WheelModel()
        model.show(wheel, selection: selection, items: service.items(for: selection, wheel: wheel))
        model.keys = Wheel.allCases.map { ($0, WheelKey.defaultKey(for: $0)) }
        model.hovered = arguments.dropFirst(3).first.flatMap(Int.init)
        write(WheelView(model: model, animated: false).background(Color(white: 0.5)), size: WheelLayout.size, to: output)
    }
}
