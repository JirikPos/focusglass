import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ConvertKit

/// Každý převod z katalogu na skutečném souboru; výsledek se znovu načte a ověří.
@Suite(.serialized) struct ConversionTests {
    let registry = Catalog.makeRegistry()

    private func run(_ id: String, on source: URL) async throws -> URL {
        let operation = try #require(registry.operation(id: id), "chybí operace \(id)")
        let selection = Selection(urls: [source])
        #expect(operation.accepts(selection), "\(id) nepřijme \(source.lastPathComponent)")
        let results = try await operation.run(OperationContext(selection: selection))
        let result = try #require(results.first)
        #expect(FileManager.default.fileExists(atPath: result.path))
        return result
    }

    // MARK: Obrázky

    @Test(arguments: ["png", "jpg", "heic", "tiff", "bmp"])
    func imageToImage(target: String) async throws {
        let dir = try TempDir()
        let source = try Fixtures.png(in: dir.url, name: target == "png" ? "x.tiff" : "x.png")
        let result = try await run("image.convert.\(target)", on: source)
        let image = try ImageBackend.image(at: result)
        #expect(image.width == 64)
        #expect(result.lastPathComponent.contains("(\(target.uppercased()))"))
    }

    @Test func pngToJPGFlattensTransparencyToWhite() async throws {
        let dir = try TempDir()
        let source = try Fixtures.png(in: dir.url)
        let result = try await run("image.convert.jpg", on: source)
        let image = try ImageBackend.image(at: result)
        // Pravá polovina byla průhledná → bílá (ne černá).
        let pixel = try #require(Self.pixel(image, x: 60, y: 32))
        #expect(pixel.r > 240 && pixel.g > 240 && pixel.b > 240)
    }

    @Test func svgRasterizes() async throws {
        let dir = try TempDir()
        let result = try await run("image.convert.png", on: try Fixtures.svg(in: dir.url))
        let image = try ImageBackend.image(at: result)
        #expect(image.width >= 2048 && image.width == image.height * 2)
    }

    @Test func imageToPDF() async throws {
        let dir = try TempDir()
        let result = try await run("image.convert.pdf", on: try Fixtures.png(in: dir.url))
        #expect(PDFDocument(url: result)?.pageCount == 1)
    }

    @Test func webpAndAvifUseSystemOrReportTool() {
        for id in ["image.convert.webp", "image.convert.avif"] {
            let op = registry.operation(id: id)!
            let systemWrites = ImageBackend.canWrite(id.hasSuffix("webp") ? .webp : .avif)
            #expect(op.requirements.isEmpty == systemWrites)
        }
    }

    @Test func sameFormatNotOffered() {
        let selection = Selection(urls: [URL(fileURLWithPath: "/a.jpeg")])
        #expect(!registry.operation(id: "image.convert.jpg")!.accepts(selection))
        #expect(registry.operation(id: "image.convert.png")!.accepts(selection))
    }

    @Test func imageWheelFitsWithoutPaging() {
        let ops = registry.operations(for: Selection(urls: [URL(fileURLWithPath: "/a.png")]), wheel: .convert)
        #expect(ops.count <= 8)
        #expect(!ops.contains { $0.title == "PNG" })
    }

    // MARK: PDF

    @Test(arguments: ["png", "jpg"])
    func pdfPagesToImages(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.\(target)", on: try Fixtures.pdf(in: dir.url))
        let files = try FileManager.default.contentsOfDirectory(atPath: result.path).sorted()
        #expect(files == ["dokument 1.\(target)", "dokument 2.\(target)"])
        let image = try ImageBackend.image(at: result.appendingPathComponent(files[0]))
        #expect(image.width == Int(200 * 300 / 72.0) + 1 || image.width == Int((200 * 300 / 72.0).rounded()))
    }

    @Test func singlePagePDFGivesFile() async throws {
        let dir = try TempDir()
        let result = try await run("pdf.convert.png", on: try Fixtures.pdf(in: dir.url, pages: 1))
        #expect(result.pathExtension == "png")
    }

    @Test func pdfToTextAndMarkdown() async throws {
        let dir = try TempDir()
        let source = try Fixtures.pdf(in: dir.url)
        let text = try String(contentsOf: try await run("pdf.convert.txt", on: source), encoding: .utf8)
        #expect(text.contains(Fixtures.marker))
        let markdown = try String(contentsOf: try await run("pdf.convert.md", on: source), encoding: .utf8)
        #expect(markdown.contains("# Nadpis"))
        #expect(markdown.contains(Fixtures.marker))
    }

    // MARK: Zvuk a video

