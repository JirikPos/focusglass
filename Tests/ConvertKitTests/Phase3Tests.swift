import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ConvertKit

private let hasFFmpeg = ToolLocator.shared.isAvailable(.ffmpeg) && ToolLocator.shared.isAvailable(.ffprobe)

/// Volitelné nástroje (ffmpeg, cwebp, avifenc), rozvržení PDF, PPTX a iWork/LibreOffice trasy.
@Suite(.serialized) struct Phase3Tests {
    let registry = Catalog.makeRegistry()

    private func run(_ id: String, on source: URL) async throws -> URL {
        let operation = try #require(registry.operation(id: id), "chybí operace \(id)")
        let selection = Selection(urls: [source])
        #expect(operation.accepts(selection))
        let results = try await operation.run(OperationContext(selection: selection))
        return try #require(results.first)
    }

    // MARK: ffmpeg

    @Test(.enabled(if: hasFFmpeg)) func mp3FromSilentVideoExplainsWhy() async throws {
        let dir = try TempDir()
        let mp4 = try await Fixtures.mp4(in: dir.url)
        await #expect(throws: ConvertError.noAudio("video.mp4")) { _ = try await run("video.convert.mp3", on: mp4) }
    }

    @Test(.enabled(if: hasFFmpeg), arguments: ["mkv", "webm", "avi", "wmv"])
    func videoViaFFmpeg(target: String) async throws {
        let dir = try TempDir()
        let mp4 = try await Fixtures.mp4(in: dir.url)
        let result = try await run("video.convert.\(target)", on: mp4)
        let duration = await FFmpegBackend.probeDuration(result, tools: .shared)
        #expect(duration != nil)
    }

    @Test(.enabled(if: hasFFmpeg)) func mkvToMP4UsesFFmpegRoute() async throws {
        let dir = try TempDir()
        let mkv = try await run("video.convert.mkv", on: try await Fixtures.mp4(in: dir.url))
        let mp4 = try await run("video.convert.mp4", on: mkv)
        let tracks = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test(.enabled(if: hasFFmpeg), arguments: ["mp3", "ogg", "opus", "wma"])
    func audioViaFFmpeg(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("audio.convert.\(target)", on: try Fixtures.wav(in: dir.url))
        let duration = try #require(await FFmpegBackend.probeDuration(result, tools: .shared))
        #expect(abs(duration - 0.5) < 0.15)
    }

    @Test(.enabled(if: hasFFmpeg)) func oggBackToWavViaFFmpeg() async throws {
        let dir = try TempDir()
        let ogg = try await run("audio.convert.ogg", on: try Fixtures.wav(in: dir.url))
        let wav = try await run("audio.convert.wav", on: ogg)
        #expect(try AVAudioFile(forReading: wav).length > 10_000)
    }

    @Test(.enabled(if: hasFFmpeg)) func progressIsReported() async throws {
        let dir = try TempDir()
        let mp4 = try await Fixtures.mp4(in: dir.url)
        let values = LockedArray<Double>()
        let op = try #require(registry.operation(id: "video.convert.webm"))
        _ = try await op.run(OperationContext(selection: Selection(urls: [mp4]), progress: { values.append($0) }))
        #expect(values.values.last == 1)
    }

    @Test func ffmpegMissingGreysOutOnlyFFmpegRoutes() {
        let noTools = ToolLocator(searchPaths: [], environment: ["PATH": ""])
        let mp4 = Selection(urls: [URL(fileURLWithPath: "/a.mp4")])
        let mkv = Selection(urls: [URL(fileURLWithPath: "/a.mkv")])
        let toMP4 = registry.operation(id: "video.convert.mp4")!
        #expect(toMP4.availability(for: mp4, tools: noTools) == .available) // nativně
        #expect(toMP4.availability(for: mkv, tools: noTools) == .missing(hint: "brew install ffmpeg"))
        #expect(registry.operation(id: "video.convert.webm")!.availability(for: mp4, tools: noTools) != .available)
    }

    // MARK: WebP / AVIF

    @Test(.enabled(if: ToolLocator.shared.isAvailable(.cwebp) || ImageBackend.canWrite(.webp)))
    func pngToWebP() async throws {
        let dir = try TempDir()
        let result = try await run("image.convert.webp", on: try Fixtures.png(in: dir.url))
        #expect(try ImageBackend.image(at: result).width == 64)
    }

    @Test(.enabled(if: ToolLocator.shared.isAvailable(.avifenc) || ImageBackend.canWrite(.avif)))
    func pngToAVIF() async throws {
        let dir = try TempDir()
        let result = try await run("image.convert.avif", on: try Fixtures.png(in: dir.url))
        #expect(try ImageBackend.image(at: result).width == 64)
    }

    // MARK: PDF → upravitelné formáty

    @Test func pdfToDOCXKeepsHeadingAndText() async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.docx", on: try Fixtures.pdf(in: dir.url))
        let text = try NSAttributedString(url: result, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil)
        #expect(text.string.contains("Nadpis"))
        #expect(text.string.contains(Fixtures.marker))
        let blocks = DocumentModel.blocks(from: text)
        #expect(blocks.first?.kind == .heading(1))
    }

