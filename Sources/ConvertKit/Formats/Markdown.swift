import Foundation

/// Markdown ↔ HTML bez závislostí. Podporuje běžnou podmnožinu CommonMark + GFM:
/// nadpisy, odstavce, tučné/kurzíva/přeškrtnutí, kód (řádkový i bloky), odkazy, obrázky,
/// odrážky a číslované seznamy (vnořené), citace, vodorovné čáry a tabulky.
public enum Markdown {
    // MARK: Markdown → HTML

    public static func html(from markdown: String, title: String? = nil) -> String {
        let body = renderBlocks(markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return document(body: body, title: title)
    }

    public static func document(body: String, title: String?) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title ?? ""))</title></head>
        <body>
        \(body)
        </body></html>
        """
    }

    static func renderBlocks(_ lines: [String]) -> String {
        var html: [String] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Řádek končící „\“ nebo dvěma mezerami = zalomení, jinak se řádky slévají (CommonMark).
            let joined = paragraph.enumerated().map { index, line -> String in
                guard index < paragraph.count - 1 else { return inline(line.trimmingCharacters(in: .whitespaces)) }
                let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
                let text = inline(line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\\")))
                return text + (hard ? "<br/>" : " ")
            }.joined()
            html.append("<p>\(joined)</p>")
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // Blok kódu ```
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                html.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // Nadpis
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.dropFirst(heading).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                html.append("<h\(heading)>\(inline(text))</h\(heading)>")
                index += 1
                continue
            }
            // Setext nadpis (podtržení === / ---)
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let level = trimmed.first == "=" ? 1 : 2
                let text = paragraph.joined(separator: " ")
                paragraph.removeAll()
                html.append("<h\(level)>\(inline(text))</h\(level)>")
                index += 1
                continue
            }
            // Vodorovná čára
            if isRule(trimmed) {
                flushParagraph()
                html.append("<hr/>")
                index += 1
                continue
            }
            // Citace
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingPrefix(" "))
                    index += 1
                }
                html.append("<blockquote>\(renderBlocks(quoted))</blockquote>")
                continue
            }
            // Tabulka (řádek s | a pod ním oddělovač)
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                var table = "<table>\n<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows {
                    table += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                }
                html.append(table + "</tbody></table>")
                continue
            }
            // Seznam
            if listMarker(line) != nil {
                flushParagraph()
                let (list, consumed) = renderList(lines, from: index)
                html.append(list)
                index = consumed
                continue
            }
            paragraph.append(line.drop(while: { $0 == " " || $0 == "\t" }).description)
            index += 1
        }
        flushParagraph()
        return html.joined(separator: "\n")
    }

    /// Seznam od řádku `start`; vrací HTML a index prvního řádku za seznamem.
    static func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = listMarker(lines[start]) else { return ("", start + 1) }
        let tag = first.ordered ? "ol" : "ul"
        var items: [String] = []
        var index = start
        while index < lines.count, let marker = listMarker(lines[index]), marker.indent == first.indent,
              marker.ordered == first.ordered {
            var content = [marker.text]
            index += 1
            // Pokračování a vnořené seznamy (víc odsazené řádky).
            var nested: [String] = []
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                let indent = next.prefix { $0 == " " || $0 == "\t" }.count
                if indent > first.indent {
                    nested.append(String(next.dropFirst(min(indent, first.indent + 2))))
                    index += 1
                } else if listMarker(next) == nil, nested.isEmpty {
                    content.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                } else {
                    break
                }
            }
            var item = inline(content.joined(separator: " "))
            if let task = taskPrefix(item) { item = task }
            if !nested.isEmpty { item += "\n" + renderBlocks(nested) }
            items.append("<li>\(item)</li>")
        }
        return ("<\(tag)>\n" + items.joined(separator: "\n") + "\n</\(tag)>", index)
    }

    private static func taskPrefix(_ text: String) -> String? {
        if text.hasPrefix("[ ] ") { return "☐ " + text.dropFirst(4) }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return "☑ " + text.dropFirst(4) }
        return nil
    }

    struct ListMarker: Equatable {
        let indent: Int
        let ordered: Bool
        let text: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ListMarker(indent: indent, ordered: false, text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 10 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " {
                return ListMarker(indent: indent, ordered: true, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Řádkové formátování: `kód`, **tučně**, *kurzíva*, ~~škrtnuto~~, [odkaz](url), ![obrázek](url).
    static func inline(_ text: String) -> String {
        // Kód nejdřív (uvnitř se nic neformátuje) – nahradit zástupnými znaky.
        var codes: [String] = []
        var work = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            work += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "`") else {
                work += rest[open...]
                rest = ""
                break
            }
            codes.append("<code>\(escape(String(after[..<close])))</code>")
            work += "\u{0}\(codes.count - 1)\u{0}"
            rest = after[after.index(after: close)...]
        }
        work += rest
        var html = escape(work)
        html = replace(html, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, "<img src=\"$2\" alt=\"$1\"/>")
        html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, "<a href=\"$2\">$1</a>")
        html = replace(html, #"(?<![\w*])\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "<strong>$1</strong>")
        html = replace(html, #"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#, "<strong>$1</strong>")
        html = replace(html, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?!\*)"#, "<em>$1</em>")
        html = replace(html, #"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"#, "<em>$1</em>")
        html = replace(html, #"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>")
        html = replace(html, #"(?<!["=>])(https?://[^\s<]+[^\s<.,;:!?)])"#, "<a href=\"$1\">$1</a>")
        for (index, code) in codes.enumerated() {
            html = html.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: code)
        }
        return html
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
