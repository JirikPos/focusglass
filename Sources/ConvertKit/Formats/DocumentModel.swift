import AppKit
import Foundation

/// Sémantická kostra dokumentu (nadpisy, odstavce, seznamy, kód) vytažená z NSAttributedString.
/// Z ní se píše Markdown a čisté XHTML pro EPUB.
public struct DocBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(Int)
        case paragraph
        case listItem(ordered: Bool, level: Int, number: Int)
        case code
        case rule
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var strike = false
        public var monospace = false
        public var link: URL?
    }

    public var kind: Kind
    public var runs: [Run]

    public var plainText: String { runs.map(\.text).joined() }
}

public enum DocumentModel {
    /// Rozdělí text na bloky. Nadpis = výrazně větší písmo než tělo textu (nebo krátký tučný řádek).
    public static func blocks(from attributed: NSAttributedString) -> [DocBlock] {
        let string = attributed.string as NSString
        guard string.length > 0 else { return [] }
        let body = bodyFontSize(attributed)
        var blocks: [DocBlock] = []
        var counters: [Int: Int] = [:]

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { text, range, _, _ in
            guard let text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                counters.removeAll()
                return
            }
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let runs = Self.runs(in: attributed, range: range)
            let maxSize = runs.isEmpty ? body : Self.maxFontSize(attributed, range: range)
            let allBold = !runs.isEmpty && runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let allMono = !runs.isEmpty && runs.allSatisfy { $0.monospace || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }

            if let lists = style?.textLists, let list = lists.last {
                let level = lists.count - 1
                let ordered = !["{disc}", "{circle}", "{square}", "{hyphen}", "{check}"].contains(list.markerFormat.rawValue)
                let number = (counters[level] ?? 0) + 1
                counters[level] = number
                counters = counters.filter { $0.key <= level }
                blocks.append(DocBlock(kind: .listItem(ordered: ordered, level: level, number: number),
                                       runs: stripListMarker(runs)))
                return
            }
            counters.removeAll()

            if trimmed.allSatisfy({ $0 == "—" || $0 == "-" || $0 == "_" }), trimmed.count >= 3 {
                blocks.append(DocBlock(kind: .rule, runs: []))
            } else if allMono {
                blocks.append(DocBlock(kind: .code, runs: [DocBlock.Run(text: text)]))
            } else if trimmed.count < 140, maxSize >= body * 1.7 {
                blocks.append(DocBlock(kind: .heading(1), runs: plain(runs)))
            } else if trimmed.count < 140, maxSize >= body * 1.35 {
                blocks.append(DocBlock(kind: .heading(2), runs: plain(runs)))
            } else if trimmed.count < 100, maxSize >= body * 1.12 || (allBold && trimmed.count < 80 && !trimmed.hasSuffix(".")) {
                blocks.append(DocBlock(kind: .heading(3), runs: plain(runs)))
            } else {
                blocks.append(DocBlock(kind: .paragraph, runs: runs))
            }
        }
        return mergeCode(blocks)
    }

    // MARK: Markdown

    public static func markdown(_ blocks: [DocBlock]) -> String {
        var lines: [String] = []
        var previous: DocBlock.Kind?
        for block in blocks {
            let separator: String
            switch (previous, block.kind) {
            case (.listItem?, .listItem): separator = "\n"
            case (nil, _): separator = ""
            default: separator = "\n\n"
            }
            let text: String
            switch block.kind {
            case .heading(let level): text = String(repeating: "#", count: level) + " " + inlineMarkdown(block.runs)
            case .paragraph: text = inlineMarkdown(block.runs)
            case .listItem(let ordered, let level, let number):
                text = String(repeating: "  ", count: level) + (ordered ? "\(number). " : "- ") + inlineMarkdown(block.runs)
            case .code: text = "```\n" + block.plainText + "\n```"
            case .rule: text = "---"
            }
            lines.append(separator + text)
            previous = block.kind
        }
        return lines.joined() + "\n"
    }

    static func inlineMarkdown(_ runs: [DocBlock.Run]) -> String {
        runs.map { run in
            var text = run.monospace ? "`\(run.text)`" : escapeMarkdown(run.text)
            // Formátování nesmí obalit mezery na krajích („** slovo**“ Markdown nepozná).
            let leading = String(text.prefix { $0 == " " })
            let trailing = String(text.reversed().prefix { $0 == " " })
            text = String(text.dropFirst(leading.count).dropLast(trailing.count))
            guard !text.isEmpty else { return leading + trailing }
            if !run.monospace {
                if run.bold && run.italic { text = "***\(text)***" }
                else if run.bold { text = "**\(text)**" }
                else if run.italic { text = "*\(text)*" }
                if run.strike { text = "~~\(text)~~" }
            }
            if let link = run.link { text = "[\(text)](\(link.absoluteString))" }
            return leading + text + trailing
        }.joined()
    }

    static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for char in text {
            if "\\`*_[]".contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }

    // MARK: NSAttributedString (pro DOCX, RTF)

    /// Bloky → formátovaný text se skutečnými nadpisy a seznamy (Word je pozná).
    public static func attributed(_ blocks: [DocBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12)
        for block in blocks {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            var base: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: style]
            var prefix = ""
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 22 : level == 2 ? 17 : 14
                base[.font] = NSFont(name: "Helvetica Neue Bold", size: size) ?? .boldSystemFont(ofSize: size)
                style.paragraphSpacingBefore = level == 1 ? 14 : 10
            case .listItem(let ordered, let level, let number):
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                style.textLists = [list]
                style.headIndent = CGFloat(level + 1) * 18
                style.firstLineHeadIndent = CGFloat(level) * 18
                style.paragraphSpacing = 2
                prefix = "\t" + (ordered ? "\(number)." : "•") + "\t"
            case .code:
                base[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case .rule, .paragraph:
                break
            }
            if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: base)) }
            if block.kind == .rule {
                result.append(NSAttributedString(string: "———", attributes: base))
            }
            for run in block.runs {
                var attributes = base
                var font = (base[.font] as? NSFont) ?? bodyFont
                var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
                if run.bold { traits.insert(.bold) }
                if run.italic { traits.insert(.italic) }
                if run.monospace { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                attributes[.font] = font
                if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        return result
    }

    // MARK: XHTML

    /// Tělo XHTML (bez `<html>`), dobře formované – pro EPUB.
    public static func xhtmlBody(_ blocks: [DocBlock]) -> String {
        var html: [String] = []
        var openLists: [Bool] = [] // ordered?

        func closeLists(to level: Int) {
            while openLists.count > level {
                html.append(openLists.removeLast() ? "</li></ol>" : "</li></ul>")
            }
        }

        for block in blocks {
            if case .listItem(let ordered, let level, _) = block.kind {
                if openLists.count == level + 1 {
                    html.append("</li>")
                } else if openLists.count > level + 1 {
                    closeLists(to: level + 1)
                    html.append("</li>")
                }
                while openLists.count < level + 1 {
                    openLists.append(ordered)
                    html.append(ordered ? "<ol>" : "<ul>")
                }
                html.append("<li>" + inlineHTML(block.runs))
                continue
            }
            closeLists(to: 0)
            switch block.kind {
            case .heading(let level): html.append("<h\(level)>\(inlineHTML(block.runs))</h\(level)>")
            case .paragraph: html.append("<p>\(inlineHTML(block.runs))</p>")
            case .code: html.append("<pre><code>\(Markdown.escape(block.plainText))</code></pre>")
            case .rule: html.append("<hr/>")
            case .listItem: break
            }
        }
        closeLists(to: 0)
        return html.joined(separator: "\n")
    }

    static func inlineHTML(_ runs: [DocBlock.Run]) -> String {
        runs.map { run in
            var text = Markdown.escape(run.text)
            if run.monospace { text = "<code>\(text)</code>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.strike { text = "<del>\(text)</del>" }
            if let link = run.link { text = "<a href=\"\(Markdown.escape(link.absoluteString))\">\(text)</a>" }
            return text
        }.joined()
    }

    // MARK: Pomocné

    static func runs(in attributed: NSAttributedString, range: NSRange) -> [DocBlock.Run] {
        var runs: [DocBlock.Run] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
                .replacingOccurrences(of: "\u{2028}", with: " ")
                .replacingOccurrences(of: "\u{FFFC}", with: "") // přílohy (obrázky)
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            var run = DocBlock.Run(text: text)
            run.bold = traits.contains(.bold)
            run.italic = traits.contains(.italic)
            run.monospace = traits.contains(.monoSpace)
            run.strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            if let url = attributes[.link] as? URL { run.link = url }
            else if let string = attributes[.link] as? String { run.link = URL(string: string) }
            // Sloučit se sousedem se stejným formátem.
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.strike == run.strike,
               last.monospace == run.monospace, last.link == run.link {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    private static func plain(_ runs: [DocBlock.Run]) -> [DocBlock.Run] {
        [DocBlock.Run(text: runs.map(\.text).joined().trimmingCharacters(in: .whitespaces))]
    }

    /// NSAttributedString z HTML/DOCX vkládá znak odrážky „•\t“ do textu – v Markdownu by se zdvojil.
    private static func stripListMarker(_ runs: [DocBlock.Run]) -> [DocBlock.Run] {
        guard var first = runs.first else { return runs }
        let text = first.text
        if let tab = text.firstIndex(of: "\t"), text.distance(from: text.startIndex, to: tab) <= 6 {
            first.text = String(text[text.index(after: tab)...])
        }
        return [first] + runs.dropFirst()
    }

    private static func mergeCode(_ blocks: [DocBlock]) -> [DocBlock] {
        var result: [DocBlock] = []
        for block in blocks {
            if block.kind == .code, let last = result.last, last.kind == .code {
                result[result.count - 1].runs = [DocBlock.Run(text: last.plainText + "\n" + block.plainText)]
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// Nejčastější velikost písma (vážená počtem znaků) = tělo textu.
    static func bodyFontSize(_ attributed: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            counts[size.rounded(), default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    static func maxFontSize(_ attributed: NSAttributedString, range: NSRange) -> CGFloat {
        var size: CGFloat = 0
        attributed.enumerateAttribute(.font, in: range) { value, _, _ in
            size = max(size, (value as? NSFont)?.pointSize ?? 0)
        }
        return size
    }
}
