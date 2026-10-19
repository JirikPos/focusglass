import CoreGraphics
import Foundation
import Testing
@testable import ConvertKit

@Suite struct CropGeometryTests {
    let start = NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    @Test func hitTesting() {
        let crop = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CropGeometry.hit(p(100, 100), crop: crop) == .topLeft)
        #expect(CropGeometry.hit(p(300, 200), crop: crop) == .bottomRight)
        #expect(CropGeometry.hit(p(200, 100), crop: crop) == .top)
        #expect(CropGeometry.hit(p(300, 150), crop: crop) == .right)
        #expect(CropGeometry.hit(p(200, 150), crop: crop) == .move)
        #expect(CropGeometry.hit(p(20, 20), crop: crop) == .new)
    }

    @Test func moveIsClampedToImage() {
        let moved = CropGeometry.updated(.move, start: start, origin: p(0.3, 0.3), point: p(0.95, 0.3), ratioK: nil)
        #expect(abs(moved.x - 0.6) < 1e-9 && moved.width == 0.4)
        let up = CropGeometry.updated(.move, start: start, origin: p(0.3, 0.3), point: p(0.3, -2), ratioK: nil)
        #expect(up.y == 0)
    }

    @Test func freeResize() {
        let r = CropGeometry.updated(.bottomRight, start: start, origin: p(0.6, 0.6), point: p(0.8, 0.7), ratioK: nil)
        #expect(abs(r.width - 0.6) < 1e-9 && abs(r.height - 0.5) < 1e-9)
        #expect(r.x == 0.2 && r.y == 0.2)

        let edge = CropGeometry.updated(.left, start: start, origin: p(0.2, 0.4), point: p(0.1, 0.4), ratioK: nil)
        #expect(abs(edge.x - 0.1) < 1e-9 && abs(edge.width - 0.5) < 1e-9 && abs(edge.height - 0.4) < 1e-9)
    }

    @Test func resizeNeverInvertsOrLeavesImage() {
        // Tažení levé hrany za pravou: zůstane minimální šířka.
        let r = CropGeometry.updated(.left, start: start, origin: p(0.2, 0.4), point: p(0.9, 0.4), ratioK: nil)
        #expect(r.width >= CropGeometry.minimum - 1e-9)
        #expect(r.x + r.width <= 1 + 1e-9)
        let out = CropGeometry.updated(.bottomRight, start: start, origin: p(0.6, 0.6), point: p(3, 3), ratioK: nil)
        #expect(out.x + out.width <= 1 + 1e-9 && out.y + out.height <= 1 + 1e-9)
    }

    @Test func lockedRatioCornersKeepRatioAndAnchor() {
        // k = výška ÷ šířka v normalizovaných souřadnicích; 0,5 = obdélník 2:1 v pixelech obrázku 1:1.
        let k = 0.5
        let base = NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2)
        let r = CropGeometry.updated(.bottomRight, start: base, origin: p(0.6, 0.4), point: p(0.8, 0.9), ratioK: k)
        #expect(abs(r.height / r.width - k) < 1e-9)
        #expect(r.x == 0.2 && r.y == 0.2, "protilehlý roh zůstává")
        #expect(abs(r.width - 0.6) < 1e-9, "šířka podle vodorovného pohybu")

        let tl = CropGeometry.updated(.topLeft, start: base, origin: p(0.2, 0.2), point: p(0.1, 0.0), ratioK: k)
        #expect(abs(tl.height / tl.width - k) < 1e-9)
        #expect(abs((tl.x + tl.width) - 0.6) < 1e-9 && abs((tl.y + tl.height) - 0.4) < 1e-9, "pravý dolní roh zůstává")
    }

    @Test func lockedRatioIgnoresEdgeHandlesAndStaysInside() {
        let k = 1.0
        let square = NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)
        #expect(CropGeometry.updated(.right, start: square, origin: p(0.8, 0.6), point: p(0.9, 0.6), ratioK: k) == square)
        let grown = CropGeometry.updated(.bottomRight, start: square, origin: p(0.8, 0.8), point: p(2, 2), ratioK: k)
        #expect(grown.x + grown.width <= 1 + 1e-9 && grown.y + grown.height <= 1 + 1e-9)
        #expect(abs(grown.height / grown.width - k) < 1e-9)
    }

    @Test func newRectangleFromPointAndRatio() {
        let free = CropGeometry.updated(.new, start: .full, origin: p(0.3, 0.3), point: p(0.1, 0.5), ratioK: nil)
        #expect(abs(free.x - 0.1) < 1e-9 && abs(free.width - 0.2) < 1e-9 && abs(free.y - 0.3) < 1e-9 && abs(free.height - 0.2) < 1e-9)
        let locked = CropGeometry.updated(.new, start: .full, origin: p(0.5, 0.5), point: p(0.9, 0.52), ratioK: 0.5)
        #expect(abs(locked.height / locked.width - 0.5) < 1e-9)
        #expect(locked.y + locked.height <= 1 + 1e-9)
        // Při zamčeném poměru u dolního okraje se zmenší i šířka, ne jen výška.
        let edge = CropGeometry.updated(.new, start: .full, origin: p(0.1, 0.9), point: p(0.9, 0.95), ratioK: 1)
        #expect(abs(edge.height / edge.width - 1) < 1e-9 && edge.y + edge.height <= 1 + 1e-9)
    }
}

