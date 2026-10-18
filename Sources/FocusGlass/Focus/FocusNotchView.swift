import SwiftUI

/// Panel „Focus“ v rozbaleném notchi.
struct FocusNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(progress: timer.progress, lineWidth: 1.5)
                Image(systemName: timer.stateSymbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 34, height: 34)
            .animation(.linear(duration: 0.9), value: timer.progress)

            VStack(alignment: .leading, spacing: 0) {
                Text(timer.remaining.clock)
                    .font(.system(size: 24, weight: .ultraLight))
                    .monospacedDigit()
                Text("Dnes \(model.stats.today.focus.hoursMinutes) · série \(model.stats.streak) d")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                if model.session.isActive && !model.session.items.isEmpty {
                    TaskMenu()
                } else {
                    Text(secondaryLine)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(action: model.startEyeBreak) { Image(systemName: "eye") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Pauza pro oči teď")
                Button(action: timer.reset) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Reset")
                Button(action: timer.toggle) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PrimaryButtonStyle(size: 32))
                Button(action: timer.skip) { Image(systemName: "forward.end") }
                    .buttonStyle(GlassIconButtonStyle(size: 24))
                    .help("Přeskočit")
            }
        }
    }

    /// Schůzka má přednost před připomínkou očí.
    private var secondaryLine: String {
        if let minutes = model.calendar.minutesUntilNext, let meeting = model.calendar.next {
            return "Za \(minutes) min: \(meeting.title)"
        }
        return model.eyeCare.status
    }
}

/// Aktivní úkol bloku – kliknutím přepneš, na který úkol jde čas, nebo přidáš další.
private struct TaskMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        Menu {
            ForEach(session.items) { item in
                Button {
                    session.activate(item.id)
                } label: {
                    if item.id == session.activeID {
                        Label("\(item.name) · \(item.seconds.hoursMinutes)", systemImage: "play.fill")
                    } else {
                        Text("\(item.closedInClickUp ? "✓ " : "")\(item.name) · \(item.seconds.hoursMinutes)")
                    }
                }
                .disabled(item.closedInClickUp)
            }
            Divider()
            Button("Přidat úkol…", action: model.addTasksToSession)
        } label: {
            Text(session.activeItem.map { "▶ \($0.name) · \($0.seconds.hoursMinutes)" } ?? "Vyber úkol…")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Na který úkol jde teď čas")
    }
}
