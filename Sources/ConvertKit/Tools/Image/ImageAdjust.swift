import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Úpravy fotek: expozice, barvy, detail, efekty a otočení. Vše přes Core Image (GPU).
public enum ImageAdjust {
    public struct Adjustments: Sendable, Equatable {
        public var autoEnhance = false
        public var exposure = 0.0       // EV, −2…2
        public var highlights = 0.0     // −1…0 (0 = beze změny, −1 = největší stažení světel)
        public var shadows = 0.0        // −1…1
        public var contrast = 1.0       // 0,5…1,5
        public var brightness = 0.0     // −0,5…0,5
        public var saturation = 1.0     // 0…2
        public var vibrance = 0.0       // −1…1
        public var temperature = 0.0    // −1 (chladnější) … 1 (teplejší)
        public var tint = 0.0           // −1 (zelenější) … 1 (purpurovější)
        public var sharpness = 0.0      // 0…1
        public var noiseReduction = 0.0 // 0…1
        public var vignette = 0.0       // 0…1
        public var filter = Filter.none
        public var rotation = 0         // 0, 90, 180, 270 po směru hodinových ručiček
        public var flipHorizontal = false
        public var flipVertical = false

        public init() {}

        public var isIdentity: Bool { self == Adjustments() }
    }

    public enum Filter: String, Sendable, CaseIterable {
        case none, mono, noir, tonal, chrome, fade, instant, process, transfer, sepia

        public var title: String {
            switch self {
            case .none: "Žádný"
            case .mono: "Mono"
            case .noir: "Noir"
            case .tonal: "Tonální"
            case .chrome: "Chrome"
            case .fade: "Fade"
            case .instant: "Instant"
            case .process: "Process"
            case .transfer: "Transfer"
            case .sepia: "Sépie"
            }
        }
    }

    /// Jeden sdílený kontext (vytvoření je drahé; používá GPU).
    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Zpracování

