import CoreGraphics
import Foundation

/// Poměry stran sdílené ořezem a pozadím.
public enum AspectRatio: String, Sendable, CaseIterable {
    case original, square, r4x3, r3x4, r3x2, r2x3, r16x9, r9x16, r21x9, r5x4, r4x5

    public var title: String {
        switch self {
        case .original: "Původní"
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .r21x9: "21:9"
        case .r5x4: "5:4"
        case .r4x5: "4:5"
        }
    }

    /// Šířka ÷ výška; `nil` u původního.
    public var value: Double? {
        switch self {
        case .original: nil
        case .square: 1
        case .r4x3: 4.0 / 3
        case .r3x4: 3.0 / 4
        case .r3x2: 3.0 / 2
        case .r2x3: 2.0 / 3
        case .r16x9: 16.0 / 9
        case .r9x16: 9.0 / 16
        case .r21x9: 21.0 / 9
        case .r5x4: 5.0 / 4
        case .r4x5: 4.0 / 5
        }
    }

    /// Volby do formuláře; „Původní“ jen tam, kde dává smysl (pozadí), ne u ořezu.
    public static func choices(includingOriginal: Bool) -> [ToolOption.Choice] {
        allCases.filter { includingOriginal || $0 != .original }.map { .init($0.rawValue, $0.title) }
    }
}

/// Obdélník v normalizovaných souřadnicích (0…1), počátek vlevo nahoře – stejně jako v okně editoru.
public struct NormalizedRect: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// Do pixelů obrázku, zaokrouhleno a oříznuto na hranice.
    public func pixels(in size: CGSize) -> CGRect {
        let rect = CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
            .integral
        return rect.intersection(CGRect(origin: .zero, size: size))
    }
}

/// Ořez obrázků: poměr stran, přesné rozměry, nebo ručně zvolený rámeček z editoru.
public enum ImageCrop {
    public enum Spec: Sendable, Equatable {
        /// Největší výřez daného poměru, vystředěný (`anchorX/Y` 0…1 posouvá výřez).
        case aspect(Double, anchorX: Double, anchorY: Double)
        /// Pevný rámeček z editoru.
        case rect(NormalizedRect)
        /// Přesné rozměry: obrázek se zvětší/zmenší tak, aby je vyplnil, a vystředěně ořízne.
        case dimensions(width: Int, height: Int)
    }

    /// Výřez v pixelech zdroje a velikost výsledku (liší se jen u přesných rozměrů).
    public static func plan(for size: CGSize, spec: Spec) throws -> (rect: CGRect, output: CGSize) {
        let rect: CGRect
        var output: CGSize?
        switch spec {
        case .rect(let normalized):
            rect = normalized.pixels(in: size)
        case .aspect(let ratio, let anchorX, let anchorY):
            rect = aspectRect(in: size, ratio: ratio, anchorX: anchorX, anchorY: anchorY)
        case .dimensions(let width, let height):
            guard width > 0, height > 0 else { throw ConvertError.writeFailed("ořez") }
            rect = aspectRect(in: size, ratio: Double(width) / Double(height), anchorX: 0.5, anchorY: 0.5)
            output = CGSize(width: width, height: height)
        }
        guard rect.width >= 1, rect.height >= 1 else { throw ConvertError.writeFailed("ořez") }
        return (rect, output ?? rect.size)
    }

    public static func crop(_ image: CGImage, spec: Spec) throws -> CGImage {
        let plan = try plan(for: CGSize(width: image.width, height: image.height), spec: spec)
        guard let cropped = image.cropping(to: plan.rect) else { throw ConvertError.writeFailed("ořez") }
        if Int(plan.output.width) == cropped.width, Int(plan.output.height) == cropped.height { return cropped }
        // Přesné rozměry: výřez správného poměru se zvětší / zmenší.
        let context = try ImageBackend.makeContext(width: Int(plan.output.width), height: Int(plan.output.height), like: image)
        context.draw(cropped, in: CGRect(origin: .zero, size: plan.output))
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("ořez") }
        return result
    }

    /// Největší výřez poměru `ratio` uvnitř `size`.
    static func aspectRect(in size: CGSize, ratio: Double, anchorX: Double, anchorY: Double) -> CGRect {
        let current = Double(size.width / size.height)
        var width = Double(size.width)
        var height = Double(size.height)
        if current > ratio { width = height * ratio } else { height = width / ratio }
        let x = (Double(size.width) - width) * min(max(anchorX, 0), 1)
        let y = (Double(size.height) - height) * min(max(anchorY, 0), 1)
        return CGRect(x: x, y: y, width: width, height: height).integral
            .intersection(CGRect(origin: .zero, size: size))
    }

    // MARK: Nástroj

    static let options: [ToolOption] = [
        .choice("mode", "Ořez", [.init("aspect", "Podle poměru stran"), .init("dimensions", "Přesné rozměry"),
                                 .init("free", "Vlastní rámeček")], default: "aspect"),
        .choice("ratio", "Poměr stran", AspectRatio.choices(includingOriginal: false), default: AspectRatio.r16x9.rawValue,
                visibleWhen: .init("mode", "aspect")),
        .number("width", "Šířka", 1...20_000, default: 1920, unit: "px", visibleWhen: .init("mode", "dimensions")),
        .number("height", "Výška", 1...20_000, default: 1080, unit: "px", visibleWhen: .init("mode", "dimensions")),
    ]

    static func spec(from context: OperationContext) -> Spec {
        switch context.string("mode") {
        case "dimensions":
            return .dimensions(width: context.int("width") ?? 1920, height: context.int("height") ?? 1080)
        case "free":
            if let rect = context.decoded(NormalizedRect.self, "rect") { return .rect(rect) }
            return .rect(.full)
        default:
            let ratio = AspectRatio(rawValue: context.string("ratio") ?? "")?.value ?? 16.0 / 9
            return .aspect(ratio, anchorX: 0.5, anchorY: 0.5)
        }
    }

    public static let tool = Tool(
        id: "image.tool.crop", title: "Ořez", symbol: "crop", options: options, editor: .crop,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            // Náhled ukazuje celý obrázek (rámeček kreslí editor); do popisku jdou rozměry výsledku.
            let full = ImageBackend.pixelSize(of: request.source) ?? CGSize(width: image.width, height: image.height)
            let result = try plan(for: full, spec: spec(from: context)).output
            return PreviewResult(image: image, caption: "Výsledek \(Int(result.width))×\(Int(result.height)) px")
        },
        run: { context in
            let spec = spec(from: context)
            return try await EachImage.run(context, tag: "ořez", outputExtension: EachImage.keepExtension) { source, output, progress in
                let format = ImageBackend.keepFormat(for: source)
                let cropped = try crop(try ImageBackend.load(source), spec: spec)
                let properties = ImageBackend.carriedProperties(of: source, stripping: false)
                try ImageBackend.encode(cropped, as: format, quality: ImageBackend.isLossy(format) ? 0.92 : nil,
                                        properties: properties).write(to: output)
                progress(1)
            }
        }
    )
}
