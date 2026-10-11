import SwiftUI

/// „Splnil jsi to?“ – u každého úkolu Ano / Ne a čas, který na něm padl.
/// Používá se v obrazovce pauzy i v notchi (`compact`).
struct TaskReviewView: View {
    let items: [WorkSession.Item]
    var compact = false
    let save: ([String: Bool]) -> Void

    @State private var answers: [String: Bool] = [:]

    private var answeredAll: Bool { items.allSatisfy { answers[$0.id] != nil } }

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 6 : 10) {
            HStack {
                Text("Splnil jsi to?")
                    .font(.system(size: compact ? 12.5 : 20, weight: compact ? .semibold : .light))
                if compact { Spacer() }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: compact ? 3 : 6) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .frame(maxWidth: compact ? .infinity : 520, maxHeight: compact ? 120 : 240)

            HStack(spacing: 10) {
                if compact { Spacer() }
                Text(answeredAll ? "\(answers.values.filter { $0 }.count)/\(items.count) splněno"
                                 : "Rozhodni u všech")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                Button("Uložit") { save(answers) }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(!answeredAll)
                    .opacity(answeredAll ? 1 : 0.4)
            }
        }
        .onAppear {
            // Úkoly uzavřené přímo v ClickUpu jsou hotové.
            for item in items where item.closedInClickUp { answers[item.id] = true }
        }
    }

    private func row(_ item: WorkSession.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.clickUp == nil ? "pencil" : "checklist")
                .font(.system(size: compact ? 9 : 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 14)
            Text(item.name)
                .font(.system(size: compact ? 11 : 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.seconds.hoursMinutes)
                .font(.system(size: compact ? 10 : 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            choice("Ne", selected: answers[item.id] == false) { answers[item.id] = false }
            choice("Ano", selected: answers[item.id] == true) { answers[item.id] = true }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 3 : 7)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 10 : 11.5, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.7))
                .frame(width: compact ? 36 : 46, height: compact ? 20 : 24)
                .background(Capsule().fill(.white.opacity(selected ? 0.95 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
