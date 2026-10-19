import SwiftUI

/// Vstupní bod. Vývojové režimy `--render-*` se vyřídí dřív, než vznikne `AppModel`
/// (ten čte Klíčenku a spouští sledování), takže nic nevyskakuje a nic nezůstane běžet.
@main
enum FocusGlassMain {
    static func main() {
        if DevRender.handle(CommandLine.arguments) { return }
        FocusGlassApp.main()
    }
}

struct FocusGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Během vynuceného večerního review nejde aplikaci ukončit (⌘Q, menu).
/// Odhlášení, restart a vypnutí Macu se neblokují.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemQuit = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                          kAEShowShutdownDialog, kAEShutDown].map { OSType($0) }
        if let reason, systemQuit.contains(reason) { return .terminateNow }
        let reviewActive = MainActor.assumeIsolated { ForcedReviewController.isActive }
        return reviewActive ? .terminateCancel : .terminateNow
    }
}

/// Ikona (a volitelně čas) v systémové liště.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: rendered)
    }

    /// Lišta jinak skládá ikonu a text zvlášť a nezarovná je. Proto obojí vykreslíme
    /// do jednoho template obrázku: symbol na účaří textu (tak jsou SF Symbols navržené).
    private var rendered: NSImage {
        let timer = model.timer
        let font = Font.system(size: 13, weight: .medium)
        let content = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(font)
            if model.settings.showTimeInMenuBar && timer.hasStarted {
                Text(timer.remaining.clock)
                    .font(font)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }

    private var symbol: String { model.timer.stateSymbol }
}
