import AppKit
import Foundation
import PDFKit
import Vision

/// Rozvržení textu v PDF: řádky s pozicí a písmem, buňky podle mezer (tabulky).
/// U naskenovaných stránek (bez textové vrstvy) doplní text OCR přes Vision.
public enum PDFLayout {
    public struct Line: Sendable {
        public let text: String
        /// Rámec v souřadnicích stránky (y nahoru).
        public let bounds: CGRect
        public let fontSize: CGFloat
        public let bold: Bool
        /// Úseky oddělené velkou mezerou (sloupce tabulky): text a levý okraj.
        public let cells: [(text: String, x: CGFloat)]
    }

    public struct Page: Sendable {
        public let lines: [Line]
        public let size: CGSize
        public let recognized: Bool // text z OCR
    }

    // MARK: Řádky

    public static func pages(of document: PDFDocument, ocr: Bool = true,
                             progress: (Double) -> Void = { _ in }) throws -> [Page] {
        var pages: [Page] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var lines = textLines(page)
            var recognized = false
            if ocr, lines.reduce(0, { $0 + $1.text.count }) < 20 {
                let ocrLines = (try? recognize(page)) ?? []
                if !ocrLines.isEmpty {
                    lines = ocrLines
                    recognized = true
                }
            }
            pages.append(Page(lines: lines, size: page.bounds(for: .cropBox).size, recognized: recognized))
            progress(Double(index + 1) / Double(document.pageCount))
        }
        return pages
    }

    /// Řádky z textové vrstvy PDF (PDFKit dělí text na řádky znakem nového řádku).
    static func textLines(_ page: PDFPage) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let attributed = page.attributedString
        let ns = string as NSString
        let skipsNewlines = boundsSkipNewlines(page, ns)
        // Index znaku v textu → index pro characterBounds (viz boundsSkipNewlines).
        var newlinesBefore = [Int](repeating: 0, count: ns.length + 1)
        for i in 0..<ns.length {
            newlinesBefore[i + 1] = newlinesBefore[i] + (ns.character(at: i) == 10 ? 1 : 0)
        }
        func bounds(at index: Int) -> CGRect {
            page.characterBounds(at: skipsNewlines ? index - newlinesBefore[index] : index)
        }

        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { text, range, _, _ in
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            var boxes: [(Character, CGRect)] = []
            var union = CGRect.null
            var offset = 0
            for char in text {
                let box = bounds(at: range.location + offset)
                offset += String(char).utf16.count
                boxes.append((char, box))
                if !box.isEmpty, char != " " { union = union.union(box) }
            }
            var size: CGFloat = 0
            var bold = true
            if let attributed, range.location + range.length <= attributed.length {
                attributed.enumerateAttribute(.font, in: range) { value, _, _ in
                    guard let font = value as? NSFont else { return }
                    size = max(size, font.pointSize)
                    if !font.fontDescriptor.symbolicTraits.contains(.bold) { bold = false }
                }
            }
            if size == 0 { size = union.isNull ? 12 : union.height }
            lines.append(Line(text: text.trimmingCharacters(in: .whitespaces), bounds: union.isNull ? .zero : union,
                              fontSize: size, bold: bold, cells: splitCells(boxes, fontSize: size)))
        }
        // Pořadí čtení: shora dolů, zleva doprava (PDF může mít text v libovolném pořadí).
        return lines.sorted { a, b in
            abs(a.bounds.midY - b.bounds.midY) > min(a.bounds.height, b.bounds.height) / 2
                ? a.bounds.midY > b.bounds.midY
                : a.bounds.minX < b.bounds.minX
        }
    }

    /// PDFKit v některých verzích macOS nepočítá v `characterBounds(at:)` znaky nového řádku,
    /// takže se pozice od druhého řádku posouvají. Vybere mapování, u kterého jdou znaky
    /// v řádku zleva doprava na stejné výšce.
    static func boundsSkipNewlines(_ page: PDFPage, _ text: NSString) -> Bool {
        let limit = min(text.length, 600)
        func score(skip: Bool) -> Int {
            var newlines = 0
            var previous: CGRect?
            var good = 0
            for i in 0..<limit {
                let isNewline = text.character(at: i) == 10
                if isNewline { newlines += 1; previous = nil; continue }
                let box = page.characterBounds(at: skip ? i - newlines : i)
                if let previous, !box.isEmpty, abs(previous.midY - box.midY) < max(previous.height, 2),
                   box.minX >= previous.minX { good += 1 }
                previous = box
            }
            return good
        }
        return score(skip: true) > score(skip: false)
    }

    /// Rozdělí řádek na buňky tam, kde je mezera větší než ~1,5 šířky písmene.
    static func splitCells(_ boxes: [(Character, CGRect)], fontSize: CGFloat) -> [(text: String, x: CGFloat)] {
        var cells: [(text: String, x: CGFloat)] = []
        var current = ""
        var start: CGFloat?
        var lastMaxX: CGFloat?
        let threshold = max(fontSize * 1.2, 6)
        for (char, box) in boxes {
            if char == " " || box.isEmpty {
                // PDFKit dává mezeře šířku celé mezery mezi sloupci.
                if char == " ", box.width > threshold, !current.isEmpty {
                    cells.append((current.trimmingCharacters(in: .whitespaces), start ?? 0))
                    current = ""
                    start = nil
                } else if !current.isEmpty {
                    current.append(" ")
                }
                continue
            }
            if let lastMaxX, box.minX - lastMaxX > threshold, !current.isEmpty {
                cells.append((current.trimmingCharacters(in: .whitespaces), start ?? 0))
                current = ""
                start = nil
            }
            if start == nil { start = box.minX }
            current.append(char)
            lastMaxX = box.maxX
        }
        if !current.isEmpty { cells.append((current.trimmingCharacters(in: .whitespaces), start ?? 0)) }
        return cells
    }

    /// OCR stránky (čeština + angličtina, přesný režim).
    static func recognize(_ page: PDFPage) throws -> [Line] {
        let image = try PDFBackend.render(page, dpi: 200)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["cs-CZ", "en-US", "de-DE", "sk-SK"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = page.bounds(for: .cropBox).size
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox // normalizované, y nahoru
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            let fontSize = rect.height * 0.8
            return Line(text: text, bounds: rect, fontSize: fontSize.rounded(), bold: false,
                        cells: [(text, rect.minX)])
        }
        return lines.sorted { abs($0.bounds.midY - $1.bounds.midY) > 4 ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX }
    }

    // MARK: Bloky dokumentu (DOCX, EPUB, Markdown)

    /// Odstavce a nadpisy. Řádky se slévají do odstavců, nadpis = výrazně větší písmo.
    public static func blocks(_ pages: [Page]) -> [DocBlock] {
        let lines = pages.flatMap(\.lines)
        guard !lines.isEmpty else { return [] }
        // Tělo textu = velikost písma s nejvíc znaky.
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[line.fontSize.rounded(), default: 0] += line.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 12

        var blocks: [DocBlock] = []
        var paragraph: [String] = []
        var previous: Line?

        func flush() {
            guard !paragraph.isEmpty else { return }
            // Rozdělená slova na konci řádku („infor-“ + „mace“) spojit.
            var text = ""
            for part in paragraph {
                if text.hasSuffix("-"), let first = part.first, first.isLowercase {
                    text.removeLast()
                    text += part
                } else {
                    text += text.isEmpty ? part : " " + part
                }
            }
            blocks.append(DocBlock(kind: .paragraph, runs: [DocBlock.Run(text: text)]))
            paragraph.removeAll()
        }

        for page in pages {
            previous = nil
            for line in page.lines {
                let text = line.text
                let short = text.count < 120
                if short, line.fontSize >= body * 1.6 {
                    flush(); blocks.append(DocBlock(kind: .heading(1), runs: [DocBlock.Run(text: text)]))
                } else if short, line.fontSize >= body * 1.25 {
                    flush(); blocks.append(DocBlock(kind: .heading(2), runs: [DocBlock.Run(text: text)]))
                } else if short, line.bold, !page.recognized, line.fontSize >= body, text.count < 80, !text.hasSuffix(".") {
                    flush(); blocks.append(DocBlock(kind: .heading(3), runs: [DocBlock.Run(text: text)]))
                } else if let bullet = text.first, "•◦▪‣-–".contains(bullet), text.dropFirst().first == " " {
                    flush()
                    blocks.append(DocBlock(kind: .listItem(ordered: false, level: 0, number: 0),
                                           runs: [DocBlock.Run(text: String(text.dropFirst(2)))]))
                } else {
                    // Nový odstavec: velká mezera nad řádkem nebo odsazení prvního řádku.
                    if let previous {
                        let gap = previous.bounds.minY - line.bounds.maxY
                        let indent = line.bounds.minX - previous.bounds.minX
                        if gap > line.fontSize * 0.9 || indent > line.fontSize * 1.5 || previous.fontSize != line.fontSize {
                            flush()
                        }
                    }
                    paragraph.append(text)
                }
                previous = line
            }
            flush()
        }
        return blocks
    }

    // MARK: Tabulky (XLSX)

    /// Tabulka stránky: řádky podle y, sloupce podle zarovnání začátků buněk napříč řádky.
    public static func table(_ page: Page) -> Spreadsheet.Table {
        let lines = page.lines.filter { !$0.cells.isEmpty }
        guard !lines.isEmpty else { return [] }
        // Sloupce: shluky x-souřadnic začátků buněk (tolerance 8 pt).
        let starts = lines.flatMap { $0.cells.map(\.x) }.sorted()
        var columns: [CGFloat] = []
        for x in starts where columns.last.map({ x - $0 > 8 }) ?? true { columns.append(x) }
        // Řádky se stejnou výškou (text vedle sebe vypsaný zvlášť) sloučit.
        var rows: [[(text: String, x: CGFloat)]] = []
        var lastY: CGFloat?
        for line in lines {
            if let lastY, abs(lastY - line.bounds.midY) < line.bounds.height / 2, !rows.isEmpty {
                rows[rows.count - 1] += line.cells
            } else {
                rows.append(line.cells)
            }
            lastY = line.bounds.midY
        }
        return rows.map { cells in
            var row = [String](repeating: "", count: columns.count)
            for cell in cells {
                // Nejbližší sloupec vlevo od začátku buňky.
                let index = columns.lastIndex { $0 <= cell.x + 8 } ?? 0
                row[index] = row[index].isEmpty ? cell.text : row[index] + " " + cell.text
            }
            while row.count > 1, row.last?.isEmpty == true { row.removeLast() }
            return row
        }
    }
}
