import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Obrázky přes ImageIO: zachová orientaci, barevný profil a metadata.
public enum ImageBackend {
    /// Vstupy, které ImageIO (nebo NSImage u SVG) přečte.
    public static let readable: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "avif",
        "ico", "jp2", "psd", "dng", "cr2", "nef", "arw", "svg",
    ]

    /// UTType pro zápis.
    static func type(for format: Format) -> UTType? {
        switch format.id {
        case "png": .png
        case "jpg": .jpeg
        case "heic": .heic
        case "tiff": .tiff
        case "bmp": .bmp
        case "gif": .gif
        case "avif": UTType("public.avif")
        case "webp": .webP
        default: nil
        }
    }

    /// Umí ImageIO tenhle formát zapsat? (AVIF a WebP se liší podle verze systému.)
    public static func canWrite(_ format: Format) -> Bool {
        guard let type = type(for: format) else { return false }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type.identifier)
    }

    /// Převodník pro ImageIO formáty a PDF.
    public static let convert: Converter = { job in
        if job.target == .pdf {
            try writePDF(from: [job.source], to: job.file)
        } else {
            try write(job.source, to: job.file, format: job.target, quality: job.options.quality)
        }
        job.progress(1)
        return job.file
    }

    // MARK: Čtení

    /// Zdroj ImageIO; SVG se nejdřív vykreslí (ImageIO SVG nečte).
    static func source(for url: URL) throws -> CGImageSource {
        if url.pathExtension.lowercased() == "svg" {
            guard let image = rasterizeSVG(url), let data = pngData(image),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ConvertError.unreadable(url.lastPathComponent)
            }
            return source
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        return source
    }

    /// První snímek s aplikovanou EXIF orientací.
    public static func image(at url: URL, maxPixel: Int? = nil) throws -> CGImage {
        let source = try source(for: url)
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel ?? max(width, height, 1)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        return image
    }

    private static func rasterizeSVG(_ url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        // SVG nemá pixely – vykreslit tak, aby delší strana měla aspoň 2048 px.
        let scale = max(2, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Zápis

    /// Zapíše první snímek `source` jako `format`. Metadata (EXIF, GPS, ICC) zůstanou,
    /// u formátů bez průhlednosti se průhledné plochy vyplní bílou.
    public static func write(_ input: URL, to output: URL, format: Format, quality: Double? = nil,
                             stripMetadata: Bool = false) throws {
        guard let type = type(for: format) else { throw ConvertError.unsupportedInput(input.lastPathComponent) }
        let source = try source(for: input)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if stripMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary] {
                properties[key] = nil
            }
        }
        if let lossy = quality ?? defaultQuality(for: format) {
            properties[kCGImageDestinationLossyCompressionQuality] = lossy
        }

        let flatten = !supportsAlpha(format) && hasAlpha(source)
        if flatten || input.pathExtension.lowercased() == "svg" {
            // Vlastní obraz: orientace je už aplikovaná, proto ji v metadatech vynulovat.
            var image = try image(at: input)
            if flatten { image = try flattened(image) }
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            // Bez dekódování do RGBA – zachová hloubku barev, profil i orientaci.
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.writeFailed(output.lastPathComponent) }
    }

    /// Zapíše CGImage (výsledek nástroje) se zvolenou kvalitou.
    public static func write(_ image: CGImage, to output: URL, format: Format, quality: Double? = nil,
                             properties extra: [CFString: Any] = [:]) throws {
        guard let type = type(for: format),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        var properties = extra
        if let lossy = quality ?? defaultQuality(for: format) {
            properties[kCGImageDestinationLossyCompressionQuality] = lossy
        }
        let output2 = supportsAlpha(format) ? image : try flattened(image)
        CGImageDestinationAddImage(destination, output2, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.writeFailed(output.lastPathComponent) }
    }

    /// Obrázky do jednoho PDF: stránka na obrázek, velikost stránky podle rozlišení obrázku.
    public static func writePDF(from inputs: [URL], to output: URL, pageSize: CGSize? = nil, margin: CGFloat = 0) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        for input in inputs {
            try Task.checkCancellation()
            let image = try image(at: input)
            let source = try source(for: input)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
            let natural = CGSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            var box = CGRect(origin: .zero, size: pageSize ?? natural)
            context.beginPage(mediaBox: &box)
            let area = box.insetBy(dx: margin, dy: margin)
            let scale = min(area.width / natural.width, area.height / natural.height, pageSize == nil ? 1 : .greatestFiniteMagnitude)
            let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
            let rect = CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: Pomocné

    static func defaultQuality(for format: Format) -> Double? {
        switch format.id {
        case "jpg": 0.9
        case "heic", "avif", "webp": 0.85
        default: nil
        }
    }

    static func supportsAlpha(_ format: Format) -> Bool {
        !["jpg", "bmp"].contains(format.id)
    }

    static func hasAlpha(_ source: CGImageSource) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// Průhledné plochy → bílá.
    public static func flattened(_ image: CGImage, background: CGColor = .white) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConvertError.writeFailed("obrázek") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("obrázek") }
        return result
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension Dictionary where Key == String, Value == OptionValue {
    /// Kvalita ztrátové komprese 0…1 (z nástroje Komprese).
    var quality: Double? {
        switch self["quality"] {
        case .double(let value): value
        case .int(let value): Double(value) / 100
        default: nil
        }
    }
}
