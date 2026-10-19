import AppKit
import Foundation
import PDFKit
import Testing
@testable import ConvertKit

extension Fixtures {
    /// PDF s jednou stránkou 200×100: vlevo červená, vpravo modrá.
    static func colorPDF(in dir: URL, name: String = "barvy.pdf", pages: Int = 1, rotation: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        if rotation != 0 {
            let document = PDFDocument(url: url)!
            for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotation }
            document.write(to: url)
        }
        return url
    }

    /// PDF s velkým fotografickým JPEG na každé stránce (vložený beze změny).
    static func photoPDF(in dir: URL, name: String = "fotky.pdf", pages: Int = 2) throws -> URL {
        let urls = try (0..<pages).map { try noisy(in: dir, name: "p\($0)-\(name).jpg", width: 1800, height: 1200) }
        let url = dir.appendingPathComponent(name)
        try ImageCombine.writePDF(urls, to: url, pageSize: .a4, margin: 20)
        return url
    }
}

@Suite(.serialized) struct PDFToolTests {
    let registry = Catalog.makeRegistry()

    @discardableResult
    private func run(_ id: String, on sources: [URL], options: [String: OptionValue] = [:]) async throws -> [URL] {
        let tool = try #require(registry.operation(id: id) as? Tool, "chybí \(id)")
        let selection = Selection(urls: sources)
        #expect(tool.accepts(selection), "\(id) nepřijme výběr")
        return try await tool.run(OperationContext(selection: selection, options: options))
    }

    // MARK: Kolo

