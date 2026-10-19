import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Společné pomůcky obrázkových nástrojů.
extension ImageBackend {
    static let writableFormats: [Format] = [.png, .jpg, .heic, .tiff, .bmp, .gif, .webp, .avif]

    /// Formát podle přípony; `nil`, když ho nepoznáme.
    public static func format(forExtension ext: String) -> Format? {
        writableFormats.first { $0.matches(ext) }
    }

    /// Formát výsledku, který zachová originál: stejný, když ho umíme zapsat, jinak PNG (bez ztráty).
    public static func keepFormat(for url: URL) -> Format {
        if let format = format(forExtension: url.pathExtension), canWrite(format) { return format }
        return .png
    }

    public static func isLossy(_ format: Format) -> Bool {
        ["jpg", "heic", "webp", "avif"].contains(format.id)
    }

    public static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Rozměry a kontext

    /// Rozměry v pixelech bez dekódování.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard url.pathExtension.lowercased() != "svg",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Orientace 5–8 prohazuje strany.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// 8bitový RGBA kontext v barevném prostoru obrázku (zachová P3 z iPhonu); jinak sRGB.
    public static func makeContext(width: Int, height: Int, like image: CGImage? = nil, opaque: Bool = false) throws -> CGContext {
        let space: CGColorSpace
        if let candidate = image?.colorSpace, candidate.model == .rgb, candidate.supportsOutput {
            space = candidate
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard width > 0, height > 0, width * height <= 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else {
            throw ConvertError.writeFailed("obrázek \(width)×\(height)")
        }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        return context
    }

    /// Zmenšený obrázek (nikdy nezvětšuje). `maxPixel` = delší strana.
    public static func resized(_ image: CGImage, maxPixel: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard maxPixel > 0, longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try makeContext(width: width, height: height, like: image)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("obrázek") }
        return result
    }

    /// Obrázek zmenšený rovnou při čtení (rychlé náhledy velkých fotek).
    public static func previewImage(at url: URL, maxPixel: Int) throws -> CGImage {
        try image(at: url, maxPixel: maxPixel)
    }

    // MARK: Kódování a metadata

    /// Vlastnosti ke zkopírování do nového souboru: EXIF, GPS, IPTC, TIFF, DPI. Orientace je 1
    /// (pixely jsou už otočené); rozměry se nekopírují.
    public static func carriedProperties(of url: URL, stripping: Bool) -> [CFString: Any] {
        guard let source = try? source(for: url),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [CFString: Any] = [:]
        if let dpi = all[kCGImagePropertyDPIWidth] { result[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = all[kCGImagePropertyDPIHeight] { result[kCGImagePropertyDPIHeight] = dpi }
        result[kCGImagePropertyOrientation] = 1
        guard !stripping else { return result }
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary] {
            guard var dictionary = all[key] as? [CFString: Any] else { continue }
            if key == kCGImagePropertyExifDictionary {
                dictionary[kCGImagePropertyExifPixelXDimension] = nil
                dictionary[kCGImagePropertyExifPixelYDimension] = nil
            }
            if key == kCGImagePropertyTIFFDictionary { dictionary[kCGImagePropertyTIFFOrientation] = 1 }
            result[key] = dictionary
        }
        return result
    }

    /// Zakóduje obrázek do paměti. Formáty bez průhlednosti dostanou bílé pozadí.
    public static func encode(_ image: CGImage, as format: Format, quality: Double? = nil,
                              properties: [CFString: Any] = [:]) throws -> Data {
        guard let type = type(for: format) else { throw ConvertError.unsupportedInput(format.label) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(format.label)
        }
        var props = properties
        if let lossy = quality ?? defaultQuality(for: format) { props[kCGImageDestinationLossyCompressionQuality] = lossy }
        let flat = supportsAlpha(format) ? image : try flattened(image)
        CGImageDestinationAddImage(destination, flat, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.writeFailed(format.label) }
        return data as Data
    }

    /// Má obrázek průhlednost, která se k něčemu hodí?
    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Jednou načtený obrázek jako CIImage-ready CGImage v plném rozlišení (orientace aplikovaná).
    public static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        try image(at: url, maxPixel: maxPixel)
    }
}

/// Zpracování po jednom obrázku z výběru s jednotným pojmenováním, zápisem a průběhem.
enum EachImage {
    /// - Parameter work: dostane zdroj a dočasný cíl; zapíše výsledek (bytes) a vrátí příponu výsledku
    ///   (ta musí odpovídat tomu, co se zapsalo – určuje jméno).
    static func run(
        _ context: OperationContext, tag: String,
        outputExtension: @Sendable (URL) -> String,
        _ work: @Sendable (_ source: URL, _ output: URL, _ progress: @Sendable (Double) -> Void) async throws -> Void
    ) async throws -> [URL] {
        let urls = context.selection.urls
        var results: [URL] = []
        for (index, source) in urls.enumerated() {
            try Task.checkCancellation()
            let share = 1.0 / Double(urls.count)
            let destination = context.output.destination(for: source, tag: tag, extension: outputExtension(source))
            let result = try await OutputPolicy.write(to: destination) { temporary in
                try await work(source, temporary) { value in
                    context.progress((Double(index) + min(max(value, 0), 1)) * share)
                }
            }
            results.append(result)
            context.progress(Double(index + 1) * share)
        }
        return results
    }

    @Sendable static func keepExtension(_ url: URL) -> String { ImageBackend.keepFormat(for: url).ext }
}

extension Selection {
    /// Samé obrázky (a aspoň jeden).
    var allImages: Bool { !isEmpty && kinds.allSatisfy { $0 == .image } }
}
