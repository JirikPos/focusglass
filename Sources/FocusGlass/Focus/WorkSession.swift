import Foundation
import Observation

/// Úkoly aktuálního pracovního bloku a čas, který na ně padl.
///
/// Čas čistého focusu (bez pauz, odchodů a rozptýlení) jde vždy na **aktivní** úkol.
/// Než si úkoly vybereš, čas se střádá a pak se připíše prvnímu vybranému.
@MainActor
@Observable
final class WorkSession {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        /// `nil` = vlastní úkol (nikam se neukládá).
        let clickUp: ClickUpClient.Task?
        var seconds: TimeInterval = 0
        var firstStart: Date?
        /// Úkol někdo (ty) uzavřel přímo v ClickUpu během bloku.
        var closedInClickUp = false
    }

    private(set) var items: [Item] = []
    private(set) var activeID: String?
    /// Blok běží a sbírá čas.
    private(set) var isActive = false
    /// Čeká se na výběr úkolů.
    private(set) var awaitingChoice = false
    @ObservationIgnored private var unassigned: TimeInterval = 0
    @ObservationIgnored private var started = Date()

    var activeItem: Item? { items.first { $0.id == activeID } }
    var hasClickUpItems: Bool { items.contains { $0.clickUp != nil } }

    func begin() {
        items = []
        activeID = nil
        unassigned = 0
        started = Date()
        isActive = true
        awaitingChoice = true
    }

    func choose(_ chosen: [Item]) {
        awaitingChoice = false
        items = chosen
        activeID = chosen.first?.id
        if !items.isEmpty {
            items[0].seconds += unassigned
            items[0].firstStart = started
        }
        unassigned = 0
    }

    /// Přidá úkoly během bloku (dosavadní časy zůstanou) a přepne na první nový.
    func append(_ more: [WorkSession.Item]) {
        awaitingChoice = false
        let fresh = more.filter { item in !items.contains { $0.id == item.id } }
        guard let first = fresh.first else { return }
        items += fresh
        activeID = first.id
    }

    /// Blok bez úkolů.
    func skipChoice() {
        awaitingChoice = false
        items = []
        activeID = nil
    }

    func add(_ seconds: TimeInterval) {
        guard isActive else { return }
        guard let index = items.firstIndex(where: { $0.id == activeID }) else {
            unassigned = max(0, unassigned + seconds)
            return
        }
        items[index].seconds = max(0, items[index].seconds + seconds)
        if items[index].firstStart == nil { items[index].firstStart = Date().addingTimeInterval(-seconds) }
    }

    func activate(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Úkol uzavřený v ClickUpu – přestane se počítat, aktivní přejde na další neuzavřený.
    /// Vrací nový aktivní úkol (nebo `nil`, pokud žádný nezbývá).
    @discardableResult
    func markClosed(_ id: String) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return activeItem }
        items[index].closedInClickUp = true
        if activeID == id {
            activeID = items.first { !$0.closedInClickUp }?.id
        }
        return activeItem
    }

    /// Ukončí blok a vrátí úkoly s časy.
    func end() -> [Item] {
        isActive = false
        awaitingChoice = false
        let result = items
        items = []
        activeID = nil
        unassigned = 0
        return result
    }
}