@Suite struct AnnotationHitTests {
    typealias A = ImageAnnotate.Annotation
    func pt(_ x: Double, _ y: Double) -> ImageAnnotate.Point { .init(x, y) }

    @Test func linesAndArrows() {
        let arrow = A(kind: .arrow, start: pt(0.1, 0.1), end: pt(0.9, 0.1))
        #expect(ImageAnnotate.hit(arrow, at: pt(0.5, 0.11)))
        #expect(!ImageAnnotate.hit(arrow, at: pt(0.5, 0.3)))
        #expect(ImageAnnotate.hit(arrow, at: pt(0.05, 0.1)) == false)
    }

    @Test func outlinedRectangleIsHollow() {
        let outlined = A(kind: .rectangle, start: pt(0.2, 0.2), end: pt(0.8, 0.8))
        #expect(ImageAnnotate.hit(outlined, at: pt(0.2, 0.5)), "hrana")
        #expect(!ImageAnnotate.hit(outlined, at: pt(0.5, 0.5)), "střed prázdného obdélníku je volný (jde kliknout na to, co je pod ním)")
        var filled = outlined
        filled.filled = true
        #expect(ImageAnnotate.hit(filled, at: pt(0.5, 0.5)))
    }

    @Test func textNumberPenAndHighlight() {
        #expect(ImageAnnotate.hit(A(kind: .number, start: pt(0.5, 0.5), end: pt(0.5, 0.5), text: "1", strokeWidth: 0.006), at: pt(0.51, 0.5)))
        #expect(!ImageAnnotate.hit(A(kind: .number, start: pt(0.5, 0.5), end: pt(0.5, 0.5), text: "1"), at: pt(0.7, 0.5)))
        #expect(ImageAnnotate.hit(A(kind: .text, start: pt(0.3, 0.3), end: pt(0.3, 0.3), text: "Pozor"), at: pt(0.33, 0.32)))
        let pen = A(kind: .pen, start: pt(0, 0), end: pt(1, 1), points: [pt(0.1, 0.1), pt(0.2, 0.2), pt(0.3, 0.1)])
        #expect(ImageAnnotate.hit(pen, at: pt(0.2, 0.21)))
        #expect(!ImageAnnotate.hit(pen, at: pt(0.8, 0.8)))
        #expect(ImageAnnotate.hit(A(kind: .highlight, start: pt(0.1, 0.1), end: pt(0.4, 0.2)), at: pt(0.25, 0.15)))
    }

    @Test func movingKeepsShape() {
        let pen = A(kind: .pen, start: pt(0.1, 0.1), end: pt(0.3, 0.3), points: [pt(0.1, 0.1), pt(0.3, 0.3)])
        let moved = ImageAnnotate.moved(pen, dx: 0.2, dy: -0.05)
        #expect(abs(moved.start.x - 0.3) < 1e-9 && abs(moved.end.y - 0.25) < 1e-9)
        #expect(moved.points.count == 2 && abs(moved.points[1].x - 0.5) < 1e-9)
        #expect(moved.id == pen.id, "přesun nesmí změnit identitu")
    }
}
