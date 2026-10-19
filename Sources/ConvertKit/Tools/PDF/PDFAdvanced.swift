import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

// MARK: - Krytí textu

/// Trvalé začernění textu v PDF. Stránka se zakrytým textem se převede na obrázek, takže
/// pod černými obdélníky nezůstane žádný text, který by šel zkopírovat.
public enum PDFRedactText {
    static let options: [ToolOption] = [
        .text("terms", "Hledané texty", placeholder: "Novák, 12345", help: "Oddělené čárkou; nerozlišuje velikost písmen."),
        .toggle("sensitive", "Citlivé údaje (e-maily, telefony, IBAN, čísla karet)", default: true),
        .color("color", "Barva", default: .black),
    ]

    /// Obdélníky ke krytí na stránce (v bodech stránky).
    static func rects(on page: PDFPage, terms: [String], sensitive: Bool) -> [CGRect] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let nsText = text as NSString
        var ranges: [NSRange] = []
        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let found = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                searchRange = NSRange(location: found.upperBound, length: nsText.length - found.upperBound)
            }
        }
        if sensitive {
            for range in ImageRedact.sensitiveRanges(in: text) { ranges.append(NSRange(range, in: text)) }
        }
        var result: [CGRect] = []
        for range in ranges {
            // Výběr se dělí po řádcích – každý řádek má vlastní obdélník.
            for line in page.selection(for: range)?.selectionsByLine() ?? [] {
                let bounds = line.bounds(for: page)
                if !bounds.isEmpty { result.append(bounds.insetBy(dx: -1.5, dy: -1.5)) }
            }
        }
        return result
    }

    public static let tool = Tool(
        id: "pdf.tool.redact", title: "Krytí", symbol: "eye.slash", options: options,
        accepts: { $0.allPDFs },
        run: { context in
            let terms = (context.string("terms") ?? "").split(separator: ",").map { String($0).trimmed }
            let sensitive = context.bool("sensitive") ?? false
            let color = context.color("color") ?? .black
            guard !terms.isEmpty || sensitive else { throw ConvertError.unsupportedInput("zadej hledaný text nebo zapni citlivé údaje") }
            return try await PDFTools.each(context, tag: "kryto") { document, source, output, progress in
                let result = PDFDocument()
                var covered = 0
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { continue }
                    let found = rects(on: page, terms: terms, sensitive: sensitive)
                    if found.isEmpty, let copy = page.copy() as? PDFPage {
                        result.insert(copy, at: result.pageCount)
                    } else {
                        result.insert(try rasterized(page, covering: found, color: color), at: result.pageCount)
                        covered += found.count
                    }
                    progress(Double(index + 1) / Double(document.pageCount))
                }
                guard covered > 0 else { throw ConvertError.unsupportedInput("\(source.lastPathComponent) – nic k zakrytí nenalezeno") }
                guard result.write(to: output) else { throw ConvertError.writeFailed(output.lastPathComponent) }
            }
        }
    )

    /// Stránka jako obrázek (200 dpi) s černými obdélníky; velikost stránky v bodech zůstává.
    static func rasterized(_ page: PDFPage, covering rects: [CGRect], color: RGBA) throws -> PDFPage {
        let bounds = page.bounds(for: .cropBox)
        let dpi: CGFloat = 200
        let scale = dpi / 72
        let rotated = page.rotation % 180 != 0
        let width = Int(((rotated ? bounds.height : bounds.width) * scale).rounded())
        let height = Int(((rotated ? bounds.width : bounds.height) * scale).rounded())
        let context = try ImageBackend.makeContext(width: width, height: height, opaque: true)
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // Stejná cesta jako zobrazení stránky: otočení a ořez se aplikují transformací.
        if let reference = page.pageRef {
            context.concatenate(reference.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
                                                              rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(reference)
        }
        context.setFillColor(color.cgColor)
        for rect in rects {
            // Obdélníky jsou v souřadnicích stránky; po transformaci výše je převedeme stejnou cestou.
            let mapped = rect.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            context.fill(rotated ? mapped : mapped)
        }
        guard let image = context.makeImage() else { throw ConvertError.writeFailed("stránka") }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        guard let new = PDFPage(image: nsImage, options: [
            .mediaBox: NSValue(rect: CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)),
            .compressionQuality: 0.9,
        ]) else { throw ConvertError.writeFailed("stránka") }
        return new
    }
}

