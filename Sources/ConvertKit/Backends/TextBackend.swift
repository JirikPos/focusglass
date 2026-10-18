import AppKit
import Foundation

/// Textové dokumenty přes NSAttributedString (DOCX, DOC, RTF, RTFD, ODT, HTML, TXT),
/// Markdown a EPUB vlastními převodníky.
public enum TextBackend {
    public static let readable: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "html", "htm", "textclipping", "epub",
    ]

    /// Jakýkoli čitelný dokument → cílový formát.
    public static let convert: Converter = { job in
        let ext = job.source.pathExtension.lowercased()
        let title = job.source.deletingPathExtension().lastPathComponent
        job.progress(0.1)

        // Markdown → HTML / EPUB bez oklik přes NSAttributedString (zachová tabulky a kód).
        if ["md", "markdown"].contains(ext), ["html", "epub"].contains(job.target.id) {
            let markdown = try readText(job.source)
            if job.target == .html {
                try Markdown.html(from: markdown, title: title).write(to: job.file, atomically: false, encoding: .utf8)
            } else {
                let body = Markdown.renderBlocks(markdown.components(separatedBy: "\n"))
                try await EPUB.write(title: title, chapters: EPUB.chapters(fromBody: body, fallbackTitle: title),
                                     to: job.file, workDirectory: job.scratch)
            }
            job.progress(1)
            return job.file
        }

        let attributed = try await load(job.source, workDirectory: job.scratch)
        job.progress(0.6)
        try await write(attributed, title: title, to: job.file, format: job.target, workDirectory: job.scratch)
        job.progress(1)
        return job.file
    }

    // MARK: Čtení

    public static func load(_ url: URL, workDirectory: URL) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "text":
            return plain(try readText(url))
        case "md", "markdown":
            return try await fromHTML(Markdown.html(from: try readText(url)))
        case "html", "htm":
            return try await fromHTML(try readText(url), baseURL: url.deletingLastPathComponent())
        case "textclipping":
            return try clipping(url)
        case "epub":
            return try await fromHTML(try await EPUB.readHTML(url, workDirectory: workDirectory).html)
        default:
            let type: NSAttributedString.DocumentType? = switch ext {
            case "docx": .officeOpenXML
            case "doc": .docFormat
            case "odt": .openDocument
            case "rtf": .rtf
            case "rtfd": .rtfd
            default: nil
            }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let type { options[.documentType] = type }
            do {
                return try NSAttributedString(url: url, options: options, documentAttributes: nil)
            } catch {
                throw ConvertError.unreadable(url.lastPathComponent)
            }
        }
    }

    /// Text v UTF-8, případně v jiném rozpoznaném kódování (Windows-1250 apod.).
    public static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ConvertError.unreadable(url.lastPathComponent) }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    /// HTML import používá WebKit – musí běžet na hlavním vlákně. Vzdálené obrázky se nenačítají.
    static func fromHTML(_ html: String, baseURL: URL? = nil) async throws -> NSAttributedString {
        let offline = html.replacingOccurrences(of: #"<img[^>]+src=["']https?://[^>]*>"#, with: "", options: .regularExpression)
        let data = Data(offline.utf8)
        // NSAttributedString není Sendable; po vytvoření se už nemění, přenos mezi vlákny je bezpečný.
        return try await MainActor.run { () throws -> Unchecked<NSAttributedString> in
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .timeout: 10,
            ]
            if let baseURL { options[.baseURL] = baseURL }
            do {
                return Unchecked(try NSAttributedString(data: data, options: options, documentAttributes: nil))
            } catch {
                throw ConvertError.unreadable("HTML")
            }
        }.value
    }

    /// Textový výstřižek (.textClipping) = plist s daty pod klíči UTI.
    static func clipping(_ url: URL) throws -> NSAttributedString {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["UTI-Data"] as? [String: Any] else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        if let rtf = items["public.rtf"] as? Data,
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil) {
            return attributed
        }
        if let text = items["public.utf8-plain-text"] as? String { return plain(text) }
        if let data = items["public.utf8-plain-text"] as? Data { return plain(String(decoding: data, as: UTF8.self)) }
        if let text = items["public.utf16-plain-text"] as? String { return plain(text) }
        throw ConvertError.unreadable(url.lastPathComponent)
    }

    // MARK: Zápis

    public static func write(_ attributed: NSAttributedString, title: String, to url: URL, format: Format,
                             workDirectory: URL) async throws {
        let range = NSRange(location: 0, length: attributed.length)
        switch format.id {
        case "txt":
            try attributed.string.write(to: url, atomically: false, encoding: .utf8)
        case "md":
            try DocumentModel.markdown(DocumentModel.blocks(from: attributed)).write(to: url, atomically: false, encoding: .utf8)
        case "epub":
            let body = DocumentModel.xhtmlBody(DocumentModel.blocks(from: attributed))
            try await EPUB.write(title: title, chapters: EPUB.chapters(fromBody: body, fallbackTitle: title),
                                 to: url, workDirectory: workDirectory)
        default:
            let type: NSAttributedString.DocumentType = switch format.id {
            case "docx": .officeOpenXML
            case "rtf": .rtf
            case "odt": .openDocument
            case "html": .html
            default: throw ConvertError.unsupportedInput(url.lastPathComponent)
            }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            attributes[.title] = title
            if type == .html {
                // Bez absolutních velikostí písma v pt – čitelné v prohlížeči.
                attributes[.excludedElements] = ["font", "doctype"]
            }
            let data: Data
            do {
                data = try attributed.data(from: range, documentAttributes: attributes)
            } catch {
                throw ConvertError.writeFailed(url.lastPathComponent)
            }
            try data.write(to: url)
        }
    }
}

/// Obal pro neměnné objekty, které nejsou označené jako Sendable.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
