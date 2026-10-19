import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ConvertKit

private let hasFFmpeg = ToolLocator.shared.isAvailable(.ffmpeg) && ToolLocator.shared.isAvailable(.ffprobe)

@Suite(.serialized) struct TextToolTests {
    let registry = Catalog.makeRegistry()

    @discardableResult
    private func run(_ id: String, on sources: [URL], options: [String: OptionValue] = [:]) async throws -> [URL] {
        let tool = try #require(registry.operation(id: id) as? Tool, "chybí \(id)")
        let selection = Selection(urls: sources)
        #expect(tool.accepts(selection), "\(id) nepřijme výběr")
        return try await tool.run(OperationContext(selection: selection, options: options))
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func wheelsForTextKinds() {
        func ids(_ paths: [String]) -> [String] {
            registry.operations(for: Selection(urls: paths.map { URL(fileURLWithPath: $0) }), wheel: .tools).map(\.id)
        }
        #expect(ids(["/a.docx"]) == ["document.tool.replace", "document.tool.stats"])
        #expect(ids(["/a.docx", "/b.md"]).contains("document.tool.merge"))
        #expect(ids(["/a.csv"]) == ["sheet.tool.clean"] && ids(["/a.csv", "/b.xlsx"]).contains("sheet.tool.merge"))
        #expect(ids(["/a.xls"]).isEmpty, "XLS neumíme zapsat – nic nenabízet")
        #expect(ids(["/a.epub"]) == ["epub.tool.metadata"])
        #expect(ids(["/a.srt"]) == ["subtitle.tool.shift", "subtitle.tool.fps"])
        #expect(ids(["/a.zip"]) == ["archive.tool.extract", "archive.tool.list"])
        #expect(ids(["/a.mp4", "/b.srt"]) == ["subtitle.tool.burn"], "video + titulky dohromady")
        #expect(ids(["/a.mp4", "/b.mp4"]).contains("subtitle.tool.burn") == false)
    }

    // MARK: Titulky

    @Test func subtitleMath() {
        typealias Cue = Subtitles.Cue
        let cues = [Cue(start: 1, end: 2, text: "a"), Cue(start: 5, end: 7, text: "b")]
        let later = SubtitleTools.shifted(cues, by: 1.5)
        #expect(later.map(\.start) == [2.5, 6.5] && later.map(\.end) == [3.5, 8.5])
        let earlier = SubtitleTools.shifted(cues, by: -1.5)
        #expect(earlier.count == 2 && earlier[0].start == 0 && abs(earlier[0].end - 0.5) < 1e-9, "začátek se ořízne na 0")
        #expect(SubtitleTools.shifted(cues, by: -3).map(\.text) == ["b"], "co skončí před nulou, zmizí")
        #expect(SubtitleTools.scaled(cues, by: 2).map(\.end) == [4, 14])
        let a = [Cue(start: 0, end: 2, text: "A1"), Cue(start: 4, end: 6, text: "A2")]
        let b = [Cue(start: 1, end: 3, text: "B1")]
        #expect(SubtitleTools.merged([a, b], appending: false).map(\.text) == ["A1", "B1", "A2"], "přes sebe seřazeně")
        let after = SubtitleTools.merged([a, b], appending: true)
        #expect(after.last?.text == "B1" && abs(after.last!.start - 7.1) < 1e-9, "druhý soubor za koncem prvního")
    }

    @Test func subtitleToolsWriteFiles() async throws {
        let dir = try TempDir()
        let srt = try Fixtures.srt(in: dir.url) // 1,0–2,5 a 3,0–4,0
        let shifted = try await run("subtitle.tool.shift", on: [srt], options: ["offset": .double(2)])[0]
        #expect(shifted.lastPathComponent == "titulky (posun).srt")
        #expect(try read(shifted).contains("00:00:03,000 --> 00:00:04,500"))
        await #expect(throws: ConvertError.self) { try await run("subtitle.tool.shift", on: [srt]) }

        let retimed = try await run("subtitle.tool.fps", on: [srt], options: ["from": .string("25"), "to": .string("50")])[0]
        #expect(try read(retimed).contains("00:00:00,500 --> 00:00:01,250"))
        await #expect(throws: ConvertError.self) { try await run("subtitle.tool.fps", on: [srt], options: ["from": .string("25"), "to": .string("25")]) }

        let vtt = try Fixtures.text(in: dir.url, name: "cesky.vtt", content: "WEBVTT\n\n00:00:01.500 --> 00:00:02.000\nAhoj\n")
        let merged = try await run("subtitle.tool.merge", on: [srt, vtt])[0]
        #expect(merged.pathExtension == "srt")
        let content = try read(merged)
        #expect(content.contains("Ahoj") && content.contains(Fixtures.marker))
        #expect(content.range(of: Fixtures.marker)!.lowerBound < content.range(of: "Ahoj")!.lowerBound, "seřazeno podle času")
    }

    @Test(.enabled(if: hasFFmpeg)) func burnSubtitlesIntoVideo() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, seconds: 3, size: "640x360")
        let subs = try Fixtures.text(in: dir.url, name: "klip.srt", content: "1\n00:00:00,000 --> 00:00:03,000\nTITULEK TITULEK TITULEK\n")
        let result = try await run("subtitle.tool.burn", on: [subs, clip], options: ["size": .double(36)])[0]
        #expect(result.lastPathComponent == "klip (titulky).mp4")
        let before = try await MediaFrames.frame(of: clip, fraction: 0.4, maxPixel: 640)
        let after = try await MediaFrames.frame(of: result, fraction: 0.4, maxPixel: 640)
        // Dole se objeví text: spousta pixelů se liší.
        var different = 0
        for x in stride(from: 0, to: 640, by: 4) { for y in stride(from: 270, to: 360, by: 2)
            where abs(Fixtures.sample(before, x: x, y: y).r - Fixtures.sample(after, x: x, y: y).r) > 60 { different += 1 } }
        #expect(different > 100, "titulky jsou vidět (\(different))")
        let burn = try #require(registry.operation(id: "subtitle.tool.burn"))
        let other = try await Fixtures.video(in: dir.url, name: "druhe.mp4", seconds: 1)
        #expect(!burn.accepts(Selection(urls: [clip, other])), "dvě videa nejsou video + titulky")
    }

    // MARK: Archivy

    @Test func extractZipFlattensSingleRootFolder() async throws {
        let dir = try TempDir()
        let archive = try await Fixtures.zip(in: dir.url) // archiv.zip → Složka/a.txt
        let result = try await run("archive.tool.extract", on: [archive])[0]
        #expect(result.lastPathComponent == "archiv")
        #expect(try read(result.appendingPathComponent("a.txt")) == Fixtures.marker, "bez zdvojené složky")
        // Podruhé nepřepíše.
        let second = try await run("archive.tool.extract", on: [archive])[0]
        #expect(second.lastPathComponent == "archiv 2")
    }

    @Test func extractTarWithSeveralItems() async throws {
        let dir = try TempDir()
        let src = dir.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "A".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let tar = dir.url.appendingPathComponent("dva.tar.gz")
        try await ProcessRunner.run(ArchiveBackend.tar, ["-czf", tar.path, "-C", src.path, "a.txt", "b.txt"])
        let result = try await run("archive.tool.extract", on: [tar])[0]
        #expect(result.lastPathComponent == "dva")
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.path).sorted() == ["a.txt", "b.txt"])
    }

    @Test func escapingSymlinksAreRemoved() throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("rozbaleno")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "ok".write(to: root.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ven"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("sub/nahoru").path, withDestinationPath: "../../..")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("uvnitr").path, withDestinationPath: "sub/a.txt")
        #expect(ArchiveTools.removeEscapingLinks(in: root) == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ven").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("uvnitr").path)) == "sub/a.txt", "vnitřní odkaz zůstává")
    }

    @Test func passwordProtectedZip() async throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("tajne.txt")
        try Fixtures.marker.write(to: file, atomically: true, encoding: .utf8)
        let archive = dir.url.appendingPathComponent("chraneny.zip")
        try await ProcessRunner.run(Zip.zip, ["-q", "-P", "heslo", archive.path, "tajne.txt"], currentDirectory: dir.url)
        await #expect(throws: ConvertError.self) { try await run("archive.tool.extract", on: [archive]) }
        await #expect(throws: ConvertError.wrongPassword("chraneny.zip")) {
            try await run("archive.tool.extract", on: [archive], options: ["password": .string("spatne")])
        }
        let result = try await run("archive.tool.extract", on: [archive], options: ["password": .string("heslo")])[0]
        #expect(try read(result.appendingPathComponent("tajne.txt")) == Fixtures.marker)
    }

    @Test func archiveListing() async throws {
        let dir = try TempDir()
        let result = try await run("archive.tool.list", on: [try await Fixtures.zip(in: dir.url)])[0]
        #expect(result.lastPathComponent == "archiv (obsah).txt")
        #expect(try read(result).contains("a.txt"))
        #expect(!(try read(result)).contains("__MACOSX"))
    }

    // MARK: Tabulky

    @Test func cleaningRules() {
        let table: Spreadsheet.Table = [["Jméno ", " Věk", ""], ["Ada ", "30", ""], ["", " ", ""], ["Ada", "30", ""], ["Bob", "", ""]]
        var options = SheetTools.CleanOptions()
        let basic = SheetTools.clean(table, options)
        #expect(basic == [["Jméno", "Věk", ""], ["Ada", "30", ""], ["Ada", "30", ""], ["Bob", "", ""]])
        options.removeEmptyColumns = true
        options.removeDuplicates = true
        #expect(SheetTools.clean(table, options) == [["Jméno", "Věk"], ["Ada", "30"], ["Bob", ""]])
        options.trim = false
        options.removeEmptyRows = false
        options.removeDuplicates = false
        options.removeEmptyColumns = false
        #expect(SheetTools.clean(table, options) == table)
        #expect(SheetTools.appended([[["a", "b"], ["1", "2"]], [["a", "b"], ["3", "4"]], [["x", "y"], ["5", "6"]]]) ==
                [["a", "b"], ["1", "2"], ["3", "4"], ["x", "y"], ["5", "6"]], "záhlaví se vynechá jen když je shodné")
    }

    @Test func cleanToolCSVAndXLSX() async throws {
        let dir = try TempDir()
        let csv = try Fixtures.text(in: dir.url, name: "spinave.csv", content: "jméno , věk\r\n Ada ,30\r\n,\r\n Ada ,30\r\n")
        let cleaned = try await run("sheet.tool.clean", on: [csv], options: ["duplicates": .bool(true), "delimiter": .string("semicolon"), "bom": .bool(true)])[0]
        #expect(cleaned.lastPathComponent == "spinave (vyčištěno).csv")
        // `String(contentsOf:)` BOM zahazuje – kontrola přes bajty.
        let bytes = try Data(contentsOf: cleaned)
        #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF], "UTF-8 BOM")
        #expect(try read(cleaned) == "jméno;věk\r\nAda;30\r\n")

        let xlsx = try await #require(registry.operation(id: "sheet.convert.xlsx")).run(OperationContext(selection: Selection(urls: [csv])))[0]
        let again = try await run("sheet.tool.clean", on: [xlsx])[0]
        #expect(again.pathExtension == "xlsx")
        let sheet = try #require(try await Spreadsheet.readXLSX(again).first)
        #expect(sheet.rows == [["jméno", "věk"], ["Ada", "30"], ["Ada", "30"]])
    }

    @Test func mergeSheets() async throws {
        let dir = try TempDir()
        let a = try Fixtures.text(in: dir.url, name: "leden.csv", content: "k,částka\nA,1\n")
        let b = try Fixtures.text(in: dir.url, name: "unor.csv", content: "k,částka\nB,2\n")
        let stacked = try await run("sheet.tool.merge", on: [a, b], options: ["format": .string("csv")])[0]
        #expect(Spreadsheet.parseDelimited(try read(stacked)) == [["k", "částka"], ["A", "1"], ["B", "2"]])
        let sheets = try await run("sheet.tool.merge", on: [a, b], options: ["mode": .string("sheets")])[0]
        #expect(sheets.pathExtension == "xlsx")
        let loaded = try await Spreadsheet.readXLSX(sheets)
        #expect(loaded.map(\.name) == ["leden", "unor"] && loaded[1].rows[1] == ["B", "2"])
    }

    // MARK: Dokumenty

    @Test func textStatistics() {
        let stats = TextStats.compute("Ahoj světe. Tohle je druhá věta!\n\nNový odstavec má pět slov.")
        #expect(stats.words == 11 && stats.sentences == 3 && stats.paragraphs == 2, Comment(rawValue: "\(stats.words) slov, \(stats.sentences) vět, \(stats.paragraphs) odstavců"))
        #expect(stats.charactersNoSpaces < stats.characters)
        #expect(TextStats.compute("slovo slovo slovo jiné").topWords.first?.word == "slovo")
        #expect(TextStats.compute("1234 5678 !!!").words == 0, "čísla nejsou slova")
        #expect(TextStats.report(stats, name: "x.txt").contains("Slov: 11"))
    }

    @Test func replacementRules() throws {
        #expect(try DocumentTools.replace(in: "Kočka a kočka.", find: "kočka", with: "pes", regex: false, caseSensitive: false) == ("pes a pes.", 2))
        #expect(try DocumentTools.replace(in: "Kočka a kočka.", find: "kočka", with: "pes", regex: false, caseSensitive: true) == ("Kočka a pes.", 1))
        #expect(try DocumentTools.replace(in: "cena (10 Kč)", find: "(10 Kč)", with: "$5", regex: false, caseSensitive: true) == ("cena $5", 1), "speciální znaky doslova")
        #expect(try DocumentTools.replace(in: "2024-05-01", find: #"(\d+)-(\d+)-(\d+)"#, with: "$3. $2. $1", regex: true, caseSensitive: true) == ("01. 05. 2024", 1))
        #expect(throws: ConvertError.self) { try DocumentTools.replace(in: "a", find: "(", with: "", regex: true, caseSensitive: true) }
    }

    @Test func replaceInPlainAndRichDocuments() async throws {
        let dir = try TempDir()
        let txt = try Fixtures.text(in: dir.url, name: "dopis.txt", content: "Vážený pane Nováku,\nděkuji, Novák.")
        let changed = try await run("document.tool.replace", on: [txt], options: ["find": .string("Novák"), "replace": .string("Svoboda")])[0]
        #expect(changed.lastPathComponent == "dopis (upraveno).txt")
        #expect(try read(changed) == "Vážený pane Svobodau,\nděkuji, Svoboda.", "hledá se podřetězec, jako ve všech textových editorech")

        // DOCX: tučné písmo se při nahrazení uvnitř zachová.
        let docx = dir.url.appendingPathComponent("smlouva.docx")
        let rich = NSMutableAttributedString(string: "Strana ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        rich.append(NSAttributedString(string: "ALFA", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        rich.append(NSAttributedString(string: " platí.", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        let replaced = try await run("document.tool.replace", on: [docx], options: ["find": .string("alfa"), "replace": .string("BETA")])[0]
        let loaded = try await TextBackend.load(replaced, workDirectory: dir.url)
        #expect(loaded.string.contains("Strana BETA platí."))
        let range = (loaded.string as NSString).range(of: "BETA")
        let font = try #require(loaded.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold), "formátování zůstalo")

        await #expect(throws: ConvertError.self) { try await run("document.tool.replace", on: [txt], options: ["find": .string("nic takového")]) }
        await #expect(throws: ConvertError.self) { try await run("document.tool.replace", on: [txt], options: ["find": .string("")]) }
    }

    @Test func documentStatsAndMerge() async throws {
        let dir = try TempDir()
        let a = try Fixtures.text(in: dir.url, name: "a.txt", content: "První dokument.")
        let b = try Fixtures.markdown(in: dir.url)
        let stats = try await run("document.tool.stats", on: [a])[0]
        #expect(try read(stats).contains("Slov: 2"))

        let merged = try await run("document.tool.merge", on: [a, b], options: ["format": .string("txt"), "separator": .string("rule")])[0]
        #expect(merged.pathExtension == "txt")
        let text = try read(merged)
        #expect(text.contains("První dokument.") && text.contains("――") && text.contains(Fixtures.marker))

        let pdf = try await run("document.tool.merge", on: [a, b], options: ["format": .string("pdf")])[0]
        let pdfText = try #require(PDFDocument(url: pdf)?.string)
        #expect(pdfText.contains("První dokument.") && pdfText.contains(Fixtures.marker))
    }

    @Test func documentToPDFConversionPaginates() async throws {
        let dir = try TempDir()
        let long = (1...400).map { "Řádek číslo \($0): Žluťoučký kůň úpěl ďábelské ódy." }.joined(separator: "\n")
        let source = try Fixtures.text(in: dir.url, name: "dlouhy.txt", content: long)
        let operation = try #require(registry.operation(id: "document.convert.pdf"))
        let result = try await operation.run(OperationContext(selection: Selection(urls: [source])))[0]
        let document = try #require(PDFDocument(url: result))
        #expect(document.pageCount > 3, "stránek: \(document.pageCount)")
        #expect(document.string?.contains("Řádek číslo 400") == true && document.string?.contains("Řádek číslo 1:") == true)
        let box = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 595.28) < 1 && abs(box.height - 841.89) < 1, "A4")
        // Černý text na bílém, ne naopak.
        let image = try PDFBackend.render(try #require(document.page(at: 0)), dpi: 72)
        #expect(Fixtures.sample(image, x: 5, y: 5).r > 240)
        var dark = 0
        for x in stride(from: 40, to: 300, by: 2) { for y in stride(from: 40, to: 200, by: 2) where Fixtures.sample(image, x: x, y: y).r < 100 { dark += 1 } }
        #expect(dark > 50, "text je tmavý (\(dark))")
    }

    // MARK: EPUB

    @Test func epubMetadataAndCover() async throws {
        let dir = try TempDir()
        let epub = try await #require(registry.operation(id: "document.convert.epub")).run(
            OperationContext(selection: Selection(urls: [try Fixtures.markdown(in: dir.url)])))[0]
        let before = try await EPUBMeta.read(epub, workDirectory: dir.url)
        #expect(before.title == "poznámky" && !before.hasCover)

        let cover = try Fixtures.halves(in: dir.url, name: "obalka.png", width: 300, height: 450)
        let result = try await run("epub.tool.metadata", on: [epub], options: [
            "title": .string("Nový název"), "author": .string("Ada Lovelace"), "language": .string("en"), "cover": .string(cover.path)])[0]
        #expect(result.lastPathComponent == "poznámky (EPUB) (metadata).epub")
        let after = try await EPUBMeta.read(result, workDirectory: dir.url)
        #expect(after == EPUBMeta.Info(title: "Nový název", author: "Ada Lovelace", language: "en", hasCover: true))

        // Kniha zůstala platná: mimetype první a nekomprimovaný, obsah se čte, obálka je v balíčku.
        let data = try Data(contentsOf: result)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(try await EPUB.readHTML(result, workDirectory: dir.url).html.contains(Fixtures.marker))
        let extracted = dir.url.appendingPathComponent("rozbaleno")
        try await Zip.extract(result, to: extracted)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("OEBPS/cover.png").path))

        // Druhá obálka nahradí první a jen jedna položka je obálka.
        let second = try await run("epub.tool.metadata", on: [result], options: ["cover": .string(try Fixtures.noisy(in: dir.url, name: "jina.jpg", width: 200, height: 300).path)])[0]
        let opf = try #require(try await Zip.read("OEBPS/content.opf", from: second))
        #expect(String(decoding: opf, as: UTF8.self).components(separatedBy: "cover-image").count - 1 == 3, "id + properties + content jednou")
        await #expect(throws: ConvertError.self) { try await run("epub.tool.metadata", on: [epub]) }
    }
}
