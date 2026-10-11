import SwiftUI

/// Panel „Návyky“ v notchi: dnešní řádek z Notionu, kliknutí = odškrtnout (zapíše se hned).
struct HabitsNotchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let habits = model.habits
        Group {
            switch habits.status {
            case .notConnected:
                EmptyNotchState(symbol: "checklist", title: "Notion není připojený",
                                detail: "Nastavení → Návyky z Notionu")
            case .failed(let message) where habits.habits.isEmpty:
                EmptyNotchState(symbol: "exclamationmark.triangle", title: "Notion nejde načíst", detail: message)
            case .loading where habits.habits.isEmpty:
                ProgressView().controlSize(.small)
            default:
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 2) {
                        Text("\(habits.doneCount)/\(habits.habits.count)")
                            .font(.system(size: 18, weight: .light))
                            .monospacedDigit()
                        Text("DNES")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(width: 42)
                    .padding(.top, 4)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: [GridItem(.fixed(28)), GridItem(.fixed(28))], spacing: 5) {
                            ForEach(habits.habits) { habit in
                                HabitChip(habit: habit) { Task { await habits.toggle(habit) } }
                            }
                        }
                    }
                }
            }
        }
        .task { await habits.refresh() }
    }
}

private struct HabitChip: View {
    let habit: HabitsService.Habit
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: habit.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .contentTransition(.symbolEffect(.replace))
                Text(habit.id)
                    .font(.system(size: 9.5, weight: habit.done ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white.opacity(habit.done ? 1 : 0.6))
            .padding(.horizontal, 8)
            .frame(maxWidth: 150, minHeight: 26, alignment: .leading)
            .background(
                Capsule().fill(.white.opacity(habit.done ? 0.14 : (hovering ? 0.08 : 0.04)))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(habit.done ? 0.2 : 0.08), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(habit.id)
        .animation(.smooth(duration: 0.2), value: habit.done)
    }
}