    @Test func wheelForPDF() {
        let ids = registry.operations(for: Selection(urls: [URL(fileURLWithPath: "/a.pdf")]), wheel: .tools).map(\.id)
        #expect(ids == ["pdf.tool.compress", "pdf.tool.pages", "pdf.tool.split", "pdf.tool.password", "pdf.tool.watermark",
                        "pdf.tool.redact", "pdf.tool.images", "pdf.tool.ocr"])
        let two = registry.operations(for: Selection(urls: [URL(fileURLWithPath: "/a.pdf"), URL(fileURLWithPath: "/b.pdf")]), wheel: .tools).map(\.id)
        #expect(two.contains("pdf.tool.merge") && !two.contains("pdf.tool.pages"))
    }

    // MARK: Rozsahy

    @Test func rangeParsing() {
        #expect(PDFTools.parseRanges("1-3, 5, 8-", pageCount: 10) == [1...3, 5...5, 8...10])
        #expect(PDFTools.parseRanges("-2", pageCount: 10) == [1...2])
        #expect(PDFTools.parseRanges("3;1", pageCount: 5) == [3...3, 1...1])
        for bad in ["0", "5-3", "11", "a", "1-2-3", "", "  "] {
            #expect(PDFTools.parseRanges(bad, pageCount: 10) == nil, "„\(bad)“ má být chyba")
        }
    }

    // MARK: Komprese

    @Test func compressShrinksPhotoPDFAndKeepsPages() async throws {
        let dir = try TempDir()
        let source = try Fixtures.photoPDF(in: dir.url)
        let before = ImageBackend.fileSize(source)
        let result = try await run("pdf.tool.compress", on: [source], options: ["preset": .string("small")])[0]
        #expect(ImageBackend.fileSize(result) < before / 2, "\(ImageBackend.fileSize(result)) vs \(before)")
        #expect(PDFDocument(url: result)?.pageCount == 2)
        #expect(result.lastPathComponent == "fotky (komprese).pdf")
        // Vyšší kvalita = větší soubor než nejmenší.
        let high = try await run("pdf.tool.compress", on: [source], options: ["preset": .string("high")])[0]
        #expect(ImageBackend.fileSize(high) > ImageBackend.fileSize(result))
    }

    @Test func compressNeverMakesPDFBigger() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url) // jen text
        let result = try await run("pdf.tool.compress", on: [source])[0]
        #expect(ImageBackend.fileSize(result) <= ImageBackend.fileSize(source))
        #expect(PDFDocument(url: result)?.page(at: 0)?.string?.contains(Fixtures.marker) == true)
    }

    @Test func compressPreviewReportsSize() async throws {
        let dir = try TempDir()
        let source = try Fixtures.photoPDF(in: dir.url)
        let tool = try #require(registry.operation(id: "pdf.tool.compress") as? Tool)
        let preview = try #require(try await tool.preview(PreviewRequest(source: source, options: [:], maxPixel: 600, selection: Selection(urls: [source]))))
        #expect(preview.caption?.contains("→") == true)
        #expect(max(preview.image.width, preview.image.height) == 600)
    }

    // MARK: Sloučení a rozdělení

    @Test func mergeKeepsOrderAndAllPages() async throws {
        let dir = try TempDir()
        let a = try Fixtures.colorPDF(in: dir.url, name: "a.pdf", pages: 2)
        let b = try Fixtures.pdf(in: dir.url, pages: 3)
        let result = try await run("pdf.tool.merge", on: [a, b])[0]
        #expect(result.lastPathComponent == "Sloučeno (2 obrázky).pdf" || result.lastPathComponent.hasPrefix("Sloučeno"))
        let merged = try #require(PDFDocument(url: result))
        #expect(merged.pageCount == 5)
        #expect(merged.page(at: 0)?.string?.isEmpty != false && merged.page(at: 2)?.string?.contains("Nadpis") == true)

        let order = try JSONEncoder().encode([b.path, a.path])
        let swapped = try #require(PDFDocument(url: try await run("pdf.tool.merge", on: [a, b], options: ["order": .data(order)])[0]))
        #expect(swapped.page(at: 0)?.string?.contains("Nadpis") == true)
    }

    @Test func splitModes() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url, pages: 5)
        func files(_ folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }

        let each = try await run("pdf.tool.split", on: [source])[0]
        #expect(try files(each) == ["dokument 1.pdf", "dokument 2.pdf", "dokument 3.pdf", "dokument 4.pdf", "dokument 5.pdf"])
        #expect(each.lastPathComponent == "dokument (rozděleno)")

        let every = try await run("pdf.tool.split", on: [source], options: ["mode": .string("every"), "count": .int(2)])[0]
        #expect(try files(every) == ["dokument 1-2.pdf", "dokument 3-4.pdf", "dokument 5.pdf"])

        let ranges = try await run("pdf.tool.split", on: [source], options: ["mode": .string("ranges"), "ranges": .string("1-2, 4")])[0]
        #expect(try files(ranges) == ["dokument 1-2.pdf", "dokument 4.pdf"])
        #expect(PDFDocument(url: ranges.appendingPathComponent("dokument 1-2.pdf"))?.pageCount == 2)

        let extract = try await run("pdf.tool.split", on: [source], options: ["mode": .string("extract"), "ranges": .string("5, 2-3")])[0]
        let extracted = try #require(PDFDocument(url: extract))
        #expect(extracted.pageCount == 3)
        #expect(extracted.page(at: 0)?.string?.contains("Strana 5") == true, "pořadí podle zadání")
        #expect(extract.pathExtension == "pdf")

        await #expect(throws: ConvertError.self) {
            try await run("pdf.tool.split", on: [source], options: ["mode": .string("ranges"), "ranges": .string("9")])
        }
    }

    // MARK: Heslo

    @Test func passwordRoundTrip() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url)
        let locked = try await run("pdf.tool.password", on: [source], options: [
            "action": .string("set"), "password": .string("tajne"), "confirm": .string("tajne")])[0]
        #expect(locked.lastPathComponent == "dokument (s heslem).pdf")
        let document = try #require(PDFDocument(url: locked))
        #expect(document.isLocked)
        #expect(document.unlock(withPassword: "tajne"))
        #expect(!document.unlock(withPassword: "spatne") || document.isEncrypted)

        let open = try await run("pdf.tool.password", on: [locked], options: ["action": .string("remove"), "password": .string("tajne")])[0]
        let unlocked = try #require(PDFDocument(url: open))
        #expect(!unlocked.isLocked && !unlocked.isEncrypted)
        #expect(unlocked.page(at: 0)?.string?.contains(Fixtures.marker) == true)
    }

    @Test func passwordErrors() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url)
        await #expect(throws: ConvertError.self) {
            try await run("pdf.tool.password", on: [source], options: ["password": .string("a"), "confirm": .string("b")])
        }
        await #expect(throws: ConvertError.self) { try await run("pdf.tool.password", on: [source], options: ["password": .string("")]) }
        let locked = try await run("pdf.tool.password", on: [source], options: ["password": .string("x"), "confirm": .string("x")])[0]
        await #expect(throws: ConvertError.wrongPassword("dokument (s heslem).pdf")) {
            try await run("pdf.tool.password", on: [locked], options: ["action": .string("remove"), "password": .string("y")])
        }
        // Zamčené PDF bez hesla jiné nástroje nepřečtou a řeknou proč.
        await #expect(throws: ConvertError.passwordRequired("dokument (s heslem).pdf")) {
            try await run("pdf.tool.compress", on: [locked])
        }
    }

    // MARK: Vodoznak a přepis

    @Test func watermarkKeepsTextAndDrawsMark() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url, pages: 2)
        let result = try await run("pdf.tool.watermark", on: [source], options: [
            "text": .string("KOPIE"), "opacity": .double(1), "angle": .double(0), "size": .double(60), "color": .color(RGBA(1, 0, 0))])[0]
        let document = try #require(PDFDocument(url: result))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains(Fixtures.marker) == true, "text zůstává textem")
        #expect(document.page(at: 1)?.string?.contains("KOPIE") == true)
        let image = try PDFBackend.render(try #require(document.page(at: 0)), dpi: 72)
        // Uprostřed stránky (100×60 pt) je červený vodoznak.
        var red = 0
        for x in stride(from: 40, to: 160, by: 2) { for y in 20..<80 where Fixtures.sample(image, x: x, y: y).isRedish { red += 1 } }
        #expect(red > 30, "vodoznak je vidět (\(red))")
    }

    @Test func rewriteKeepsRotatedPageOrientation() async throws {
        let dir = try TempDir()
        let source = try Fixtures.colorPDF(in: dir.url, rotation: 90) // 200×100 otočená doprava = 100×200
        let original = try #require(PDFDocument(url: source)?.page(at: 0))
        let before = try PDFBackend.render(original, dpi: 72)
        #expect(before.width == 100 && before.height == 200)
        let result = try await run("pdf.tool.watermark", on: [source], options: ["text": .string("x"), "opacity": .double(0.05)])[0]
        let after = try PDFBackend.render(try #require(PDFDocument(url: result)?.page(at: 0)), dpi: 72)
        #expect(after.width == 100 && after.height == 200)
        // Červená byla vlevo; po otočení o 90° doprava je nahoře.
        #expect(Fixtures.sample(after, x: 50, y: 20).isRedish && Fixtures.sample(after, x: 50, y: 180).isBluish)
        #expect(Fixtures.sample(before, x: 50, y: 20).isRedish)
    }

    // MARK: Krytí textu

    @Test func redactRemovesTextAndPaintsBlack() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url, pages: 2)
        let result = try await run("pdf.tool.redact", on: [source], options: ["terms": .string("nadpis"), "sensitive": .bool(false)])[0]
        let document = try #require(PDFDocument(url: result))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("Nadpis") != true, "text pod černým obdélníkem nesmí zůstat")
        #expect(document.page(at: 0)?.string?.contains(Fixtures.marker) != true, "stránka je rastr – žádný text")
        #expect(document.page(at: 1)?.string?.contains(Fixtures.marker) == true, "nezasažená stránka zůstává textová")
        let image = try PDFBackend.render(try #require(document.page(at: 0)), dpi: 72)
        var dark = 0
        for x in 0..<image.width { for y in 0..<image.height where Fixtures.sample(image, x: x, y: y).isDark { dark += 1 } }
        #expect(dark > 200, "černý obdélník (\(dark))")
    }

    @Test func redactSensitivePatternsAndNothingFound() async throws {
        let dir = try TempDir()
        let page = dir.url.appendingPathComponent("kontakt.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 100)
        let context = CGContext(page as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        "Pište na jan.novak@example.com".draw(at: CGPoint(x: 10, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let result = try await run("pdf.tool.redact", on: [page], options: ["terms": .string(""), "sensitive": .bool(true)])[0]
        #expect(PDFDocument(url: result)?.page(at: 0)?.string?.contains("example.com") != true)
        await #expect(throws: ConvertError.self) {
            try await run("pdf.tool.redact", on: [try Fixtures.colorPDF(in: dir.url)], options: ["terms": .string("neexistuje")])
        }
        await #expect(throws: ConvertError.self) { try await run("pdf.tool.redact", on: [page], options: ["terms": .string(""), "sensitive": .bool(false)]) }
    }

    // MARK: Obrázky

    @Test func extractsEmbeddedJPEGsOnce() async throws {
        let dir = try TempDir()
        let photo = try Fixtures.noisy(in: dir.url, name: "jedna.jpg", width: 1200, height: 800)
        let source = dir.url.appendingPathComponent("dvakrat.pdf")
        try ImageCombine.writePDF([photo, photo], to: source, pageSize: .fit, margin: 0) // stejný obrázek na dvou stranách
        let folder = try await run("pdf.tool.images", on: [source])[0]
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1, "duplicita se vytáhne jednou: \(files)")
        let image = try ImageBackend.load(folder.appendingPathComponent(files[0]))
        #expect(image.width == 1200 && image.height == 800)
        #expect(files[0].hasSuffix(".jpg"))
    }

    @Test func extractsRawPixelsAsPNG() async throws {
        let dir = try TempDir()
        let png = try Fixtures.halves(in: dir.url, name: "raw.png", width: 120, height: 60)
        let source = dir.url.appendingPathComponent("raw.pdf")
        // PNG se do PDF vkládá jako dekomprimované pixely (Flate), ne jako JPEG.
        try ImageCombine.writePDF([png], to: source, pageSize: .fit, margin: 0)
        let found = try PDFExtractImages.extract(from: try #require(PDFDocument(url: source)))
        #expect(found.images.count == 1 && found.skipped == 0, "nalezeno \(found.images.count), přeskočeno \(found.skipped)")
        let image = try #require(found.images.first)
        #expect(image.ext == "png")
        let decoded = try #require(CGImageSourceCreateWithData(image.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 120 && decoded.height == 60)
        #expect(Fixtures.sample(decoded, x: 10, y: 30).isRedish && Fixtures.sample(decoded, x: 110, y: 30).isBluish)
    }

    @Test func noImagesIsExplained() async throws {
        let dir = try TempDir()
        await #expect(throws: ConvertError.self) { try await run("pdf.tool.images", on: [try Fixtures.pdf(in: dir.url)]) }
    }

    // MARK: OCR

    @Test func ocrMakesScanSearchable() async throws {
        let dir = try TempDir()
        let scan = try Fixtures.scannedPDF(in: dir.url)
        #expect(PDFDocument(url: scan)?.page(at: 0)?.string?.isEmpty != false)
        let result = try await run("pdf.tool.ocr", on: [scan])[0]
        let document = try #require(PDFDocument(url: result))
        #expect(document.page(at: 0)?.string?.contains("Faktura") == true, "přepsáno: \(document.page(at: 0)?.string ?? "nil")")
        #expect(document.findString("faktura", withOptions: .caseInsensitive).count == 1, "text jde hledat")
        // Obraz zůstal – stránka stále vypadá jako sken (bílé pozadí, černý text).
        let image = try PDFBackend.render(try #require(document.page(at: 0)), dpi: 72)
        #expect(Fixtures.sample(image, x: 2, y: 2).r > 240)
    }

    // MARK: Stránky

    @Test func pagesReorderRotateDeleteDuplicate() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url, pages: 4)
        let specs: [PDFPages.PageSpec] = [
            .init(source: 3), .init(source: 0, rotation: 90), .init(source: 0), .init(source: 2, rotation: -90),
        ]
        let result = try await run("pdf.tool.pages", on: [source], options: ["pages": .data(try JSONEncoder().encode(specs))])[0]
        let document = try #require(PDFDocument(url: result))
        #expect(document.pageCount == 4)
        #expect(document.page(at: 0)?.string?.contains("Strana 4") == true)
        #expect(document.page(at: 1)?.rotation == 90 && document.page(at: 2)?.rotation == 0)
        #expect(document.page(at: 3)?.rotation == 270)
        #expect(document.page(at: 1)?.string?.contains("Nadpis") == true && document.page(at: 2)?.string?.contains("Nadpis") == true)
        #expect(result.lastPathComponent == "dokument (stránky).pdf")

        await #expect(throws: ConvertError.self) { try await run("pdf.tool.pages", on: [source]) }
        await #expect(throws: ConvertError.self) {
            try await run("pdf.tool.pages", on: [source], options: ["pages": .data(try JSONEncoder().encode([PDFPages.PageSpec]()))])
        }
    }
}
