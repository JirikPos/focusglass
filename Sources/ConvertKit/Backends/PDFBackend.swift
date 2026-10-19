import AppKit
import Foundation
import PDFKit

/// PDF přes PDFKit: stránky na obrázky, text, Markdown.
public enum PDFBackend {
    public static let renderDPI: CGFloat = 300

    static func document(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConvertError.unreadable(url.lastPathComponent) }
        if document.isLocked {
            guard let password, !password.isEmpty else { throw ConvertError.passwordRequired(url.lastPathComponent) }
            guard document.unlock(withPassword: password) else { throw ConvertError.wrongPassword(url.lastPathComponent) }
        }
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

    /// Markdown, DOCX, EPUB z rozvržení textu (odstavce, nadpisy, odrážky; skeny přes OCR).
    public static let document: Converter = { job in
        let pdf = try document(job.source)
        let pages = try PDFLayout.pages(of: pdf) { job.progress($0 * 0.8) }
        let blocks = PDFLayout.blocks(pages)
        guard !blocks.isEmpty else { throw ConvertError.unreadable("\(job.source.lastPathComponent) (bez textu)") }
        let title = job.source.deletingPathExtension().lastPathComponent
        switch job.target.id {
        case "md":
            try DocumentModel.markdown(blocks).write(to: job.file, atomically: false, encoding: .utf8)
        case "epub":
            let body = DocumentModel.xhtmlBody(blocks)
            try await EPUB.write(title: title, chapters: EPUB.chapters(fromBody: body, fallbackTitle: title),
                                 to: job.file, workDirectory: job.scratch)
        default:
            try await TextBackend.write(DocumentModel.attributed(blocks), title: title, to: job.file,
                                        format: job.target, workDirectory: job.scratch)
        }
        job.progress(1)
        return job.file
    }

    /// Tabulky do XLSX: list na stránku, sloupce podle zarovnání textu.
    public static let spreadsheet: Converter = { job in
        let pdf = try document(job.source)
        let pages = try PDFLayout.pages(of: pdf) { job.progress($0 * 0.8) }
        let sheets = pages.enumerated().map { index, page in
            Spreadsheet.Sheet(name: pages.count == 1 ? "List1" : "Strana \(index + 1)", rows: PDFLayout.table(page))
        }
        try await Spreadsheet.writeXLSX(sheets, to: job.file, workDirectory: job.scratch)
        job.progress(1)
        return job.file
    }

    /// Prezentace: snímek na stránku (obrázek ve 200 DPI, vzhled 1:1).
    public static let presentation: Converter = { job in
        let pdf = try document(job.source)
        guard let first = pdf.page(at: 0) else { throw ConvertError.unreadable(job.source.lastPathComponent) }
        var slides: [PPTX.Slide] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            let image = job.temporary("snimek\(index + 1).jpg")
            try ImageBackend.write(try render(page, dpi: 200), to: image, format: .jpg, quality: 0.88)
            slides.append(PPTX.Slide(image: image))
            job.progress(Double(index + 1) / Double(pdf.pageCount) * 0.9)
        }
        let bounds = first.bounds(for: .cropBox)
        let size = first.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        try await PPTX.write(slides: slides, size: size, to: job.file, workDirectory: job.scratch)
        job.progress(1)
        return job.file
    }
}
