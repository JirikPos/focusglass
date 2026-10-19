import Foundation

extension Selection {
    /// Tabulky, které umíme číst sami (CSV, TSV, XLSX).
    var allNativeSheets: Bool {
        !isEmpty && zip(urls, kinds).allSatisfy { $1 == .spreadsheet && ["csv", "tsv", "xlsx"].contains($0.pathExtension.lowercased()) }
    }
}

public enum SheetTools {
    public struct CleanOptions: Sendable, Equatable {
        public var trim = true
        public var removeEmptyRows = true
        public var removeEmptyColumns = false
        public var removeDuplicates = false

        public init() {}
    }

    /// Ořezání mezer, vyhození prázdných řádků a sloupců a duplicit. První řádek (záhlaví) zůstává vždy.
    public static func clean(_ table: Spreadsheet.Table, _ options: CleanOptions) -> Spreadsheet.Table {
        var rows = table
        if options.trim {
            rows = rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        }
        let isEmpty: ([String]) -> Bool = { $0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        if options.removeEmptyRows {
            rows = rows.enumerated().filter { $0.offset == 0 || !isEmpty($0.element) }.map(\.element)
        }
        if options.removeEmptyColumns, let width = rows.map(\.count).max(), width > 0 {
            let keep = (0..<width).filter { column in
                rows.contains { column < $0.count && !$0[column].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            rows = rows.map { row in keep.map { $0 < row.count ? row[$0] : "" } }
        }
        if options.removeDuplicates {
            var seen = Set<[String]>()
            rows = rows.enumerated().filter { $0.offset == 0 || seen.insert($0.element).inserted }.map(\.element)
        }
        return rows
    }

    /// Řádky pod sebou; záhlaví dalších souborů se vynechá, když je shodné s prvním.
    public static func appended(_ tables: [Spreadsheet.Table]) -> Spreadsheet.Table {
        guard var result = tables.first else { return [] }
        let header = result.first?.map { $0.trimmingCharacters(in: .whitespaces) }
        for table in tables.dropFirst() {
            var rows = table
            if let header, let first = rows.first, first.map({ $0.trimmingCharacters(in: .whitespaces) }) == header { rows.removeFirst() }
            result += rows
        }
        return result
    }

    static func delimiter(_ name: String?, ext: String) -> Character {
        switch name {
        case "comma": ","
        case "semicolon": ";"
        case "tab": "\t"
        default: ext == "tsv" ? "\t" : ","
        }
    }

    // MARK: Čištění

    static let cleanOptions: [ToolOption] = [
        .toggle("trim", "Oříznout mezery na krajích buněk", default: true),
        .toggle("emptyRows", "Odstranit prázdné řádky", default: true),
        .toggle("emptyColumns", "Odstranit prázdné sloupce", default: false),
        .toggle("duplicates", "Odstranit duplicitní řádky", default: false),
        .choice("delimiter", "Oddělovač (CSV)", [.init("keep", "Beze změny"), .init("comma", "Čárka"), .init("semicolon", "Středník (český Excel)"),
                                                  .init("tab", "Tabulátor")], default: "keep"),
        .toggle("bom", "UTF-8 s BOM (Excel pozná diakritiku)", default: false),
    ]

    public static let cleanTool = Tool(
        id: "sheet.tool.clean", title: "Vyčistit", symbol: "sparkles", options: cleanOptions,
        accepts: { $0.allNativeSheets },
        run: { context in
            var draft = CleanOptions()
            draft.trim = context.bool("trim") ?? true
            draft.removeEmptyRows = context.bool("emptyRows") ?? true
            draft.removeEmptyColumns = context.bool("emptyColumns") ?? false
            draft.removeDuplicates = context.bool("duplicates") ?? false
            let options = draft
            return try await EachImage.run(context, tag: "vyčištěno", outputExtension: { $0.pathExtension.lowercased() }) { source, output, progress in
                let sheets = try await Spreadsheet.load(source).map { Spreadsheet.Sheet(name: $0.name, rows: clean($0.rows, options)) }
                let ext = output.pathExtension.lowercased()
                if ext == "xlsx" {
                    try await OutputPolicy.withScratch(near: output.deletingLastPathComponent()) { scratch in
                        try await Spreadsheet.writeXLSX(sheets, to: output, workDirectory: scratch)
                    }
                } else {
                    var text = Spreadsheet.delimited(sheets.first?.rows ?? [], separator: delimiter(context.string("delimiter"), ext: ext))
                    if context.bool("bom") == true { text = "\u{FEFF}" + text }
                    try text.write(to: output, atomically: false, encoding: .utf8)
                }
                progress(1)
            }
        }
    )

    // MARK: Sloučení

    static let mergeOptions: [ToolOption] = [
        .choice("mode", "Jak", [.init("append", "Řádky pod sebou"), .init("sheets", "Každý soubor na vlastní list")], default: "append"),
        .choice("format", "Výsledek", [.init("xlsx", "XLSX"), .init("csv", "CSV")], default: "xlsx", visibleWhen: .init("mode", "append")),
    ]

    public static let mergeTool = Tool(
        id: "sheet.tool.merge", title: "Sloučit", symbol: "square.on.square", options: mergeOptions, editor: .order,
        needsMultiple: true,
        accepts: { $0.allNativeSheets },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            var sheetsPerFile: [[Spreadsheet.Sheet]] = []
            for url in urls { sheetsPerFile.append(try await Spreadsheet.load(url)) }
            let separate = context.string("mode") == "sheets"
            let csv = !separate && context.string("format") == "csv"
            let ext = csv ? "csv" : "xlsx"
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: ext, count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                if csv {
                    let merged = appended(sheetsPerFile.map { $0.first?.rows ?? [] })
                    try Spreadsheet.delimited(merged, separator: ",").write(to: temporary, atomically: false, encoding: .utf8)
                    return
                }
                let sheets: [Spreadsheet.Sheet]
                if separate {
                    var used = Set<String>()
                    sheets = zip(urls, sheetsPerFile).flatMap { url, file in
                        file.enumerated().map { index, sheet in
                            var name = file.count == 1 ? url.deletingPathExtension().lastPathComponent : "\(url.deletingPathExtension().lastPathComponent) – \(sheet.name)"
                            name = String(name.prefix(31))
                            var unique = name, counter = 2
                            while !used.insert(unique.lowercased()).inserted { unique = String(name.prefix(28)) + " \(counter)"; counter += 1 }
                            return Spreadsheet.Sheet(name: unique, rows: sheet.rows)
                        }
                    }
                } else {
                    sheets = [Spreadsheet.Sheet(name: "Sloučeno", rows: appended(sheetsPerFile.map { $0.first?.rows ?? [] }))]
                }
                try await OutputPolicy.withScratch(near: temporary.deletingLastPathComponent()) { scratch in
                    try await Spreadsheet.writeXLSX(sheets, to: temporary, workDirectory: scratch)
                }
            }
            context.progress(1)
            return [result]
        }
    )
}
