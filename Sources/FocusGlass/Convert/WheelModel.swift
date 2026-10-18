import ConvertKit
import Foundation
import Observation

/// Jeden lístek kola.
struct WheelItem: Identifiable, Equatable {
    enum Target: Equatable {
        case operation(String)
        case action(FileAction)
        /// Další stránka, když se položky nevejdou.
        case more
    }

    let id: String
    let title: String
    let symbol: String?
    let target: Target
    /// Proč nejde použít (chybí nástroj); `nil` = dostupné.
    var hint: String?
    var approximate = false

    var isEnabled: Bool { hint == nil }

    static let more = WheelItem(id: "more", title: "Další", symbol: "ellipsis", target: .more)
}

/// Rozměry kola na jednom místě – sdílí je kreslení i určování lístku pod kurzorem.
enum WheelLayout {
    static let outerRadius: CGFloat = 150
    static let innerRadius: CGFloat = 58
    /// Okraj kolem kola (stín, tolerance tažení).
    static let padding: CGFloat = 26
    /// Pruh s klávesami kol pod kolem.
    static let footerHeight: CGFloat = 40
    static let maxPetals = 8

    static var wheelSide: CGFloat { 2 * (outerRadius + padding) }
    static var size: CGSize { CGSize(width: wheelSide, height: wheelSide + footerHeight) }
    /// Střed kola v souřadnicích SwiftUI (y dolů).
    static var center: CGPoint { CGPoint(x: wheelSide / 2, y: wheelSide / 2) }
}

/// Stav otevřeného kola.
@MainActor
@Observable
final class WheelModel {
    private(set) var wheel: Wheel = .convert
    private(set) var selection = Selection(urls: [])
    private(set) var allItems: [WheelItem] = []
    private(set) var page = 0
    var hovered: Int?
    /// Klávesy kol pro patičku (⇧ Převést · ⌘ Nástroje · ⌃ Akce).
    var keys: [(Wheel, WheelKey)] = []

    func show(_ wheel: Wheel, selection: Selection, items: [WheelItem]) {
        if wheel != self.wheel || selection != self.selection { page = 0 }
        self.wheel = wheel
        self.selection = selection
        allItems = items
        hovered = nil
        page = min(page, pageCount - 1)
    }

    var pageCount: Int {
        guard allItems.count > WheelLayout.maxPetals else { return 1 }
        let perPage = WheelLayout.maxPetals - 1
        return (allItems.count + perPage - 1) / perPage
    }

    /// Lístky na aktuální stránce (při stránkování poslední = „Další“).
    var visibleItems: [WheelItem] {
        guard pageCount > 1 else { return allItems }
        let perPage = WheelLayout.maxPetals - 1
        let start = page * perPage
        return Array(allItems[start..<min(start + perPage, allItems.count)]) + [.more]
    }

    var geometry: WheelGeometry {
        WheelGeometry(
            count: visibleItems.count,
            innerRadius: WheelLayout.innerRadius,
            outerRadius: WheelLayout.outerRadius,
            slop: WheelLayout.padding
        )
    }

    var hoveredItem: WheelItem? {
        guard let hovered, visibleItems.indices.contains(hovered) else { return nil }
        return visibleItems[hovered]
    }

    func nextPage() {
        page = (page + 1) % max(pageCount, 1)
        hovered = nil
    }
}