    public static func apply(_ adjustments: Adjustments, to image: CGImage) throws -> CGImage {
        guard !adjustments.isIdentity else { return image }
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if adjustments.autoEnhance {
            for filter in ci.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(ci, forKey: kCIInputImageKey)
                ci = filter.outputImage ?? ci
            }
        }
        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = ci
            filter.ev = Float(adjustments.exposure)
            ci = filter.outputImage ?? ci
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = ci
            filter.highlightAmount = Float(1 + min(max(adjustments.highlights, -1), 0))
            filter.shadowAmount = Float(adjustments.shadows)
            ci = filter.outputImage ?? ci
        }
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = ci
            filter.neutral = CIVector(x: 6500, y: 0)
            // Nižší cílová teplota = teplejší (oranžovější) výsledek.
            filter.targetNeutral = CIVector(x: 6500 - CGFloat(adjustments.temperature) * 2500,
                                            y: CGFloat(adjustments.tint) * 100)
            ci = filter.outputImage ?? ci
        }
        if adjustments.contrast != 1 || adjustments.saturation != 1 || adjustments.brightness != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = ci
            filter.contrast = Float(adjustments.contrast)
            filter.saturation = Float(adjustments.saturation)
            filter.brightness = Float(adjustments.brightness)
            ci = filter.outputImage ?? ci
        }
        if adjustments.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = ci
            filter.amount = Float(adjustments.vibrance)
            ci = filter.outputImage ?? ci
        }
        ci = applyFilter(adjustments.filter, to: ci)
        if adjustments.noiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = ci
            filter.noiseLevel = Float(adjustments.noiseReduction) * 0.04
            filter.sharpness = 0.4
            ci = filter.outputImage ?? ci
        }
        if adjustments.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = ci
            filter.sharpness = Float(adjustments.sharpness) * 1.6
            filter.radius = Float(max(extent.width, extent.height) / 1500 + 1)
            ci = filter.outputImage ?? ci
        }
        if adjustments.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = ci
            filter.intensity = Float(adjustments.vignette) * 1.5
            filter.radius = Float(max(extent.width, extent.height) / 700)
            ci = filter.outputImage ?? ci
        }

        // Otočení a převrácení (po směru hodinových ručiček; CIImage má y nahoru).
        if adjustments.flipHorizontal { ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if adjustments.flipVertical { ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)) }
        switch ((adjustments.rotation % 360) + 360) % 360 {
        case 90: ci = ci.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        case 180: ci = ci.transformed(by: CGAffineTransform(rotationAngle: .pi))
        case 270: ci = ci.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        default: break
        }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))

        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let output = CGRect(x: 0, y: 0, width: ci.extent.width.rounded(), height: ci.extent.height.rounded())
        guard let result = context.createCGImage(ci, from: output, format: .RGBA8, colorSpace: space) else {
            throw ConvertError.writeFailed("úprava obrázku")
        }
        return result
    }

    private static func applyFilter(_ filter: Filter, to image: CIImage) -> CIImage {
        let effect: CIFilter?
        switch filter {
        case .none: return image
        case .mono: effect = CIFilter.photoEffectMono()
        case .noir: effect = CIFilter.photoEffectNoir()
        case .tonal: effect = CIFilter.photoEffectTonal()
        case .chrome: effect = CIFilter.photoEffectChrome()
        case .fade: effect = CIFilter.photoEffectFade()
        case .instant: effect = CIFilter.photoEffectInstant()
        case .process: effect = CIFilter.photoEffectProcess()
        case .transfer: effect = CIFilter.photoEffectTransfer()
        case .sepia:
            let sepia = CIFilter.sepiaTone()
            sepia.intensity = 0.9
            effect = sepia
        }
        guard let effect else { return image }
        effect.setValue(image, forKey: kCIInputImageKey)
        return effect.outputImage ?? image
    }

    // MARK: Nástroj

    static let options: [ToolOption] = [
        .toggle("auto", "Automatické vylepšení", default: false),
        .slider("exposure", "Expozice", -2...2, default: 0, step: 0.05, unit: " EV"),
        .slider("highlights", "Světla", -1...0, default: 0, step: 0.05),
        .slider("shadows", "Stíny", -1...1, default: 0, step: 0.05),
        .slider("contrast", "Kontrast", 0.5...1.5, default: 1, step: 0.02),
        .slider("brightness", "Jas", -0.5...0.5, default: 0, step: 0.02),
        .slider("saturation", "Sytost", 0...2, default: 1, step: 0.02),
        .slider("vibrance", "Živost", -1...1, default: 0, step: 0.05),
        .slider("temperature", "Teplota", -1...1, default: 0, step: 0.05),
        .slider("tint", "Odstín", -1...1, default: 0, step: 0.05),
        .slider("sharpness", "Ostrost", 0...1, default: 0, step: 0.05),
        .slider("noise", "Redukce šumu", 0...1, default: 0, step: 0.05),
        .slider("vignette", "Viněta", 0...1, default: 0, step: 0.05),
        .choice("filter", "Filtr", Filter.allCases.map { .init($0.rawValue, $0.title) }, default: "none"),
        .choice("rotation", "Otočit", [.init("0", "Neotáčet"), .init("90", "90° vpravo"), .init("180", "180°"), .init("270", "90° vlevo")],
                default: "0"),
        .toggle("flipH", "Převrátit vodorovně", default: false),
        .toggle("flipV", "Převrátit svisle", default: false),
    ]

    static func adjustments(from context: OperationContext) -> Adjustments {
        var value = Adjustments()
        value.autoEnhance = context.bool("auto") ?? false
        value.exposure = context.double("exposure") ?? 0
        value.highlights = context.double("highlights") ?? 0
        value.shadows = context.double("shadows") ?? 0
        value.contrast = context.double("contrast") ?? 1
        value.brightness = context.double("brightness") ?? 0
        value.saturation = context.double("saturation") ?? 1
        value.vibrance = context.double("vibrance") ?? 0
        value.temperature = context.double("temperature") ?? 0
        value.tint = context.double("tint") ?? 0
        value.sharpness = context.double("sharpness") ?? 0
        value.noiseReduction = context.double("noise") ?? 0
        value.vignette = context.double("vignette") ?? 0
        value.filter = Filter(rawValue: context.string("filter") ?? "") ?? .none
        value.rotation = Int(context.string("rotation") ?? "0") ?? 0
        value.flipHorizontal = context.bool("flipH") ?? false
        value.flipVertical = context.bool("flipV") ?? false
        return value
    }

    public static let tool = Tool(
        id: "image.tool.edit", title: "Úpravy", symbol: "slider.horizontal.3", options: options,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            return PreviewResult(image: try apply(adjustments(from: context), to: image))
        },
        run: { context in
            let adjustments = adjustments(from: context)
            guard !adjustments.isIdentity else { throw ConvertError.unsupportedInput("nic k úpravě – posuň některý jezdec") }
            return try await EachImage.run(context, tag: "upraveno", outputExtension: EachImage.keepExtension) { source, output, progress in
                let format = ImageBackend.keepFormat(for: source)
                progress(0.1)
                let result = try apply(adjustments, to: try ImageBackend.load(source))
                progress(0.7)
                let properties = ImageBackend.carriedProperties(of: source, stripping: false)
                try ImageBackend.encode(result, as: format, quality: ImageBackend.isLossy(format) ? 0.92 : nil,
                                        properties: properties).write(to: output)
                progress(1)
            }
        }
    )
}
