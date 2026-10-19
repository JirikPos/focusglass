import Foundation

/// Tabulky: CSV/TSV (RFC 4180) a XLSX (čtení i zápis bez závislostí).
public enum Spreadsheet {
    public typealias Table = [[String]]

    // MARK: CSV / TSV

    /// Rozparsuje CSV s uvozovkami, zalomením řádků v buňkách a zdvojenými uvozovkami.
    /// Oddělovač se u CSV odhadne (čárka / středník – český Excel ukládá středníky).
    public static func parseDelimited(_ text: String, separator: Character? = nil) -> Table {
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let separator = separator ?? guessSeparator(content)
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()
        var pending: Character? = nil

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                row.append(field)
                field = ""
            case "\n", "\r\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            case "\r":
                break
            default:
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func guessSeparator(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        let counts: [(Character, Int)] = [",", ";", "\t", "|"].map { candidate in
            (candidate, firstLine.filter { $0 == candidate }.count)
        }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    public static func delimited(_ table: Table, separator: Character) -> String {
        table.map { row in
            row.map { cell in
                let needsQuotes = cell.contains(separator) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
                return needsQuotes ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: XLSX čtení

    public struct Sheet: Sendable {
        public let name: String
        public let rows: Table
    }

    public static func readXLSX(_ url: URL) async throws -> [Sheet] {
        guard let workbook = try await Zip.read("xl/workbook.xml", from: url) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let rels = try await Zip.read("xl/_rels/workbook.xml.rels", from: url) ?? Data()
        let shared = try await Zip.read("xl/sharedStrings.xml", from: url).map(SharedStringsParser.parse) ?? []
        let targets = RelationshipsParser.parse(rels)
        var sheets: [Sheet] = []
        for (index, entry) in WorkbookParser.parse(workbook).enumerated() {
            var path = targets[entry.relationID] ?? "worksheets/sheet\(index + 1).xml"
            if path.hasPrefix("/") { path.removeFirst() } else { path = "xl/" + path }
            guard let data = try await Zip.read(path, from: url) else { continue }
            sheets.append(Sheet(name: entry.name, rows: SheetParser.parse(data, shared: shared)))
        }
        return sheets
    }

    // MARK: XLSX zápis

    /// Minimální platné XLSX (inline řetězce, čísla jako čísla).
    public static func writeXLSX(_ sheets: [Sheet], to output: URL, workDirectory: URL) async throws {
        let root = workDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for folder in ["_rels", "docProps", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ content: String) throws {
            try content.write(to: root.appendingPathComponent(path), atomically: false, encoding: .utf8)
        }
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let overrides = sheets.indices.map {
            #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        try put("[Content_Types].xml", header + #"""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\#(overrides)</Types>
        """#)
        try put("_rels/.rels", header + #"""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """#)
        let sheetEntries = sheets.enumerated().map { index, sheet in
            #"<sheet name="\#(xmlEscape(sheetName(sheet.name, index: index)))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined()
        try put("xl/workbook.xml", header + #"""
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheetEntries)</sheets></workbook>
        """#)
        let sheetRels = sheets.indices.map {
            #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"#
        }.joined()
        try put("xl/_rels/workbook.xml.rels", header + #"""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(sheetRels)</Relationships>
        """#)
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            var xml = header + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
            for (r, row) in sheet.rows.enumerated() {
                xml += #"<row r="\#(r + 1)">"#
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = column(c) + String(r + 1)
                    if let number = numeric(value) {
                        xml += #"<c r="\#(ref)"><v>\#(number)</v></c>"#
                    } else {
                        xml += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(xmlEscape(value))</t></is></c>"#
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            try put("xl/worksheets/sheet\(index + 1).xml", xml)
        }
        try await Zip.archiveContents(of: root, to: output)
    }

    /// Excel: max 31 znaků, bez []:*?/\ a jedinečné.
    static func sheetName(_ name: String, index: Int) -> String {
        let cleaned = name.filter { !"[]:*?/\\".contains($0) }.prefix(31)
        return cleaned.isEmpty ? "List\(index + 1)" : String(cleaned)
    }

    /// Číslo zapsat jako číslo jen když se tím nic neztratí (ne „007“, ne „1,5“ s čárkou).
    static func numeric(_ value: String) -> String? {
        guard value.count < 16, let first = value.first, first.isNumber || first == "-" else { return nil }
        if value.count > 1, value.hasPrefix("0"), !value.hasPrefix("0.") { return nil }
        guard Double(value) != nil, !value.contains("e"), !value.contains("E") else { return nil }
        return value
    }

    /// 0 → A, 25 → Z, 26 → AA.
    static func column(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(65 + index % 26)!) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    /// „AB12“ → 27.
    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return index - 1
    }

    static func xmlEscape(_ text: String) -> String {
        // Řídicí znaky XML 1.0 nepovoluje vůbec.
        let filtered = String(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        return Markdown.escape(filtered)
    }

    /// CSV, TSV nebo XLSX → listy.
    public static func load(_ url: URL) async throws -> [Sheet] {
        let sheets: [Sheet]
        switch url.pathExtension.lowercased() {
        case "xlsx":
            sheets = try await readXLSX(url)
        case "tsv":
            sheets = [Sheet(name: "List1", rows: parseDelimited(try TextBackend.readText(url), separator: "\t"))]
        default:
            sheets = [Sheet(name: "List1", rows: parseDelimited(try TextBackend.readText(url)))]
        }
        guard !sheets.isEmpty else { throw ConvertError.unreadable(url.lastPathComponent) }
        return sheets
    }

    // MARK: Převodník

    public static let convert: Converter = { job in
        let sheets = try await load(job.source)
        job.progress(0.5)

        if job.target == .xlsx {
            try await writeXLSX(sheets, to: job.file, workDirectory: job.scratch)
            job.progress(1)
            return job.file
        }
        let separator: Character = job.target == .tsv ? "\t" : ","
        let nonEmpty = sheets.filter { !$0.rows.isEmpty }
        // Víc listů → složka s CSV za každý list.
        if nonEmpty.count > 1 {
            let folder = try job.folder()
            for (index, sheet) in nonEmpty.enumerated() {
                let name = sheetName(sheet.name, index: index).replacingOccurrences(of: "/", with: "-")
                try delimited(sheet.rows, separator: separator)
                    .write(to: folder.appendingPathComponent("\(name).\(job.target.ext)"), atomically: false, encoding: .utf8)
            }
            job.progress(1)
            return folder
        }
        try delimited(nonEmpty.first?.rows ?? [], separator: separator).write(to: job.file, atomically: false, encoding: .utf8)
        job.progress(1)
        return job.file
    }
}

// MARK: - XML parsery XLSX

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inText = false
    private var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let handler = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.strings
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "si": current = ""
        case "t": inText = !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "t": inText = false
        case "rPh": inPhonetic = false
        case "si": strings.append(current)
        default: break
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Entry { let name: String; let relationID: String }
    var entries: [Entry] = []

    static func parse(_ data: Data) -> [Entry] {
        let handler = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.entries
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "sheet" else { return }
        entries.append(Entry(name: attributes["name"] ?? "List", relationID: attributes["r:id"] ?? ""))
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let handler = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.targets
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if element == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [Int: [Int: String]] = [:]
    private var rowIndex = 0
    private var cellRef = ""
    private var cellType = ""
    private var nextColumn = 0
    private var value = ""
    private var capturing = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> Spreadsheet.Table {
        let handler = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.table
    }

    var table: Spreadsheet.Table {
        guard let maxRow = rows.keys.max() else { return [] }
        let width = (rows.values.compactMap { $0.keys.max() }.max() ?? -1) + 1
        return (0...maxRow).map { r in
            let cells = rows[r] ?? [:]
            return (0..<width).map { cells[$0] ?? "" }
        }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "row":
            rowIndex = (attributes["r"].flatMap(Int.init) ?? (rowIndex + 1)) - 1
            nextColumn = 0
        case "c":
            cellRef = attributes["r"] ?? ""
            cellType = attributes["t"] ?? "n"
            value = ""
        case "v", "t":
            capturing = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "v", "t":
            capturing = false
        case "c":
            let column = cellRef.isEmpty ? nextColumn : Spreadsheet.columnIndex(cellRef)
            nextColumn = column + 1
            let text: String
            switch cellType {
            case "s": text = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            default: text = value
            }
            if !text.isEmpty { rows[rowIndex, default: [:]][column] = text }
        default: break
        }
    }
}
