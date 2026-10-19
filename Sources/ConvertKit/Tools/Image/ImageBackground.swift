import CoreGraphics
import CoreImage
import Foundation

/// Podložení obrázku pozadím: barva, přechod, rozmazaná kopie nebo jiný obrázek;
/// poměr stran, okraj, zaoblení rohů a stín.
public enum ImageBackground {
    public enum Fill: Sendable, Equatable {
        case clear
        case solid(RGBA)
        case gradient(RGBA, RGBA, angle: Double)
        case blurred
        case image(URL)
    }

    public struct Settings: Sendable, Equatable {
        public var fill: Fill = .gradient(RGBA(hex: "#2193b0")!, RGBA(hex: "#6dd5ed")!, angle: 135)
        public var ratio: AspectRatio = .original
        /// Okraj jako podíl kratší strany obrázku (0…0,4).
        public var padding = 0.1
        /// Poloměr zaoblení jako podíl kratší strany obrázku (0…0,25).
        public var cornerRadius = 0.03
        public var shadow = true
        public var maxPixel = 6000

        public init() {}
    }

    /// Dvojice barev přechodů.
    public static let gradients: [(id: String, title: String, from: String, to: String)] = [
        ("ocean", "Oceán", "#2193b0", "#6dd5ed"),
        ("sunset", "Západ slunce", "#ff7e5f", "#feb47b"),
        ("forest", "Les", "#11998e", "#38ef7d"),
        ("grape", "Hrozny", "#7f00ff", "#e100ff"),
        ("graphite", "Grafit", "#232526", "#414345"),
        ("night", "Noc", "#0f2027", "#2c5364"),
    ]

    // MARK: Vykreslení

    public static func render(_ image: CGImage, settings: Settings) throws -> CGImage {
        let content = CGSize(width: image.width, height: image.height)
        let shortSide = min(content.width, content.height)
        let pad = CGFloat(settings.padding) * shortSide

        var canvas = CGSize(width: content.width + 2 * pad, height: content.height + 2 * pad)
        if let ratio = settings.ratio.value {
            // Plátno se jen rozšiřuje, takže okraj nikdy neklesne pod nastavený.
            if Double(canvas.width / canvas.height) < ratio {
                canvas.width = canvas.height * CGFloat(ratio)
            } else {
                canvas.height = canvas.width / CGFloat(ratio)
            }
        }
        // Strop velikosti: vše se úměrně zmenší.
        let scale = min(1, CGFloat(settings.maxPixel) / max(canvas.width, canvas.height))
        canvas = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
        let size = CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
        let frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)

        let context = try ImageBackend.makeContext(width: Int(canvas.width), height: Int(canvas.height), like: image)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        try drawBackground(settings.fill, in: context, rect: canvasRect, content: image)

