import SwiftUI

/// „Na čem budeš pracovat?“ – víc úkolů z ClickUpu + vlastní úkoly (Enter v poli).
struct TaskPickerView: View {
    /// Úkoly, které už v bloku jsou.
    let excluded: Set<String>
    /// `nil` / prázdné = bez úkolu.
    let done: ([WorkSession.Item]?) -> Void

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var chosen: [WorkSession.Item] = []
    @FocusState private var focused: Bool

    private var hasClickUp: Bool { model.clickUp.isConfigured }

    /// Bez hledání: moje úkoly. S hledáním: moje + všechny úkoly workspace (moje první).
    private var filtered: [ClickUpClient.Task] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let taken = excluded.union(chosen.map(\.id))
        let mine = model.clickUp.tasks.filter { !taken.contains($0.id) }
        guard !text.isEmpty else { return Array(mine.prefix(50)) }

        let mineIDs = Set(mine.map(\.id))
        let others = model.clickUp.allTasks.filter { !taken.contains($0.id) && !mineIDs.contains($0.id) }
        // Hledá se ve všech slovech dotazu (na pořadí nezáleží), bez ohledu na diakritiku.
        let words = Self.fold(text).split(separator: " ").map(String.init)
        return (mine + others).filter { task in
            let haystack = Self.fold("\(task.name) \(task.listName)")
            return words.allSatisfy { haystack.contains($0) }
        }
        .prefix(60)
        .map { $0 }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 12))
                Text("Na čem budeš pracovat?")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(chosen.isEmpty ? "Vyber jeden nebo víc" : "\(chosen.count) vybráno")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if !chosen.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(chosen.enumerated()), id: \.element.id) { index, item in
                            Button { chosen.removeAll { $0.id == item.id } } label: {
                                HStack(spacing: 4) {
                                    Text(index == 0 ? "▶ \(item.name)" : item.name).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.92)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 22)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(filtered) { task in
                        Button { chosen.append(Self.item(from: task)) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.5))
                                Text(task.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(Self.detail(task))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TaskRowButtonStyle())
                    }
                    if filtered.isEmpty {
                        Text(!hasClickUp
                             ? "Napiš úkol do pole a dej Enter (ClickUp není připojený)."
                             : model.clickUp.isLoadingAll
                                ? "Načítám všechny úkoly z ClickUpu…"
                                : "Nic nenalezeno – Enter přidá „\(query)“ jako vlastní úkol.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField("Hledej v ClickUpu nebo napiš vlastní úkol…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(focused ? 0.2 : 0.08), lineWidth: 0.75))
                    .focused($focused)
                    .onSubmit(addCustom)
                Button("Bez úkolu") { done(nil) }
                    .buttonStyle(GlassPillButtonStyle(size: 11))
                Button("Start") { done(chosen) }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.4 : 1)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
        }
        .task { await model.clickUp.refreshAllTasks() }
    }

    /// Enter: přesná shoda s ClickUp úkolem → vyber ho, jinak vlastní úkol.
    private func addCustom() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return chosen.isEmpty ? () : done(chosen) }
        if filtered.count == 1, let only = filtered.first {
            chosen.append(Self.item(from: only))
        } else {
            chosen.append(WorkSession.Item(id: UUID().uuidString, name: text, clickUp: nil))
        }
        query = ""
    }

    private static func item(from task: ClickUpClient.Task) -> WorkSession.Item {
        WorkSession.Item(id: task.id, name: task.name, clickUp: task)
    }

    private static func detail(_ task: ClickUpClient.Task) -> String {
        guard let due = task.due else { return task.listName }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(due) ? "dnes"
            : calendar.isDateInTomorrow(due) ? "zítra"
            : due < Date() ? "po termínu" : due.formatted(.dateTime.day().month())
        return task.listName.isEmpty ? day : "\(task.listName) · \(day)"
    }
}

private struct TaskRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.12 : 0.04))
            )
    }
}
