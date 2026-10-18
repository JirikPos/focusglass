import Foundation

/// EPUB 3: zápis z XHTML kapitol a čtení do jednoho HTML.
public enum EPUB {
    public struct Chapter: Sendable {
        public let title: String
        public let body: String // dobře formované XHTML bez <html>/<body>
    }

    /// Rozdělí tělo podle `<h1>` na kapitoly (bez nadpisů = jedna kapitola).
    public static func chapters(fromBody body: String, fallbackTitle: String) -> [Chapter] {
        let parts = body.components(separatedBy: "<h1>")
        var chapters: [Chapter] = []
        if let lead = parts.first, !lead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chapters.append(Chapter(title: fallbackTitle, body: lead))
        }
        for part in parts.dropFirst() {
            let title = part.components(separatedBy: "</h1>").first.map(stripTags) ?? fallbackTitle
            chapters.append(Chapter(title: title.isEmpty ? fallbackTitle : title, body: "<h1>" + part))
        }
        return chapters.isEmpty ? [Chapter(title: fallbackTitle, body: "<p></p>")] : chapters
    }

    /// Zapíše EPUB 3 (s navigací pro EPUB 2 čtečky).
    public static func write(title: String, author: String? = nil, language: String = "cs",
                             chapters: [Chapter], to output: URL, workDirectory: URL) async throws {
        let root = workDirectory.appendingPathComponent("epub-\(UUID().uuidString)")
        let fm = FileManager.default
        let oebps = root.appendingPathComponent("OEBPS")
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try "application/epub+zip".write(to: root.appendingPathComponent("mimetype"), atomically: false, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: false, encoding: .utf8)

        let css = "body{font-family:serif;line-height:1.5;margin:0 5%}h1,h2,h3{font-family:sans-serif;line-height:1.2}pre{white-space:pre-wrap;font-size:.9em}table{border-collapse:collapse}td,th{border:1px solid #999;padding:.2em .4em}"
        try css.write(to: oebps.appendingPathComponent("style.css"), atomically: false, encoding: .utf8)

        let t = Markdown.escape(title)
        for (index, chapter) in chapters.enumerated() {
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)">
            <head><meta charset="utf-8"/><title>\(Markdown.escape(chapter.title))</title><link rel="stylesheet" href="style.css"/></head>
            <body>
            \(chapter.body)
            </body></html>
            """.write(to: oebps.appendingPathComponent("chapter\(index + 1).xhtml"), atomically: false, encoding: .utf8)
        }

        let navItems = chapters.enumerated().map {
            "<li><a href=\"chapter\($0.offset + 1).xhtml\">\(Markdown.escape($0.element.title))</a></li>"
        }.joined(separator: "\n")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
        <head><meta charset="utf-8"/><title>\(t)</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Obsah</h1><ol>
        \(navItems)
        </ol></nav></body></html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: false, encoding: .utf8)

        let identifier = "urn:uuid:\(UUID().uuidString)"
        let ncxPoints = chapters.enumerated().map {
            """
            <navPoint id="p\($0.offset + 1)" playOrder="\($0.offset + 1)"><navLabel><text>\(Markdown.escape($0.element.title))</text></navLabel><content src="chapter\($0.offset + 1).xhtml"/></navPoint>
            """
        }.joined(separator: "\n")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(identifier)"/></head>
        <docTitle><text>\(t)</text></docTitle>
        <navMap>
        \(ncxPoints)
        </navMap></ncx>
        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: false, encoding: .utf8)

        let manifest = chapters.indices.map {
            "<item id=\"c\($0 + 1)\" href=\"chapter\($0 + 1).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = chapters.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }.joined(separator: "\n")
        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(language)">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="uid">\(identifier)</dc:identifier>
          <dc:title>\(t)</dc:title>
          <dc:language>\(language)</dc:language>
          \(author.map { "<dc:creator>\(Markdown.escape($0))</dc:creator>" } ?? "")
          <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="css" href="style.css" media-type="text/css"/>
        \(manifest)
        </manifest>
        <spine toc="ncx">
        \(spine)
        </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: false, encoding: .utf8)

        try await Zip.archiveContents(of: root, to: output, storedFirst: "mimetype")
    }

    // MARK: Čtení

    /// Text knihy jako jedno HTML (kapitoly v pořadí čtení).
    public static func readHTML(_ url: URL, workDirectory: URL) async throws -> (title: String?, html: String) {
        let folder = workDirectory.appendingPathComponent("epub-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Zip.extract(url, to: folder)

        let container = try Data(contentsOf: folder.appendingPathComponent("META-INF/container.xml"))
        guard let opfPath = XMLAttributes.first(element: "rootfile", attribute: "full-path", in: container) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let opfURL = folder.appendingPathComponent(opfPath)
        let opf = try Data(contentsOf: opfURL)
        let package = OPFParser.parse(opf)
        let base = opfURL.deletingLastPathComponent()

        var bodies: [String] = []
        for idref in package.spine {
            guard let href = package.manifest[idref]?.removingPercentEncoding else { continue }
            let file = base.appendingPathComponent(href)
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            bodies.append(Self.body(of: text))
        }
        guard !bodies.isEmpty else { throw ConvertError.unreadable(url.lastPathComponent) }
        return (package.title, Markdown.document(body: bodies.joined(separator: "\n"), title: package.title))
    }

    /// Obsah `<body>…</body>`; obrázky (relativní cesty) se vynechají.
    static func body(of xhtml: String) -> String {
        var content = xhtml
        if let open = xhtml.range(of: "<body", options: .caseInsensitive),
           let openEnd = xhtml[open.upperBound...].firstIndex(of: ">"),
           let close = xhtml.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            content = String(xhtml[xhtml.index(after: openEnd)..<close.lowerBound])
        }
        return content.replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<image[^>]*>"#, with: "", options: .regularExpression)
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Manifest, spine a název z content.opf.
private final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    var title: String?
    private var inTitle = false
    private var buffer = ""

    static func parse(_ data: Data) -> OPFParser {
        let handler = OPFParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = handler
        parser.parse()
        return handler
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"] != "no" { spine.append(idref) }
        case "title":
            if title == nil { inTitle = true; buffer = "" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "title", inTitle {
            title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            inTitle = false
        }
    }
}

/// První hodnota atributu daného elementu v XML.
enum XMLAttributes {
    static func first(element: String, attribute: String, in data: Data) -> String? {
        final class Finder: NSObject, XMLParserDelegate {
            let element: String
            let attribute: String
            var value: String?
            init(element: String, attribute: String) {
                self.element = element
                self.attribute = attribute
            }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == element, value == nil, let found = attributes[attribute] {
                    value = found
                    parser.abortParsing()
                }
            }
        }
        let finder = Finder(element: element, attribute: attribute)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = finder
        parser.parse()
        return finder.value
    }
}
