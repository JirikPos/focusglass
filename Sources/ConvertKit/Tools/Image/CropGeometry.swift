import CoreGraphics
import Foundation

/// Geometrie tažení ořezového rámečku (čistá matematika, aby šla testovat bez okna).
/// Souřadnice jsou normalizované (0…1, počátek vlevo nahoře).
public enum CropGeometry {
    public enum Handle: Sendable, Equatable {
        case move, new
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
    }

    public static let minimum = 0.02

    /// Co je pod bodem (v bodech pohledu): roh, hrana, vnitřek, nebo mimo (= nový rámeček).
    public static func hit(_ point: CGPoint, crop: CGRect, grab: CGFloat = 16) -> Handle {
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) <= grab }
        let left = near(point.x, crop.minX), right = near(point.x, crop.maxX)
        let top = near(point.y, crop.minY), bottom = near(point.y, crop.maxY)
        let insideX = point.x > crop.minX - grab && point.x < crop.maxX + grab
        let insideY = point.y > crop.minY - grab && point.y < crop.maxY + grab
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if top && insideX { return .top }
        if bottom && insideX { return .bottom }
        if left && insideY { return .left }
        if right && insideY { return .right }
        return crop.contains(point) ? .move : .new
    }

    /// Nový rámeček po tažení.
    /// - Parameters:
    ///   - start: rámeček při začátku tahu
    ///   - origin: normalizovaný bod, kde tah začal
    ///   - point: aktuální normalizovaný bod
    ///   - ratioK: při zamčeném poměru podíl `výška ÷ šířka` v normalizovaných souřadnicích
    ///     (`(W/H) / poměr`); `nil` = volný rámeček
    public static func updated(_ handle: Handle, start: NormalizedRect, origin: CGPoint, point: CGPoint, ratioK: Double?) -> NormalizedRect {
        let dx = Double(point.x - origin.x)
        let dy = Double(point.y - origin.y)
        var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height

        switch handle {
        case .move:
            return NormalizedRect(x: min(max(start.x + dx, 0), 1 - start.width), y: min(max(start.y + dy, 0), 1 - start.height),
                                  width: start.width, height: start.height)
        case .new:
            var width = abs(Double(point.x - origin.x))
            var height = abs(Double(point.y - origin.y))
            if let k = ratioK { height = width * k }
            let x = point.x >= origin.x ? Double(origin.x) : Double(origin.x) - width
            var y = point.y >= origin.y ? Double(origin.y) : Double(origin.y) - height
            if x + width > 1 { width = 1 - x }
            if y + height > 1 { height = 1 - y }
            if y < 0 { y = 0 }
            // Zamčený poměr: omezení výšky smrští i šířku.
            if let k = ratioK, k > 0, abs(height - width * k) > 1e-9 { width = height / k }
            return NormalizedRect(x: max(x, 0), y: y, width: max(width, minimum), height: max(height, minimum))
        case .topLeft: left += dx; top += dy
        case .topRight: right += dx; top += dy
        case .bottomLeft: left += dx; bottom += dy
        case .bottomRight: right += dx; bottom += dy
        case .top: top += dy
        case .bottom: bottom += dy
        case .left: left += dx
        case .right: right += dx
        }

        if let k = ratioK, k > 0 {
            // Zamčený poměr: hrany se nehýbou, rohy drží protilehlý roh.
            guard handle.isCorner else { return start }
            let anchorLeft = handle == .topRight || handle == .bottomRight // pevný je levý okraj
            let anchorTop = handle == .bottomLeft || handle == .bottomRight // pevný je horní okraj
            let anchorX = anchorLeft ? start.x : start.x + start.width
            let anchorY = anchorTop ? start.y : start.y + start.height
            let movingX = anchorLeft ? right : left
            var width = abs(movingX - anchorX)
            width = min(max(width, minimum), anchorLeft ? 1 - anchorX : anchorX)
            var height = width * k
            let room = anchorTop ? 1 - anchorY : anchorY
            if height > room { height = room; width = height / k }
            return NormalizedRect(x: anchorLeft ? anchorX : anchorX - width, y: anchorTop ? anchorY : anchorY - height,
                                  width: width, height: height)
        }

        left = min(max(left, 0), 1); right = min(max(right, 0), 1)
        top = min(max(top, 0), 1); bottom = min(max(bottom, 0), 1)
        if right - left < minimum {
            if handle == .left || handle == .topLeft || handle == .bottomLeft { left = right - minimum } else { right = left + minimum }
        }
        if bottom - top < minimum {
            if handle == .top || handle == .topLeft || handle == .topRight { top = bottom - minimum } else { bottom = top + minimum }
        }
        left = max(left, 0); top = max(top, 0)
        return NormalizedRect(x: left, y: top, width: min(right, 1) - left, height: min(bottom, 1) - top)
    }
}

extension ImageAnnotate {
    /// Zásah anotace bodem (normalizované souřadnice) s tolerancí ~1,5 % obrázku.
    public static func hit(_ a: Annotation, at p: Point) -> Bool {
        let tolerance = max(0.015, a.strokeWidth * 1.5)
        func inside(_ rect: NormalizedRect, grow: Double = 0) -> Bool {
            p.x >= rect.x - grow && p.x <= rect.x + rect.width + grow && p.y >= rect.y - grow && p.y <= rect.y + rect.height + grow
        }
        switch a.kind {
        case .line, .arrow:
            return distance(p, from: a.start, to: a.end) <= tolerance
        case .pen:
            return a.points.contains { hypot($0.x - p.x, $0.y - p.y) <= tolerance }
        case .rectangle, .ellipse:
            if a.filled { return inside(a.bounds, grow: tolerance) }
            let b = a.bounds
            let outer = inside(b, grow: tolerance)
            let core = p.x > b.x + tolerance && p.x < b.x + b.width - tolerance && p.y > b.y + tolerance && p.y < b.y + b.height - tolerance
            return outer && !core
        case .highlight, .pixelate:
            return inside(a.bounds, grow: tolerance)
        case .text:
            return inside(NormalizedRect(x: a.start.x, y: a.start.y, width: max(0.06, Double(a.text.count) * a.strokeWidth * 2.2),
                                         height: max(0.05, a.strokeWidth * 8)), grow: tolerance)
        case .number:
            return hypot(p.x - a.start.x, p.y - a.start.y) <= max(0.03, a.strokeWidth * 5)
        }
    }

    static func distance(_ p: Point, from a: Point, to b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Posune anotaci o `dx`, `dy` (normalizované).
    public static func moved(_ a: Annotation, dx: Double, dy: Double) -> Annotation {
        var result = a
        result.start = Point(a.start.x + dx, a.start.y + dy)
        result.end = Point(a.end.x + dx, a.end.y + dy)
        result.points = a.points.map { Point($0.x + dx, $0.y + dy) }
        return result
    }
}
