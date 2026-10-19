import AppKit
import Foundation
import NaturalLanguage

extension Selection {
    /// Dokumenty, které umíme číst i zapisovat sami.
    var allEditableDocuments: Bool {
        !isEmpty && zip(urls, kinds).allSatisfy { $1 == .document && DocumentTools.editable.contains($0.pathExtension.lowercased()) }
    }
}

/// Statistika textu: slova, znaky, věty, odstavce, čas čtení, nejčastější slova.
public enum TextStats {
    public struct Result: Sendable, Equatable {
        public var words = 0
        public var characters = 0
        public var charactersNoSpaces = 0
        public var sentences = 0
        public var paragraphs = 0
        public var topWords: [(word: String, count: Int)] = []

        public static func == (a: Result, b: Result) -> Bool {
            a.words == b.words && a.characters == b.characters && a.charactersNoSpaces == b.charactersNoSpaces
                && a.sentences == b.sentences && a.paragraphs == b.paragraphs && a.topWords.map(\.word) == b.topWords.map(\.word)
        }

        /// Čtení 200 slov za minutu, mluvení 130.
        public var readingMinutes: Double { Double(words) / 200 }
        public var speakingMinutes: Double { Double(words) / 130 }
    }

    public static func compute(_ text: String) -> Result {
        var result = Result()
        result.characters = text.count
        result.charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        result.paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

        var counts: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            // Číslice a samostatné znaky se za slova nepočítají.
            guard word.contains(where: \.isLetter) else { return true }
            result.words += 1
            let lower = word.lowercased()
            if lower.count > 3 { counts[lower, default: 0] += 1 }
            return true
        }
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Prázdné řádky mezi odstavci nejsou věty.
            if text[range].contains(where: \.isLetter) { result.sentences += 1 }
            return true
        }
        result.topWords = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(10).map { ($0.key, $0.value) }
        return result
    }

    public static func report(_ stats: Result, name: String) -> String {
        func minutes(_ value: Double) -> String { value < 1 ? "méně než minuta" : "\(Int(value.rounded())) min" }
        var lines = [
            "Statistiky: \(name)", "",
            "Slov: \(stats.words)",
            "Znaků: \(stats.characters) (bez mezer \(stats.charactersNoSpaces))",
            "Vět: \(stats.sentences)",
            "Odstavců: \(stats.paragraphs)",
            "Čas čtení: \(minutes(stats.readingMinutes))",
            "Čas mluvení: \(minutes(stats.speakingMinutes))",
        ]
        if !stats.topWords.isEmpty {
            lines += ["", "Nejčastější slova:"] + stats.topWords.map { "  \($0.word) – \($0.count)×" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum DocumentTools {
    static let editable: Set<String> = ["docx", "doc", "rtf", "odt", "txt", "text", "md", "markdown", "html", "htm"]
    static let plainText: Set<String> = ["txt", "text", "md", "markdown", "html", "htm"]

    /// Přípona výsledku se stejným formátem (DOC se zapisuje jako DOCX – starý formát zapisovat neumíme).
    @Sendable static func sameFormat(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext == "doc" ? "docx" : (ext == "text" ? "txt" : (ext == "markdown" ? "md" : (ext == "htm" ? "html" : ext)))
    }

    // MARK: Statistiky

    public static let statsTool = Tool(
        id: "document.tool.stats", title: "Statistiky", symbol: "textformat.123",
        accepts: { $0.allEditableDocuments },
        run: { context in
            try await EachImage.run(context, tag: "statistiky", outputExtension: { _ in "txt" }) { source, output, progress in
                let attributed = try await TextBackend.load(source, workDirectory: output.deletingLastPathComponent())
                let text = Unchecked(attributed).value.string
                let stats = TextStats.compute(text)
                try TextStats.report(stats, name: source.lastPathComponent).write(to: output, atomically: false, encoding: .utf8)
                progress(1)
            }
        }
    )

    // MARK: Najít a nahradit

    static let replaceOptions: [ToolOption] = [
        .text("find", "Najít", placeholder: "hledaný text"),
        .text("replace", "Nahradit", placeholder: "nový text (prázdné = smazat)"),
        .toggle("caseSensitive", "Rozlišovat velikost písmen", default: false),
        .toggle("regex", "Regulární výraz", default: false, help: "V náhradě lze použít $1, $2…"),
    ]

    /// Regulární výraz z hledaného textu (nebo doslovný).
    static func pattern(_ find: String, regex: Bool, caseSensitive: Bool) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: regex ? find : NSRegularExpression.escapedPattern(for: find),
                                           options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw ConvertError.unsupportedInput("neplatný regulární výraz „\(find)“")
        }
    }

    /// Nahradí v čistém textu; vrací nový text a počet nahrazení.
    public static func replace(in text: String, find: String, with replacement: String, regex: Bool, caseSensitive: Bool) throws -> (String, Int) {
        let expression = try pattern(find, regex: regex, caseSensitive: caseSensitive)
        let range = NSRange(text.startIndex..., in: text)
        let count = expression.numberOfMatches(in: text, range: range)
        let template = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return (expression.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }

    /// Nahradí ve formátovaném textu a zachová formátování okolí.
    static func replace(in attributed: NSMutableAttributedString, find: String, with replacement: String, regex: Bool, caseSensitive: Bool) throws -> Int {
        let expression = try pattern(find, regex: regex, caseSensitive: caseSensitive)
        let matches = expression.matches(in: attributed.string, range: NSRange(location: 0, length: attributed.length))
        let template = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        // Od konce, ať se dřívější pozice nehýbou.
        for match in matches.reversed() {
            let text = expression.replacementString(for: match, in: attributed.string, offset: 0, template: template)
            let attributes = attributed.length > 0 ? attributed.attributes(at: min(match.range.location, attributed.length - 1), effectiveRange: nil) : [:]
            attributed.replaceCharacters(in: match.range, with: NSAttributedString(string: text, attributes: attributes))
        }
        return matches.count
    }

    public static let replaceTool = Tool(
        id: "document.tool.replace", title: "Nahradit", symbol: "text.magnifyingglass", options: replaceOptions,
        accepts: { $0.allEditableDocuments },
        run: { context in
            let find = context.string("find") ?? ""
            let replacement = context.string("replace") ?? ""
            guard !find.isEmpty else { throw ConvertError.unsupportedInput("vyplň, co hledat") }
            let regex = context.bool("regex") ?? false
            let caseSensitive = context.bool("caseSensitive") ?? false
            return try await EachImage.run(context, tag: "upraveno", outputExtension: sameFormat) { source, output, progress in
                let ext = source.pathExtension.lowercased()
                var count = 0
                if plainText.contains(ext) {
                    let (text, found) = try replace(in: try TextBackend.readText(source), find: find, with: replacement, regex: regex, caseSensitive: caseSensitive)
                    count = found
                    if count > 0 { try text.write(to: output, atomically: false, encoding: .utf8) }
                } else {
                    let loaded = Unchecked(try await TextBackend.load(source, workDirectory: output.deletingLastPathComponent()))
                    let mutable = Unchecked(NSMutableAttributedString(attributedString: loaded.value))
                    count = try replace(in: mutable.value, find: find, with: replacement, regex: regex, caseSensitive: caseSensitive)
                    if count > 0 {
                        let format = ImageBackend.format(forExtension: ext) ?? Format(ext, ext.uppercased())
                        try await TextBackend.write(mutable.value, title: source.deletingPathExtension().lastPathComponent, to: output,
                                                    format: Format(sameFormat(source), format.label), workDirectory: output.deletingLastPathComponent())
                    }
                }
                guard count > 0 else { throw ConvertError.unsupportedInput("\(source.lastPathComponent) – „\(find)“ se nenašlo") }
                progress(1)
            }
        }
    )

    // MARK: Sloučení

    static let mergeOptions: [ToolOption] = [
        .choice("format", "Výsledek", [.init("docx", "DOCX"), .init("md", "Markdown"), .init("txt", "Prostý text"), .init("pdf", "PDF")], default: "docx"),
        .choice("separator", "Mezi dokumenty", [.init("blank", "Prázdný řádek"), .init("rule", "Vodorovná čára"), .init("none", "Nic")], default: "blank"),
    ]

    public static let mergeTool = Tool(
        id: "document.tool.merge", title: "Sloučit", symbol: "square.on.square", options: mergeOptions, editor: .order,
        needsMultiple: true,
        accepts: { $0.allEditableDocuments },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            let format = Format(context.string("format") ?? "docx", (context.string("format") ?? "docx").uppercased())
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: format.ext, count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                let merged = Unchecked(NSMutableAttributedString())
                let separator: String = switch context.string("separator") {
                case "rule": "\n\n――――――――――――\n\n"
                case "none": "\n"
                default: "\n\n"
                }
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    let part = Unchecked(try await TextBackend.load(url, workDirectory: temporary.deletingLastPathComponent()))
                    if index > 0 { merged.value.append(NSAttributedString(string: separator, attributes: [.font: NSFont.systemFont(ofSize: 12)])) }
                    merged.value.append(part.value)
                    context.progress(Double(index + 1) / Double(urls.count) * 0.9)
                }
                try await TextBackend.write(merged.value, title: urls[0].deletingPathExtension().lastPathComponent, to: temporary,
                                            format: format, workDirectory: temporary.deletingLastPathComponent())
            }
            context.progress(1)
            return [result]
        }
    )
}
