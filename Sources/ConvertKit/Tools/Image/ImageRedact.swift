import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Krytí citlivých částí fotek: obličeje a text se najdou lokálně (Vision) a zakryjí barvou,
/// rozmazáním nebo pixelizací. Nic se neodesílá.
public enum ImageRedact {
    public struct Region: Sendable, Codable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable { case face, text, manual }

        public var id: UUID
        public var rect: NormalizedRect
        public var kind: Kind
        /// Co bylo nalezeno (u textu přečtený řetězec) – do seznamu v editoru.
        public var label: String

        public init(id: UUID = UUID(), rect: NormalizedRect, kind: Kind, label: String = "") {
            self.id = id; self.rect = rect; self.kind = kind; self.label = label
        }
    }

    public enum Style: Sendable, Equatable {
        case solid(RGBA)
        case blur
        case pixelate
    }

    public enum TextMode: String, Sendable {
        case off, sensitive, all
    }

    // MARK: Hledání

    /// Najde obličeje a/nebo text. Pracuje na zmenšenině (do 2800 px), takže je to rychlé i u velkých fotek.
    public static func detect(in image: CGImage, faces: Bool, text: TextMode) throws -> [Region] {
        let small = try ImageBackend.resized(image, maxPixel: 2800)
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        if faces { requests.append(faceRequest) }
        let textRequest = VNRecognizeTextRequest()
        if text != .off {
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = false // jména a čísla se nemají „opravovat“
            textRequest.recognitionLanguages = ["cs-CZ", "en-US", "de-DE", "sk-SK"]
            requests.append(textRequest)
        }
        guard !requests.isEmpty else { return [] }
        try VNImageRequestHandler(cgImage: small).perform(requests)

        var regions: [Region] = []
        if faces {
            for face in faceRequest.results ?? [] {
                regions.append(Region(rect: topLeft(face.boundingBox, grow: 0.18), kind: .face, label: "Obličej"))
            }
        }
        if text != .off {
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                if text == .all {
                    regions.append(Region(rect: topLeft(observation.boundingBox, grow: 0.12), kind: .text, label: candidate.string))
                    continue
                }
                for range in sensitiveRanges(in: candidate.string) {
                    guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    regions.append(Region(rect: topLeft(box, grow: 0.12), kind: .text, label: String(candidate.string[range])))
                }
            }
        }
        // Pořadí čtení: shora dolů, zleva doprava.
        return regions.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
    }

    /// Vision: počátek vlevo dole → editor: vlevo nahoře; obdélník se o `grow` (podíl výšky) zvětší.
    static func topLeft(_ box: CGRect, grow: Double) -> NormalizedRect {
        let dx = Double(box.height) * grow
        let x = max(0, Double(box.minX) - dx)
        let y = max(0, 1 - Double(box.maxY) - Double(box.height) * grow)
        let width = min(1 - x, Double(box.width) + 2 * dx)
        let height = min(1 - y, Double(box.height) * (1 + 2 * grow))
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    /// Citlivé úseky v řádku: e-maily, telefony, odkazy, IBAN, rodná čísla a dlouhé řady číslic (karty, ID).
    public static func sensitiveRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..., in: text)
        let patterns = [
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,           // e-mail
            #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#, // IBAN
            #"\b\d{6}/\d{3,4}\b"#,                                          // rodné číslo
            #"(?<!\d)(?:\d[ \-]?){7,19}\d(?!\d)"#,                          // dlouhé řady číslic (karty, účty, telefony)
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text) { ranges.append(range) }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
                                                   | NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            for match in detector.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text) { ranges.append(range) }
            }
        }
        // Překrývající se úseky sloučit (e-mail je zároveň odkaz).
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: Zakrytí

    public static func apply(_ regions: [Region], style: Style, to image: CGImage) throws -> CGImage {
        guard !regions.isEmpty else { return image }
        let base = CIImage(cgImage: image)
        let size = base.extent.size
        var output = base
        let clamped = base.clampedToExtent()

        for region in regions {
            // Do souřadnic Core Image (počátek vlevo dole).
            let rect = CGRect(x: region.rect.x * size.width, y: (1 - region.rect.y - region.rect.height) * size.height,
                              width: region.rect.width * size.width, height: region.rect.height * size.height)
                .integral.intersection(base.extent)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let covered: CIImage
            switch style {
            case .solid(let color):
                covered = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)).cropped(to: rect)
            case .blur:
                // Rozmazání úměrné velikosti oblasti – i velké písmo zůstane nečitelné.
                covered = clamped.applyingGaussianBlur(sigma: Double(max(min(rect.width, rect.height) * 0.45, 6))).cropped(to: rect)
            case .pixelate:
                let block = max(max(rect.width, rect.height) / 8, 8)
                covered = clamped.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                ]).cropped(to: rect)
            }
            output = covered.composited(over: output)
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ImageAdjust.context.createCGImage(output, from: base.extent, format: .RGBA8, colorSpace: space) else {
            throw ConvertError.writeFailed("krytí")
        }
        return result
    }

    // MARK: Nástroj

    static let options: [ToolOption] = [
        .toggle("faces", "Obličeje", default: true),
        .choice("text", "Text", [.init("off", "Nekrýt"), .init("sensitive", "Jen citlivý (e-maily, čísla, telefony)"),
                                 .init("all", "Veškerý text")], default: "sensitive"),
        .choice("style", "Zakrýt", [.init("solid", "Plnou barvou"), .init("pixelate", "Pixelizací"), .init("blur", "Rozmazáním")],
                default: "solid", help: "Plná barva a pixelizace jsou nevratné; rozmazání jen u malých oblastí."),
        .color("color", "Barva", default: .black, visibleWhen: .init("style", "solid")),
    ]

    static func style(from context: OperationContext) -> Style {
        switch context.string("style") {
        case "blur": .blur
        case "pixelate": .pixelate
        default: .solid(context.color("color") ?? .black)
        }
    }

    static func textMode(from context: OperationContext) -> TextMode {
        TextMode(rawValue: context.string("text") ?? "") ?? .sensitive
    }

    public static let tool = Tool(
        id: "image.tool.redact", title: "Krytí", symbol: "eye.slash", options: options, editor: .redact,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            let regions: [Region]
            if let manual = context.decoded([Region].self, "regions") {
                regions = manual
            } else {
                regions = try detect(in: image, faces: context.bool("faces") ?? true, text: textMode(from: context))
            }
            return PreviewResult(image: try apply(regions, style: style(from: context), to: image),
                                 caption: regions.isEmpty ? "Nic k zakrytí nenalezeno" : "Zakryto: \(regions.count)")
        },
        run: { context in
            let style = style(from: context)
            let manual = context.selection.count == 1 ? context.decoded([Region].self, "regions") : nil
            return try await EachImage.run(context, tag: "kryto", outputExtension: EachImage.keepExtension) { source, output, progress in
                let format = ImageBackend.keepFormat(for: source)
                let image = try ImageBackend.load(source)
                progress(0.2)
                let regions: [Region]
                if let manual { regions = manual } else {
                    regions = try detect(in: image, faces: context.bool("faces") ?? true, text: textMode(from: context))
                }
                guard !regions.isEmpty else { throw ConvertError.unsupportedInput("\(source.lastPathComponent) – nic k zakrytí nenalezeno") }
                progress(0.6)
                // Metadata (poloha, autor) se z krytého obrázku odstraní – je to smysl krytí.
                let result = try apply(regions, style: style, to: image)
                let properties = ImageBackend.carriedProperties(of: source, stripping: true)
                try ImageBackend.encode(result, as: format, quality: ImageBackend.isLossy(format) ? 0.92 : nil,
                                        properties: properties).write(to: output)
                progress(1)
            }
        }
    )
}
