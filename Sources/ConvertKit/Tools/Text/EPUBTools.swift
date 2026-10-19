import Foundation
import ImageIO

extension Selection {
    var allEPUBs: Bool { !isEmpty && kinds.allSatisfy { $0 == .epub } }
}

/// Čtení a úprava metadat e-knihy (název, autor, jazyk, obálka).
public enum EPUBMeta {
    public struct Info: Sendable, Equatable {
        public var title = ""
        public var author = ""
        public var language = ""
        public var hasCover = false
    }

    struct Package {
        let opfURL: URL
        let document: XMLDocument
    }

    static func locate(in folder: URL) throws -> Package {
        let container = try Data(contentsOf: folder.appendingPathComponent("META-INF/container.xml"))
        guard let path = XMLAttributes.first(element: "rootfile", attribute: "full-path", in: container) else {
            throw ConvertError.unreadable("EPUB bez content.opf")
        }
        let url = folder.appendingPathComponent(path)
        return Package(opfURL: url, document: try XMLDocument(data: try Data(contentsOf: url), options: [.nodePreserveAll]))
    }

    static func nodes(_ document: XMLDocument, _ localName: String) -> [XMLNode] {
        (try? document.nodes(forXPath: "//*[local-name()='\(localName)']")) ?? []
    }

    static func info(of package: Package) -> Info {
        var info = Info()
        info.title = nodes(package.document, "title").first?.stringValue ?? ""
        info.author = nodes(package.document, "creator").first?.stringValue ?? ""
        info.language = nodes(package.document, "language").first?.stringValue ?? ""
        info.hasCover = nodes(package.document, "item").contains {
            ($0 as? XMLElement)?.attribute(forName: "properties")?.stringValue?.contains("cover-image") == true
        } || nodes(package.document, "meta").contains { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue == "cover" }
        return info
    }

    public static func read(_ url: URL, workDirectory: URL) async throws -> Info {
        let folder = workDirectory.appendingPathComponent("epub-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Zip.extract(url, to: folder)
        return info(of: try locate(in: folder))
    }

    /// Prázdná pole se nemění. `cover` je obrázek (JPG nebo PNG).
    public static func write(source: URL, to output: URL, title: String?, author: String?, language: String?, cover: URL?,
                             workDirectory: URL) async throws {
        let folder = workDirectory.appendingPathComponent("epub-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Zip.extract(source, to: folder)
        let package = try locate(in: folder)
        let document = package.document
        guard let metadata = nodes(document, "metadata").first as? XMLElement else { throw ConvertError.unreadable(source.lastPathComponent) }

        func set(_ name: String, _ value: String?) {
            guard let value, !value.trimmed.isEmpty else { return }
            if let existing = nodes(document, name).first(where: { $0.parent === metadata }) as? XMLElement {
                existing.stringValue = value.trimmed
            } else {
                metadata.addChild(XMLElement(name: "dc:\(name)", stringValue: value.trimmed))
            }
        }
        set("title", title)
        set("creator", author)
        set("language", language)

        if let cover {
            guard let image = try? ImageBackend.load(cover, maxPixel: 2400) else { throw ConvertError.unreadable(cover.lastPathComponent) }
            let isPNG = cover.pathExtension.lowercased() == "png"
            let fileName = isPNG ? "cover.png" : "cover.jpg"
            try ImageBackend.encode(image, as: isPNG ? .png : .jpg, quality: 0.9)
                .write(to: package.opfURL.deletingLastPathComponent().appendingPathComponent(fileName))
            guard let manifest = nodes(document, "manifest").first as? XMLElement else { throw ConvertError.unreadable(source.lastPathComponent) }
            // Naše dřívější obálka se smaže celá (jinak by vzniklo duplicitní ID); cizí obálka jen přestane být obálkou.
            for item in nodes(document, "item") {
                guard let element = item as? XMLElement else { continue }
                if element.attribute(forName: "id")?.stringValue == "fg-cover-image" {
                    if let href = element.attribute(forName: "href")?.stringValue {
                        try? FileManager.default.removeItem(at: package.opfURL.deletingLastPathComponent().appendingPathComponent(href))
                    }
                    element.detach()
                    continue
                }
                guard let properties = element.attribute(forName: "properties")?.stringValue, properties.contains("cover-image") else { continue }
                let rest = properties.split(separator: " ").filter { $0 != "cover-image" }.joined(separator: " ")
                if rest.isEmpty { element.removeAttribute(forName: "properties") } else { element.addAttribute(XMLNode.attribute(withName: "properties", stringValue: rest) as! XMLNode) }
            }
            let item = XMLElement(name: "item")
            for (key, value) in [("id", "fg-cover-image"), ("href", fileName), ("media-type", isPNG ? "image/png" : "image/jpeg"), ("properties", "cover-image")] {
                item.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
            }
            manifest.addChild(item)
            // EPUB 2 čtečky hledají `<meta name="cover" content="id">`.
            for old in nodes(document, "meta") where (old as? XMLElement)?.attribute(forName: "name")?.stringValue == "cover" { old.detach() }
            let meta = XMLElement(name: "meta")
            meta.addAttribute(XMLNode.attribute(withName: "name", stringValue: "cover") as! XMLNode)
            meta.addAttribute(XMLNode.attribute(withName: "content", stringValue: "fg-cover-image") as! XMLNode)
            metadata.addChild(meta)
        }

        try document.xmlData(options: [.nodePreserveAll]).write(to: package.opfURL)
        try await Zip.archiveContents(of: folder, to: output, storedFirst: "mimetype")
    }

    static let options: [ToolOption] = [
        .text("title", "Název"),
        .text("author", "Autor"),
        .text("language", "Jazyk", placeholder: "cs"),
        .file("cover", "Obálka", extensions: ["jpg", "jpeg", "png"]),
    ]

    public static let tool = Tool(
        id: "epub.tool.metadata", title: "Metadata", symbol: "book.closed", options: options,
        accepts: { $0.allEPUBs },
        run: { context in
            func value(_ key: String) -> String? { let text = (context.string(key) ?? "").trimmed; return text.isEmpty ? nil : text }
            let title = value("title"), author = value("author"), language = value("language")
            let cover = value("cover").map { URL(fileURLWithPath: $0) }
            guard title != nil || author != nil || language != nil || cover != nil else {
                throw ConvertError.unsupportedInput("vyplň aspoň jedno pole")
            }
            return try await EachImage.run(context, tag: "metadata", outputExtension: { _ in "epub" }) { source, output, progress in
                try await write(source: source, to: output, title: title, author: author, language: language,
                                cover: cover, workDirectory: output.deletingLastPathComponent())
                progress(1)
            }
        }
    )
}
