import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ConvertKit

extension Fixtures {
    struct Pixel: Equatable {
        let r: Int, g: Int, b: Int, a: Int
        var isRedish: Bool { r > 200 && g < 120 && b < 120 }
        var isBluish: Bool { b > 200 && r < 120 && g < 120 }
        var isDark: Bool { r < 30 && g < 30 && b < 30 && a > 200 }
    }

    /// Barva pixelu (0,0 vlevo nahoře), v sRGB.
    static func sample(_ image: CGImage, x: Int, y: Int) -> Pixel {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let a = Int(data[3])
        // Zpět z premultiplied.
        func unpremultiply(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int(v) * 255 / a) }
        return Pixel(r: unpremultiply(data[0]), g: unpremultiply(data[1]), b: unpremultiply(data[2]), a: a)
    }

    static func mean(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let small = try! ImageBackend.resized(image, maxPixel: 16)
        var r = 0.0, g = 0.0, b = 0.0
        var count = 0.0
        for y in 0..<small.height { for x in 0..<small.width {
            let p = sample(small, x: x, y: y)
            r += Double(p.r); g += Double(p.g); b += Double(p.b); count += 1
        } }
        return (r / count, g / count, b / count)
    }

    /// Levá polovina červená, pravá modrá.
    static func halves(in dir: URL, name: String = "pulky.png", width: Int = 200, height: Int = 100,
                       properties: [CFString: Any] = [:]) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try write(context.makeImage()!, to: dir.appendingPathComponent(name), properties: properties)
    }

    /// Jednolitě šedý obrázek.
    static func gray(in dir: URL, name: String = "seda.png", width: Int = 100, height: Int = 100) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try write(context.makeImage()!, to: dir.appendingPathComponent(name))
    }

    static func write(_ image: CGImage, to url: URL, properties: [CFString: Any] = [:], quality: Double = 0.95) throws -> URL {
        let type = UTType(filenameExtension: url.pathExtension)!.identifier
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        var props = properties
        if ["jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "zápis \(url.lastPathComponent)")
        return url
    }

    /// Fotka-podobný obraz: tisíce náhodných barevných obdélníků (nedá se moc zkomprimovat).
    static func noisy(in dir: URL, name: String = "foto.jpg", width: Int = 1600, height: Int = 1200,
                      properties: [CFString: Any] = [:]) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<6000 {
            context.setFillColor(CGColor(srgbRed: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                         blue: .random(in: 0...1, using: &generator), alpha: 1))
            let size = CGFloat.random(in: 4...60, using: &generator)
            context.fill(CGRect(x: .random(in: 0...CGFloat(width), using: &generator),
                                y: .random(in: 0...CGFloat(height), using: &generator), width: size, height: size))
        }
        return try write(context.makeImage()!, to: dir.appendingPathComponent(name), properties: properties)
    }

    /// JPEG s autorem, fotoaparátem, GPS, komentářem a orientací.
    static func exifJPEG(in dir: URL, name: String = "exif.jpg", orientation: Int = 1, width: Int = 200, height: Int = 100) throws -> URL {
        try halves(in: dir, name: name, width: width, height: height, properties: [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Ada", kCGImagePropertyTIFFMake: "Acme",
                                             kCGImagePropertyTIFFModel: "X1", kCGImagePropertyTIFFCopyright: "(c) Ada"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "tajne"],
        ])
    }

    /// Velký text na bílém pozadí (pro OCR).
    static func textImage(in dir: URL, text: String, name: String = "text.png") throws -> URL {
        let width = 1800, height = 400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: 40, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return try write(context.makeImage()!, to: dir.appendingPathComponent(name))
    }
}

/// Opakovatelná „náhoda“ – testy nesmí být nestabilní.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