        let radius = CGFloat(settings.cornerRadius) * min(size.width, size.height)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if settings.shadow {
            let blur = max(canvas.width, canvas.height) * 0.025
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.5), blur: blur, color: CGColor(gray: 0, alpha: 0.4))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: frame)
        context.restoreGState()
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("pozadí") }
        return result
    }

    private static func drawBackground(_ fill: Fill, in context: CGContext, rect: CGRect, content: CGImage) throws {
        switch fill {
        case .clear:
            break
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .gradient(let from, let to, let angle):
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let gradient = CGGradient(colorsSpace: space, colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]) else { return }
            // Úhel jako v CSS: 0° = zdola nahoru, po směru hodinových ručiček; přechod pokrývá celé plátno.
            let radians = angle * .pi / 180
            let direction = CGVector(dx: sin(radians), dy: cos(radians))
            let half = (abs(direction.dx) * rect.width + abs(direction.dy) * rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: center.x - direction.dx * half, y: center.y - direction.dy * half),
                                       end: CGPoint(x: center.x + direction.dx * half, y: center.y + direction.dy * half),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .blurred:
            try drawCover(blurred(content, target: rect.size), in: context, rect: rect)
        case .image(let url):
            try drawCover(try ImageBackend.load(url, maxPixel: Int(max(rect.width, rect.height))), in: context, rect: rect)
        }
    }

    /// Obrázek zvětšený tak, aby vyplnil `rect`, vystředěný a oříznutý.
    static func drawCover(_ image: CGImage, in context: CGContext, rect: CGRect) throws {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
        context.restoreGState()
    }

    /// Silně rozmazaná a lehce ztmavená kopie (poměrně malá – rozmazání se počítá na zmenšenině).
    static func blurred(_ image: CGImage, target: CGSize) throws -> CGImage {
        let small = try ImageBackend.resized(image, maxPixel: 600)
        let ci = CIImage(cgImage: small)
        let blur = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(max(small.width, small.height)) / 18)
            .cropped(to: ci.extent)
        let darker = blur.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.15])
        guard let result = ImageAdjust.context.createCGImage(darker, from: ci.extent) else {
            throw ConvertError.writeFailed("pozadí")
        }
        return result
    }

    // MARK: Nástroj

    static let options: [ToolOption] = [
        .choice("fill", "Pozadí", [.init("gradient", "Přechod"), .init("solid", "Barva"), .init("blur", "Rozmazaný obrázek"),
                                   .init("image", "Jiný obrázek"), .init("clear", "Průhledné")], default: "gradient"),
        .choice("gradient", "Přechod", gradients.map { .init($0.id, $0.title) } + [.init("custom", "Vlastní")], default: "ocean",
                visibleWhen: .init("fill", "gradient")),
        .color("color", "Barva", default: RGBA(hex: "#1f2937")!, visibleWhen: .init("fill", "solid")),
        .color("color1", "Od", default: RGBA(hex: "#2193b0")!, visibleWhen: .init("gradient", "custom")),
        .color("color2", "Do", default: RGBA(hex: "#6dd5ed")!, visibleWhen: .init("gradient", "custom")),
        .slider("angle", "Úhel přechodu", 0...360, default: 135, step: 5, unit: "°", visibleWhen: .init("fill", "gradient")),
        .file("image", "Obrázek pozadí", extensions: ["jpg", "jpeg", "png", "heic", "tiff", "webp"], visibleWhen: .init("fill", "image")),
        .choice("ratio", "Poměr stran", AspectRatio.choices(includingOriginal: true), default: AspectRatio.original.rawValue),
        .slider("padding", "Okraj", 0...0.4, default: 0.1, step: 0.01),
        .slider("radius", "Zaoblení rohů", 0...0.25, default: 0.03, step: 0.01),
        .toggle("shadow", "Stín", default: true),
    ]

    static func settings(from context: OperationContext, maxPixel: Int = 6000) -> Settings {
        var settings = Settings()
        settings.maxPixel = maxPixel
        switch context.string("fill") {
        case "solid": settings.fill = .solid(context.color("color") ?? RGBA(hex: "#1f2937")!)
        case "blur": settings.fill = .blurred
        case "clear": settings.fill = .clear
        case "image":
            if let url = context.string("image").flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0) }) ?? context.url("image") {
                settings.fill = .image(url)
            }
        default:
            let angle = context.double("angle") ?? 135
            if context.string("gradient") == "custom" {
                settings.fill = .gradient(context.color("color1") ?? .white, context.color("color2") ?? .black, angle: angle)
            } else if let preset = gradients.first(where: { $0.id == context.string("gradient") }) ?? gradients.first {
                settings.fill = .gradient(RGBA(hex: preset.from)!, RGBA(hex: preset.to)!, angle: angle)
            }
        }
        settings.ratio = AspectRatio(rawValue: context.string("ratio") ?? "") ?? .original
        settings.padding = context.double("padding") ?? 0.1
        settings.cornerRadius = context.double("radius") ?? 0.03
        settings.shadow = context.bool("shadow") ?? true
        return settings
    }

    public static let tool = Tool(
        id: "image.tool.background", title: "Pozadí", symbol: "photo.on.rectangle", options: options,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            return PreviewResult(image: try render(image, settings: settings(from: context, maxPixel: request.maxPixel)))
        },
        run: { context in
            let settings = settings(from: context)
            let transparent = settings.fill == .clear
            return try await EachImage.run(
                context, tag: "pozadí",
                outputExtension: { transparent ? "png" : EachImage.keepExtension($0) }
            ) { source, output, progress in
                let format = transparent ? Format.png : ImageBackend.keepFormat(for: source)
                progress(0.1)
                let result = try render(try ImageBackend.load(source), settings: settings)
                progress(0.8)
                let properties = ImageBackend.carriedProperties(of: source, stripping: false)
                try ImageBackend.encode(result, as: format, quality: ImageBackend.isLossy(format) ? 0.92 : nil,
                                        properties: properties).write(to: output)
                progress(1)
            }
        }
    )
}
