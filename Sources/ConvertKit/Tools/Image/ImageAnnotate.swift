import AppKit
import CoreGraphics
import Foundation

/// Anotace fotek: šipky, čáry, tvary, zvýrazňovač, text, číslované popisky, kresba a pixelizace.
/// Souřadnice jsou normalizované (0…1, počátek vlevo nahoře), tloušťky jsou podíl kratší strany –
/// stejná anotace proto vypadá stejně v náhledu i v plném rozlišení.
public enum ImageAnnotate {
    public struct Point: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public struct Annotation: Sendable, Codable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable, CaseIterable {
            case arrow, line, rectangle, ellipse, highlight, text, number, pen, pixelate

            public var title: String {
                switch self {
                case .arrow: "Šipka"
                case .line: "Čára"
                case .rectangle: "Obdélník"
                case .ellipse: "Elipsa"
                case .highlight: "Zvýrazňovač"
                case .text: "Text"
                case .number: "Číslo"
                case .pen: "Tužka"
                case .pixelate: "Pixelizace"
                }
            }

            public var symbol: String {
                switch self {
                case .arrow: "arrow.up.right"
                case .line: "line.diagonal"
                case .rectangle: "rectangle"
                case .ellipse: "circle"
                case .highlight: "highlighter"
                case .text: "textformat"
                case .number: "1.circle"
                case .pen: "pencil.tip"
                case .pixelate: "squareshape.split.3x3"
                }
            }
        }

        public var id: UUID
        public var kind: Kind
        public var start: Point
        public var end: Point
        public var points: [Point]
        public var text: String
        public var color: RGBA
        /// Podíl kratší strany obrázku.
        public var strokeWidth: Double
        public var filled: Bool

        public init(id: UUID = UUID(), kind: Kind, start: Point, end: Point, points: [Point] = [], text: String = "",
                    color: RGBA = .red, strokeWidth: Double = 0.006, filled: Bool = false) {
            self.id = id; self.kind = kind; self.start = start; self.end = end; self.points = points
            self.text = text; self.color = color; self.strokeWidth = strokeWidth; self.filled = filled
        }

        /// Obdélník mezi počátkem a koncem (i když se táhlo „pozpátku“).
        public var bounds: NormalizedRect {
            NormalizedRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }

    // MARK: Vykreslení

    public static func render(_ annotations: [Annotation], onto image: CGImage) throws -> CGImage {
        guard !annotations.isEmpty else { return image }
        // Pixelizace jde přes Core Image dřív, vektorové tvary se kreslí nad ni.
        let pixelated = annotations.filter { $0.kind == .pixelate }.map {
            ImageRedact.Region(rect: $0.bounds, kind: .manual)
        }
        let base = try ImageRedact.apply(pixelated, style: .pixelate, to: image)

        let width = base.width
        let height = base.height
        let context = try ImageBackend.makeContext(width: width, height: height, like: base)
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Souřadnice vlevo nahoře (jako ve formuláři a editoru).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let side = Double(min(width, height))
        func point(_ p: Point) -> CGPoint { CGPoint(x: p.x * Double(width), y: p.y * Double(height)) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        for annotation in annotations {
            let lineWidth = max(1, annotation.strokeWidth * side)
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let start = point(annotation.start)
            let end = point(annotation.end)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))

            switch annotation.kind {
            case .line:
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            case .arrow:
                drawArrow(context, from: start, to: end, lineWidth: lineWidth)
            case .rectangle:
                if annotation.filled { context.fill(rect) } else { context.stroke(rect) }
            case .ellipse:
                if annotation.filled { context.fillEllipse(in: rect) } else { context.strokeEllipse(in: rect) }
            case .highlight:
                context.setFillColor(CGColor(srgbRed: annotation.color.r, green: annotation.color.g, blue: annotation.color.b,
                                             alpha: min(annotation.color.a, 0.4)))
                context.fill(rect)
            case .pen:
                guard let first = annotation.points.first else { continue }
                context.move(to: point(first))
                for p in annotation.points.dropFirst() { context.addLine(to: point(p)) }
                context.strokePath()
            case .text:
                drawText(annotation.text, at: start, color: annotation.color, fontSize: max(10, annotation.strokeWidth * side * 6),
                         in: context)
            case .number:
                drawNumber(annotation.text, center: start, color: annotation.color, diameter: max(18, annotation.strokeWidth * side * 7),
                           in: context)
            case .pixelate:
                break // už hotovo
            }
        }
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("anotace") }
        return result
    }

    private static func drawArrow(_ context: CGContext, from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 1 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = min(max(lineWidth * 4.5, 12), length * 0.6)
        // Dřík končí v patě hlavy, ať nepřečuhuje špička.
        let neck = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
        context.move(to: start)
        context.addLine(to: neck)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
        context.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
        context.closePath()
        context.fillPath()
    }

    private static func drawText(_ text: String, at point: CGPoint, color: RGBA, fontSize: Double, in context: CGContext) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        // Podklad pro čitelnost na libovolné fotce: jasné světlé nebo tmavé pole podle jasu písma.
        let luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
        let padding = fontSize * 0.28
        let box = CGRect(x: point.x - padding, y: point.y - padding, width: size.width + 2 * padding, height: size.height + 2 * padding)
        context.setFillColor(luminance > 0.55 ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.7))
        context.addPath(CGPath(roundedRect: box, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        string.draw(at: point)
    }

    private static func drawNumber(_ text: String, center: CGPoint, color: RGBA, diameter: Double, in context: CGContext) {
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(max(1.5, diameter * 0.06))
        context.strokeEllipse(in: circle.insetBy(dx: diameter * 0.03, dy: diameter * 0.03))
        let font = NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = string.size()
        string.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // MARK: Nástroj

    public static let tool = Tool(
        id: "image.tool.annotate", title: "Anotace", symbol: "pencil.tip.crop.circle", editor: .annotate,
        accepts: { $0.count == 1 && $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            let annotations = context.decoded([Annotation].self, "annotations") ?? []
            return PreviewResult(image: try render(annotations, onto: image))
        },
        run: { context in
            guard let annotations = context.decoded([Annotation].self, "annotations"), !annotations.isEmpty else {
                throw ConvertError.unsupportedInput("žádné anotace – nakresli aspoň jednu")
            }
            return try await EachImage.run(context, tag: "anotace", outputExtension: EachImage.keepExtension) { source, output, progress in
                let format = ImageBackend.keepFormat(for: source)
                let result = try render(annotations, onto: try ImageBackend.load(source))
                progress(0.8)
                let properties = ImageBackend.carriedProperties(of: source, stripping: false)
                try ImageBackend.encode(result, as: format, quality: ImageBackend.isLossy(format) ? 0.92 : nil,
                                        properties: properties).write(to: output)
                progress(1)
            }
        }
    )
}