    @Test func pdfToEPUBAndMarkdown() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url)
        let epub = try await run("pdf.convert.epub", on: source)
        #expect(try await EPUB.readHTML(epub, workDirectory: dir.url).html.contains(Fixtures.marker))
        let markdown = try String(contentsOf: try await run("pdf.convert.md", on: source), encoding: .utf8)
        #expect(markdown.hasPrefix("# Nadpis"))
    }

    @Test func pdfTableToXLSX() async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.xlsx", on: try Fixtures.tablePDF(in: dir.url))
        let rows = try #require(try await Spreadsheet.readXLSX(result).first).rows
        #expect(rows.first == ["Položka", "Počet", "Cena"])
        #expect(rows.contains(["Jablka", "12", "34,50"]))
    }

    @Test func pdfToPPTXHasSlidePerPage() async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.pptx", on: try Fixtures.pdf(in: dir.url))
        let presentation = try #require(try await Zip.read("ppt/presentation.xml", from: result))
        let xml = String(decoding: presentation, as: UTF8.self)
        #expect(xml.components(separatedBy: "<p:sldId ").count - 1 == 2)
        #expect(xml.contains(#"<p:sldSz cx="2540000" cy="1524000"/>"#)) // 200 × 120 pt
        #expect(try await Zip.read("ppt/media/image2.jpg", from: result) != nil)
        // Všechny XML části musí být dobře formované.
        let folder = dir.url.appendingPathComponent("pptx")
        try await Zip.extract(result, to: folder)
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where ["xml", "rels"].contains(file.pathExtension) {
            let parser = XMLParser(contentsOf: file)!
            #expect(parser.parse(), "\(file.lastPathComponent) není platné XML")
        }
    }

    @Test func scannedPDFUsesOCR() async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.txt", on: try Fixtures.scannedPDF(in: dir.url))
        // TXT bere textovou vrstvu – sken žádnou nemá; Markdown použije OCR.
        #expect(try String(contentsOf: result, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let markdown = try String(contentsOf: try await run("pdf.convert.md", on: try Fixtures.scannedPDF(in: dir.url, name: "sken2.pdf")),
                                  encoding: .utf8)
        #expect(markdown.contains("Faktura"))
    }

    // MARK: iWork / LibreOffice

    @Test func appleScriptEscapesPaths() {
        let script = IWorkBackend.script(app: .pages, input: URL(fileURLWithPath: #"/tmp/a "b"\c.docx"#),
                                         output: URL(fileURLWithPath: "/tmp/out.pages"), target: .pages)
        #expect(script.contains(#"POSIX file "/tmp/a \"b\"\\c.docx""#))
        #expect(script.contains(#"save theDoc in (POSIX file "/tmp/out.pages")"#))
        #expect(script.contains("close theDoc saving no"))
    }

    @Test func keynoteImagesScript() {
        let script = IWorkBackend.script(app: .keynote, input: URL(fileURLWithPath: "/tmp/a.pptx"),
                                         output: URL(fileURLWithPath: "/tmp/a (PNG).png"), target: .png)
        #expect(script.contains("as slide images with properties {image format:PNG}"))
    }

    @Test func officeRoutesReportMissingApp() {
        let noTools = ToolLocator(searchPaths: [], environment: ["PATH": ""])
        let pptx = Selection(urls: [URL(fileURLWithPath: "/a.pptx")])
        let toPDF = registry.operation(id: "slides.convert.pdf")!
        #expect(toPDF.accepts(pptx))
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") == nil {
            #expect(toPDF.availability(for: pptx, tools: noTools) == .missing(hint: "Nainstaluj Keynote z App Storu"))
        }
        // Nativní CSV → XLSX nic nepotřebuje.
        let csv = Selection(urls: [URL(fileURLWithPath: "/a.csv")])
        #expect(registry.operation(id: "sheet.convert.xlsx")!.availability(for: csv, tools: noTools) == .available)
    }

    @Test func wheelsFitOrPageSensibly() {
        func count(_ path: String) -> Int {
            registry.operations(for: Selection(urls: [URL(fileURLWithPath: path)]), wheel: .convert).count
        }
        #expect(count("/a.png") == 7)   // 8 formátů bez vlastního
        #expect(count("/a.mp4") == 7)
        #expect(count("/a.wav") == 7)
        #expect(count("/a.pdf") == 9)   // stránkování
        #expect(count("/a.docx") == 7)   // + PDF
        #expect(count("/a.pptx") == 3)
    }
}

extension Fixtures {
    /// PDF s tabulkou (sloupce zarovnané mezerami).
    static func tablePDF(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("tabulka.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rows = [["Položka", "Počet", "Cena"], ["Jablka", "12", "34,50"], ["Hrušky", "3", "9,90"]]
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                cell.draw(at: CGPoint(x: 20 + c * 130, y: 160 - r * 24), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// „Naskenované“ PDF: text jen jako obrázek, bez textové vrstvy.
    static func scannedPDF(in dir: URL, name: String = "sken.pdf") throws -> URL {
        let size = CGSize(width: 1200, height: 600)
        let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        "Faktura číslo 2026".draw(at: CGPoint(x: 80, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 72)])
        NSGraphicsContext.restoreGraphicsState()
        let image = bitmap.makeImage()!

        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 600, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
