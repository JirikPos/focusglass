import CoreGraphics
import Foundation

/// Geometrie kola: lístek 0 je nahoře (12 hodin), další po směru hodinových ručiček.
/// Úhly jsou v radiánech měřené od svislice po směru hodinových ručiček.
public struct WheelGeometry: Sendable, Equatable {
    public let count: Int
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    /// Jak daleko za vnějším okrajem se lístek ještě vybere (tažení bývá nepřesné).
    public let slop: CGFloat

    public init(count: Int, innerRadius: CGFloat, outerRadius: CGFloat, slop: CGFloat = 40) {
        self.count = max(count, 0)
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.slop = slop
    }

    /// Šířka jednoho lístku.
    public var sweep: Double { count > 0 ? 2 * .pi / Double(count) : 0 }

    /// Úhel středu lístku.
    public func midAngle(of index: Int) -> Double { Double(index) * sweep }

    /// Začátek a konec lístku (konec může přesáhnout 2π).
    public func range(of index: Int) -> (start: Double, end: Double) {
        let mid = midAngle(of: index)
        return (mid - sweep / 2, mid + sweep / 2)
    }

    /// Lístek pod bodem. `dx`, `dy` je posun od středu, **`dy` kladné nahoru** (souřadnice AppKitu).
    /// Ve středu (zrušit) a daleko mimo kolo vrací `nil`.
    public func segment(dx: CGFloat, dy: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius + slop else { return nil }
        var angle = atan2(Double(dx), Double(dy)) // 0 = nahoře, kladně po směru hodin
        if angle < 0 { angle += 2 * .pi }
        let index = Int(((angle + sweep / 2) / sweep).rounded(.down)) % count
        return index
    }

    /// Bod na kružnici o poloměru `radius` ve směru `angle` – v souřadnicích s **y dolů** (SwiftUI).
    public static func point(angle: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    /// Lístek, na který se přesune výběr šipkou. `step` +1 = po směru hodin.
    public func step(from index: Int?, by step: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return step >= 0 ? 0 : count - 1 }
        return ((index + step) % count + count) % count
    }
}