    @Test(arguments: ["m4a", "aiff", "flac"])
    func audioConversions(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("audio.convert.\(target)", on: try Fixtures.wav(in: dir.url))
        let file = try AVAudioFile(forReading: result)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 0.5) < 0.1)
    }

    @Test func audioToWav() async throws {
        let dir = try TempDir()
        let flac = try await run("audio.convert.flac", on: try Fixtures.wav(in: dir.url))
        let result = try await run("audio.convert.wav", on: flac)
        #expect(try AVAudioFile(forReading: result).length > 20_000)
    }

    @Test(arguments: ["mov", "gif"])
    func videoConversions(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("video.convert.\(target)", on: try await Fixtures.mp4(in: dir.url))
        if target == "gif" {
            let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
            #expect(CGImageSourceGetCount(source) >= 10)
        } else {
            let tracks = try await AVURLAsset(url: result).loadTracks(withMediaType: .video)
            #expect(tracks.count == 1)
        }
    }

    // MARK: Dokumenty

    @Test(arguments: ["docx", "txt", "html", "rtf", "epub"])
    func markdownToDocuments(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("document.convert.\(target)", on: try Fixtures.markdown(in: dir.url))
        let back = try await TextBackend.load(result, workDirectory: dir.url)
        #expect(back.string.contains(Fixtures.marker))
    }

    @Test func docxToMarkdownKeepsHeading() async throws {
        let dir = try TempDir()
        let result = try await run("document.convert.md", on: try Fixtures.docx(in: dir.url))
        let markdown = try String(contentsOf: result, encoding: .utf8)
        #expect(markdown.hasPrefix("# Nadpis"))
        #expect(markdown.contains(Fixtures.marker))
    }

    @Test func epubIsValidContainer() async throws {
        let dir = try TempDir()
        let result = try await run("document.convert.epub", on: try Fixtures.docx(in: dir.url))
        // mimetype musí být první a nekomprimovaný: na offsetu 30 je jeho jméno, za ním obsah.
        let data = try Data(contentsOf: result)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<58], as: UTF8.self) == "application/epub+zip")
        let html = try await EPUB.readHTML(result, workDirectory: dir.url).html
        #expect(html.contains(Fixtures.marker))
    }

    // MARK: Tabulky, titulky, archivy

    @Test func csvToXLSXAndBack() async throws {
        let dir = try TempDir()
        let xlsx = try await run("sheet.convert.xlsx", on: try Fixtures.csv(in: dir.url))
        let sheets = try await Spreadsheet.readXLSX(xlsx)
        #expect(sheets.first?.rows[1][1] == "čárka, a \"uvozovky\"")
        #expect(sheets.first?.rows[2][2] == "007") // nuly na začátku zůstanou (text)
        let csv = try await run("sheet.convert.csv", on: xlsx)
        let table = Spreadsheet.parseDelimited(try String(contentsOf: csv, encoding: .utf8))
        #expect(table[2] == ["Bob", Fixtures.marker, "007"])
    }

    @Test func subtitlesRoundTrip() async throws {
        let dir = try TempDir()
        let vtt = try await run("subtitle.convert.vtt", on: try Fixtures.srt(in: dir.url))
        let content = try String(contentsOf: vtt, encoding: .utf8)
        #expect(content.hasPrefix("WEBVTT"))
        #expect(content.contains("00:00:01.000 --> 00:00:02.500"))
        let txt = try await run("subtitle.convert.txt", on: vtt)
        #expect(try String(contentsOf: txt, encoding: .utf8) == "\(Fixtures.marker)\nDruhý\n")
    }

    @Test(arguments: ["tar", "tgz"])
    func zipToOtherArchives(target: String) async throws {
        let dir = try TempDir()
        let result = try await run("archive.convert.\(target)", on: try await Fixtures.zip(in: dir.url))
        let listing = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", result.path])
        #expect(String(decoding: listing.stdout, as: UTF8.self).contains("Složka/a.txt"))
        #expect(result.lastPathComponent == (target == "tar" ? "archiv (TAR).tar" : "archiv (GZIP).tar.gz"))
    }

    @Test func folderToZip() async throws {
        let dir = try TempDir()
        let result = try await run("archive.convert.zip", on: try Fixtures.folder(in: dir.url))
        let extracted = dir.url.appendingPathComponent("rozbaleno")
        let root = try await ArchiveBackend.extract(result, into: extracted)
        #expect(root.lastPathComponent.precomposedStringWithCanonicalMapping == "Složka")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == Fixtures.marker)
        #expect(!FileManager.default.fileExists(atPath: extracted.appendingPathComponent("__MACOSX").path))
    }

    // MARK: Obecné

    @Test func neverOverwritesExistingResult() async throws {
        let dir = try TempDir()
        let source = try Fixtures.png(in: dir.url)
        let first = try await run("image.convert.jpg", on: source)
        let second = try await run("image.convert.jpg", on: source)
        #expect(first.lastPathComponent == "obrázek (JPG).jpg")
        #expect(second.lastPathComponent == "obrázek (JPG) 2.jpg")
    }

    @Test func everyCatalogOperationHasUniqueID() {
        let ids = registry.operations.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }
}
