import SwiftUI

@main
struct FocusGlassApp: App {
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

/// Ikona (a volitelně čas) v systémové liště.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let timer = model.timer
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if model.settings.showTimeInMenuBar && timer.hasStarted {
                Text(timer.remaining.clock)
                    .monospacedDigit()
            }
        }
    }

    private var symbol: String {
        let timer = model.timer
        if timer.hasStarted && !timer.isRunning { return "pause.circle" }
        // Oko v kruhu = poznávací znak FocusGlass (stejný motiv jako ikona aplikace).
        return timer.phase == .work ? "eye.circle" : "cup.and.saucer"
    }
}