// MARK: - Obrázky z PDF

/// Vytáhne vložené obrázky (JPEG beze změny, ostatní jako PNG).
public enum PDFExtractImages {
    public struct Found: Sendable {
        public let page: Int
        public let index: Int
        public let data: Data
        public let ext: String
    }

    public static func extract(from document: PDFDocument, progress: (Double) -> Void = { _ in }) throws -> (images: [Found], skipped: Int) {
        var images: [Found] = []
        var skipped = 0
        var seen = Set<Int>()
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex)?.pageRef, let dictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { continue }

            let collector = Collector()
            let info = Unmanaged.passUnretained(collector).toOpaque()
            CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
                guard let info else { return true }
                let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream { collector.streams.append(stream) }
                return true
            }, info)

            var index = 0
            for stream in collector.streams {
                guard let streamDictionary = CGPDFStreamGetDictionary(stream) else { continue }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { continue }
                var format = CGPDFDataFormat.raw
                guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { skipped += 1; continue }
                // Stejný obrázek na víc stránkách (loga, pozadí) jen jednou.
                let key = data.count &* 31 &+ data.prefix(64).hashValue
                guard seen.insert(key).inserted else { continue }
                index += 1
                switch format {
                case .jpegEncoded:
                    images.append(Found(page: pageIndex + 1, index: index, data: data, ext: "jpg"))
                case .JPEG2000:
                    images.append(Found(page: pageIndex + 1, index: index, data: data, ext: "jp2"))
                default:
                    if let png = rawToPNG(data, dictionary: streamDictionary) {
                        images.append(Found(page: pageIndex + 1, index: index, data: png, ext: "png"))
                    } else {
                        skipped += 1
                    }
                }
            }
            progress(Double(pageIndex + 1) / Double(document.pageCount))
        }
        return (images, skipped)
    }

    private final class Collector {
        var streams: [CGPDFStreamRef] = []
    }

    /// Nekomprimované pixely (8 bitů, šedá nebo RGB) → PNG.
    private static func rawToPNG(_ data: Data, dictionary: CGPDFDictionaryRef) -> Data? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height) else { return nil }
        CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        guard bits == 8, width > 0, height > 0 else { return nil }

        var components = 0
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceRGB": components = 3
            case "DeviceGray": components = 1
            default: return nil
            }
        } else {
            // [/ICCBased stream] – počet složek je v proudu profilu.
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array,
                  CGPDFArrayGetCount(array) >= 2 else { return nil }
            var first: UnsafePointer<CChar>?
            var profile: CGPDFStreamRef?
            guard CGPDFArrayGetName(array, 0, &first), let first, String(cString: first) == "ICCBased",
                  CGPDFArrayGetStream(array, 1, &profile), let profile, let profileDictionary = CGPDFStreamGetDictionary(profile) else { return nil }
            var n: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(profileDictionary, "N", &n), n == 1 || n == 3 else { return nil }
            components = Int(n)
        }
        guard data.count >= Int(width) * Int(height) * components,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        guard let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * components,
                                  bytesPerRow: Int(width) * components, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return try? ImageBackend.encode(image, as: .png)
    }

    public static let tool = Tool(
        id: "pdf.tool.images", title: "Obrázky", symbol: "photo.on.rectangle.angled",
        accepts: { $0.allPDFs },
        run: { context in
            var results: [URL] = []
            for source in context.selection.urls {
                let document = try PDFBackend.document(source)
                let found = try extract(from: document) { context.progress($0 * 0.8) }
                guard !found.images.isEmpty else {
                    throw ConvertError.unsupportedInput("\(source.lastPathComponent) – žádné vložené obrázky (\(found.skipped) nepodporovaných)")
                }
                let base = source.deletingPathExtension().lastPathComponent
                let folder = OutputPolicy.unique(context.output.directory(for: source).appendingPathComponent("\(base) (obrázky)", isDirectory: true))
                results.append(try await OutputPolicy.write(to: folder) { temporary in
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    for image in found.images {
                        try image.data.write(to: temporary.appendingPathComponent("strana \(image.page) – \(image.index).\(image.ext)"))
                    }
                })
            }
            context.progress(1)
            return results
        }
    )
}

