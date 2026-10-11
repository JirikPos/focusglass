import SwiftUI

/// Dnešek, série, týden a tvrdé hodnocení – v okně z lišty.
struct StatsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        let today = stats.today
        let fraction = min(1, today.focus / stats.goal)

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(today.focus.hoursMinutes)
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
                Text("/ \(model.settings.dailyGoalHours)h dnes")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Label("\(stats.streak) d", systemImage: "flame")
                        .font(.system(size: 11, weight: .medium))
                    if IntentLog.todayCount > 0 {
                        Text("\(IntentLog.todayCount)× výjimka")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if today.lost >= 60 {
                        Text("−\(today.lost.hoursMinutes) rozptýlení")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 3)

            WeekBars(week: stats.week, goal: stats.goal)
                .frame(height: 34)

            Text(stats.verdict)
                .font(.system(size: 10.5, weight: .light))
                .italic()
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassPanel(radius: 18)
    }
}

private struct WeekBars: View {
    let week: [(label: String, focus: TimeInterval)]
    let goal: TimeInterval

    var body: some View {
        let top = max(goal, week.map(\.focus).max() ?? 0)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 3) {
                    GeometryReader { proxy in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(day.focus >= goal ? 0.9 : (index == week.count - 1 ? 0.5 : 0.22)))
                                .frame(height: max(2, proxy.size.height * day.focus / top))
                        }
                    }
                    Text(day.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(index == week.count - 1 ? 0.7 : 0.3))
                }
            }
        }
    }
}
