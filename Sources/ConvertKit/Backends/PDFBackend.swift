import AppKit
import Foundation
import PDFKit

/// PDF přes PDFKit: stránky na obrázky, text, Markdown.
public enum PDFBackend {
    public static let renderDPI: CGFloat = 300

    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConvertError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw ConvertError.unreadable("\(url.lastPathComponent) (zamčené heslem)") }
        return document
    }

    /// Stránky → PNG / JPG ve 300 DPI. Jedna stránka = soubor, víc stránek = složka.
    public static let images: Converter = { job in
        let document = try document(job.source)
        let count = document.pageCount
        guard count > 0 else { throw ConvertError.unreadable(job.source.lastPathComponent) }
        if count == 1, let page = document.page(at: 0) {
            try write(page, to: job.file, format: job.target)
            job.progress(1)
            return job.file
        }
        let folder = try job.folder()
        let base = job.source.deletingPathExtension().lastPathComponent
        let digits = String(count).count
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            try write(page, to: folder.appendingPathComponent("\(base) \(number).\(job.target.ext)"), format: job.target)
            job.progress(Double(index + 1) / Double(count))
        }
        return folder
    }

    /// Vykreslí stránku na bílé pozadí v daném rozlišení.
    public static func render(_ page: PDFPage, dpi: CGFloat = renderDPI) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let points = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = dpi / 72
        let width = Int((points.width * scale).rounded())
        let height = Int((points.height * scale).rounded())
        guard width > 0, height > 0, width * height < 400_000_000,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw ConvertError.writeFailed("stránka \((page.pageRef?.pageNumber ?? 0))") }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConvertError.writeFailed("stránka") }
        return image
    }

    private static func write(_ page: PDFPage, to url: URL, format: Format) throws {
        let image = try render(page)
        let dpi = [kCGImagePropertyDPIWidth: renderDPI, kCGImagePropertyDPIHeight: renderDPI] as [CFString: Any]
        try ImageBackend.write(image, to: url, format: format, properties: dpi)
    }

    /// Text všech stránek, stránky oddělené prázdným řádkem.
    public static let text: Converter = { job in
        let document = try document(job.source)
        var parts: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            parts.append(document.page(at: index)?.string ?? "")
            job.progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        try parts.joined(separator: "\n\n").write(to: job.file, atomically: false, encoding: .utf8)
        return job.file
    }

    /// Markdown: nadpisy podle velikosti písma, odstavce podle mezer mezi řádky.
    public static let markdown: Converter = { job in
        let document = try document(job.source)
        var lines: [StyledLine] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if let page = document.page(at: index) { lines += styledLines(page) }
            job.progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        try MarkdownFromLayout.render(lines).write(to: job.file, atomically: false, encoding: .utf8)
        return job.file
    }

    /// Řádek textu s velikostí písma a tučností (pro odhad nadpisů).
    struct StyledLine {
        let text: String
        let size: CGFloat
        let bold: Bool
        let gapBefore: CGFloat
    }

    static func styledLines(_ page: PDFPage) -> [StyledLine] {
        guard let attributed = page.attributedString else { return [] }
        let string = attributed.string as NSString
        var result: [StyledLine] = []
        var previousBottom: CGFloat?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                previousBottom = nil
                return
            }
            var size: CGFloat = 0
            var bold = true
            attributed.enumerateAttribute(.font, in: range) { value, _, _ in
                guard let font = value as? NSFont else { return }
                size = max(size, font.pointSize)
                if !font.fontDescriptor.symbolicTraits.contains(.bold) { bold = false }
            }
            let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
            let gap = previousBottom.map { max(0, $0 - bounds.maxY) } ?? size
            previousBottom = bounds.minY
            result.append(StyledLine(text: line, size: size, bold: bold, gapBefore: gap))
        }
        return result
    }
}

/// Z řádků s velikostí písma složí Markdown.
enum MarkdownFromLayout {
    static func render(_ lines: [PDFBackend.StyledLine]) -> String {
        guard !lines.isEmpty else { return "" }
        // Tělo textu = velikost písma s nejvíc znaky (medián řádků by u krátkého dokumentu chytil nadpisy).
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[line.size.rounded(), default: 0] += line.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 12
        var output: [String] = []
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty { output.append(paragraph.joined(separator: " ")) }
            paragraph.removeAll()
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let short = text.count < 120
            if short, line.size >= body * 1.6 {
                flush(); output.append("# \(text)")
            } else if short, line.size >= body * 1.25 {
                flush(); output.append("## \(text)")
            } else if short, line.bold, line.size >= body, text.count < 80 {
                flush(); output.append("### \(text)")
            } else if text.hasPrefix("•") || text.hasPrefix("◦") || text.hasPrefix("▪") {
                flush(); output.append("- " + text.dropFirst().trimmingCharacters(in: .whitespaces))
            } else {
                // Velká mezera nad řádkem = nový odstavec.
                if line.gapBefore > body * 0.9 { flush() }
                paragraph.append(text)
            }
        }
        flush()
        return output.joined(separator: "\n\n") + "\n"
    }
}