// MARK: - OCR

/// Z naskenovaného PDF udělá prohledávatelné: obraz zůstane, nad něj přibude neviditelná textová vrstva.
public enum PDFOCR {
    static let options: [ToolOption] = [
        .choice("languages", "Jazyk", [.init("cs-CZ,en-US", "Čeština + angličtina"), .init("en-US", "Angličtina"),
                                       .init("de-DE,en-US", "Němčina + angličtina"), .init("sk-SK,cs-CZ,en-US", "Slovenština + čeština")],
                default: "cs-CZ,en-US"),
    ]

    public static let tool = Tool(
        id: "pdf.tool.ocr", title: "OCR", symbol: "text.viewfinder", options: options,
        accepts: { $0.allPDFs },
        run: { context in
            let languages = (context.string("languages") ?? "cs-CZ,en-US").split(separator: ",").map(String.init)
            return try await PDFTools.each(context, tag: "OCR") { document, _, output, progress in
                try PDFTools.rewrite(document, to: output, progress: progress) { pdf, page, rect, _ in
                    try addTextLayer(to: pdf, page: page, rect: rect, languages: languages)
                }
            }
        }
    )

    static func addTextLayer(to context: CGContext, page: PDFPage, rect: CGRect, languages: [String]) throws {
        let image = try PDFBackend.render(page, dpi: 220)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image).perform([request])

        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let box = observation.boundingBox
            let target = CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + box.minY * rect.height,
                                width: box.width * rect.width, height: box.height * rect.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(target.height * 0.85, 4), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.string, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width > 0 else { continue }
            // Text se roztáhne na šířku nalezeného řádku, ať se výběr kryje s obrazem.
            context.textMatrix = CGAffineTransform(scaleX: target.width / CGFloat(width), y: 1)
            context.textPosition = CGPoint(x: target.minX, y: target.minY + target.height * 0.2)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

// MARK: - Stránky

/// Úprava stránek: řazení, otáčení, mazání a duplikace. Pořadí a obsah určuje seznam `PageSpec`.
public enum PDFPages {
    public struct PageSpec: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        /// Stránka zdroje (od 0).
        public var source: Int
        /// Otočení navíc po směru hodinových ručiček (0, 90, 180, 270).
        public var rotation: Int

        public init(id: UUID = UUID(), source: Int, rotation: Int = 0) {
            self.id = id; self.source = source; self.rotation = ((rotation % 360) + 360) % 360
        }
    }

    public static func apply(_ specs: [PageSpec], to document: PDFDocument, output: URL) throws {
        guard !specs.isEmpty else { throw ConvertError.unsupportedInput("v dokumentu nezbyla žádná stránka") }
        let result = PDFDocument()
        for spec in specs {
            guard let page = document.page(at: spec.source)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + spec.rotation) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.write(to: output) else { throw ConvertError.writeFailed(output.lastPathComponent) }
    }

    public static let tool = Tool(
        id: "pdf.tool.pages", title: "Stránky", symbol: "rectangle.grid.2x2", editor: .pages,
        accepts: { $0.count == 1 && $0.allPDFs },
        run: { context in
            guard let specs = context.decoded([PageSpec].self, "pages") else {
                throw ConvertError.unsupportedInput("uprav stránky v okně nástroje")
            }
            return try await PDFTools.each(context, tag: "stránky") { document, _, output, progress in
                try apply(specs, to: document, output: output)
                progress(1)
            }
        }
    )
}
