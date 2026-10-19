import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Quartz

extension Selection {
    var allPDFs: Bool { !isEmpty && kinds.allSatisfy { $0 == .pdf } }
}

/// Společné pomůcky PDF nástrojů.
enum PDFTools {
    /// Po jednom PDF z výběru: jméno výsledku „x (štítek).pdf“, atomický zápis, průběh.
    static func each(
        _ context: OperationContext, tag: String, password: String? = nil,
        _ work: @Sendable (_ document: PDFDocument, _ source: URL, _ output: URL, _ progress: @Sendable (Double) -> Void) async throws -> Void
    ) async throws -> [URL] {
        var results: [URL] = []
        let urls = context.selection.urls
        for (index, source) in urls.enumerated() {
            try Task.checkCancellation()
            let share = 1.0 / Double(urls.count)
            let document = try PDFBackend.document(source, password: password)
            let destination = context.output.destination(for: source, tag: tag, extension: "pdf")
            let result = try await OutputPolicy.write(to: destination) { temporary in
                try await work(document, source, temporary) { value in
                    context.progress((Double(index) + min(max(value, 0), 1)) * share)
                }
            }
            results.append(result)
            context.progress(Double(index + 1) * share)
        }
        return results
    }

    /// Náhled první stránky (pro okno nástroje).
    static func firstPage(_ url: URL, maxPixel: Int, password: String? = nil) throws -> CGImage {
        let document = try PDFBackend.document(url, password: password)
        guard let page = document.page(at: 0) else { throw ConvertError.unreadable(url.lastPathComponent) }
        let bounds = page.bounds(for: .cropBox)
        let dpi = 72 * CGFloat(maxPixel) / max(bounds.width, bounds.height)
        return try PDFBackend.render(page, dpi: dpi)
    }

    /// Vykreslí každou stránku znovu do nového PDF (vektory zůstanou) a nechá na `draw` doplnit obsah.
    /// Odkazy, formuláře a záložky se při tom nepřenášejí.
    static func rewrite(
        _ document: PDFDocument, to output: URL, progress: (Double) -> Void = { _ in },
        draw: (_ context: CGContext, _ page: PDFPage, _ rect: CGRect, _ index: Int) throws -> Void
    ) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let reference = page.pageRef else { continue }
            let crop = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            var rect = CGRect(origin: .zero, size: rotated ? CGSize(width: crop.height, height: crop.width) : crop.size)
            context.beginPage(mediaBox: &rect)
            context.saveGState()
            context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(reference)
            context.restoreGState()
            try draw(context, page, rect, index)
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
    }

    // MARK: Rozsahy stránek

    /// „1-3, 5, 8-“ → [1...3, 5...5, 8...n]. Čísla stránek jsou od 1; chyba = `nil`.
    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
        var ranges: [ClosedRange<Int>] = []
        for part in text.replacingOccurrences(of: ";", with: ",").split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            switch bounds.count {
            case 1:
                guard let page = Int(bounds[0]), (1...max(pageCount, 1)).contains(page) else { return nil }
                ranges.append(page...page)
            case 2:
                let from = bounds[0].isEmpty ? 1 : Int(bounds[0])
                let to = bounds[1].isEmpty ? pageCount : Int(bounds[1])
                guard let from, let to, from >= 1, to <= pageCount, from <= to else { return nil }
                ranges.append(from...to)
            default:
                return nil
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// Nový dokument ze stránek `pages` (0…n-1) zdroje.
    static func extract(_ pages: [Int], from document: PDFDocument) -> PDFDocument {
        let result = PDFDocument()
        for index in pages {
            if let page = document.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        return result
    }
}

// MARK: - Komprese

public enum PDFCompress {
    public enum Preset: String, Sendable, CaseIterable {
        case small, balanced, high

        var resolution: Int { switch self { case .small: 96; case .balanced: 144; case .high: 200 } }
        var quality: Double { switch self { case .small: 0.5; case .balanced: 0.7; case .high: 0.85 } }
        var maxSize: Int { switch self { case .small: 1600; case .balanced: 2400; case .high: 3600 } }
    }

    /// Vlastní Quartz filtr (stejná struktura jako systémový „Reduce File Size“).
    static func filter(_ preset: Preset, in directory: URL) throws -> QuartzFilter {
        let plist: [String: Any] = [
            "Name": "FocusGlass \(preset.rawValue)",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": preset.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": preset.resolution, "ImageScaleInterpolate": true,
                    "ImageSizeMax": preset.maxSize, "ImageSizeMin": 0,
                ],
            ]]],
        ]
        let url = directory.appendingPathComponent("filter-\(preset.rawValue).qfilter")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        guard let filter = QuartzFilter(url: url) else { throw ConvertError.writeFailed("filtr komprese") }
        return filter
    }

    /// Zapíše zmenšené PDF. Když by výsledek nebyl menší, zapíše beze změny zdroj.
    @discardableResult
    static func compress(_ document: PDFDocument, source: URL, preset: Preset, to output: URL, scratch: URL) throws -> (before: Int, after: Int) {
        let before = ImageBackend.fileSize(source)
        let filter = try filter(preset, in: scratch)
        guard document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        let after = ImageBackend.fileSize(output)
        if after >= before, before > 0 {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: source, to: output)
            return (before, before)
        }
        return (before, after)
    }

    static let options: [ToolOption] = [
        .choice("preset", "Kvalita", [.init("small", "Nejmenší soubor (96 dpi)"), .init("balanced", "Vyvážená (144 dpi)"),
                                      .init("high", "Vysoká kvalita (200 dpi)")], default: "balanced",
                help: "Zmenší se obrázky; text a vektory zůstanou beze změny."),
    ]

    public static let tool = Tool(
        id: "pdf.tool.compress", title: "Komprese", symbol: "arrow.down.right.and.arrow.up.left", options: options,
        accepts: { $0.allPDFs },
        preview: { request in
            let preset = Preset(rawValue: OperationContext(selection: request.selection, options: request.options).string("preset") ?? "") ?? .balanced
            let document = try PDFBackend.document(request.source)
            let image = try PDFTools.firstPage(request.source, maxPixel: request.maxPixel)
            let result = try await OutputPolicy.withScratch(near: FileManager.default.temporaryDirectory) { scratch in
                try compress(document, source: request.source, preset: preset, to: scratch.appendingPathComponent("out.pdf"), scratch: scratch)
            }
            let caption = result.after >= result.before
                ? "\(ImageCompress.byteString(result.before)) – už je optimální"
                : "\(ImageCompress.byteString(result.before)) → \(ImageCompress.byteString(result.after)) (−\(100 - result.after * 100 / max(result.before, 1)) %)"
            return PreviewResult(image: image, caption: caption)
        },
        run: { context in
            let preset = Preset(rawValue: context.string("preset") ?? "") ?? .balanced
            return try await PDFTools.each(context, tag: "komprese") { document, source, output, progress in
                try await OutputPolicy.withScratch(near: output.deletingLastPathComponent()) { scratch in
                    progress(0.2)
                    try compress(document, source: source, preset: preset, to: output, scratch: scratch)
                }
                progress(1)
            }
        }
    )
}

// MARK: - Sloučení

public enum PDFMerge {
    public static let tool = Tool(
        id: "pdf.tool.merge", title: "Sloučit", symbol: "square.on.square", editor: .order, needsMultiple: true,
        accepts: { $0.allPDFs },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            let merged = PDFDocument()
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let document = try PDFBackend.document(url)
                for pageIndex in 0..<document.pageCount {
                    if let page = document.page(at: pageIndex)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
                context.progress(Double(index + 1) / Double(urls.count) * 0.9)
            }
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: "pdf", count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                guard merged.write(to: temporary) else { throw ConvertError.writeFailed(destination.lastPathComponent) }
            }
            context.progress(1)
            return [result]
        }
    )
}

// MARK: - Rozdělení

public enum PDFSplit {
    static let options: [ToolOption] = [
        .choice("mode", "Rozdělit", [.init("each", "Každá stránka zvlášť"), .init("every", "Po určitém počtu stránek"),
                                     .init("ranges", "Podle rozsahů (soubor na rozsah)"), .init("extract", "Vybrat stránky do jednoho PDF")],
                default: "each"),
        .number("count", "Stránek v souboru", 1...1000, default: 10, visibleWhen: .init("mode", "every")),
        .text("ranges", "Rozsahy", placeholder: "1-3, 5, 8-", visibleWhen: .init("mode", "ranges", "extract"),
              help: "Čísla stránek od 1. „8-“ = od osmé do konce."),
    ]

    /// Skupiny stránek (od 0) pro jednotlivé výsledné soubory a jejich popisky.
    static func groups(mode: String, count: Int, pageCount: Int, ranges: String) throws -> [(label: String, pages: [Int])] {
        switch mode {
        case "every":
            let size = max(count, 1)
            return stride(from: 0, to: pageCount, by: size).map { start in
                let end = min(start + size, pageCount)
                return (start + 1 == end ? "\(start + 1)" : "\(start + 1)-\(end)", Array(start..<end))
            }
        case "ranges", "extract":
            guard let parsed = PDFTools.parseRanges(ranges, pageCount: pageCount) else {
                throw ConvertError.unsupportedInput("rozsahy „\(ranges)“ – použij např. 1-3, 5, 8- (dokument má \(pageCount) stran)")
            }
            if mode == "extract" {
                let pages = parsed.flatMap { Array(($0.lowerBound - 1)...($0.upperBound - 1)) }
                return [("vybrané", pages)]
            }
            return parsed.map { ($0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)",
                                 Array(($0.lowerBound - 1)...($0.upperBound - 1))) }
        default:
            return (0..<pageCount).map { ("\($0 + 1)", [$0]) }
        }
    }

    public static let tool = Tool(
        id: "pdf.tool.split", title: "Rozdělit", symbol: "scissors", options: options,
        accepts: { $0.allPDFs },
        preview: { request in
            PreviewResult(image: try PDFTools.firstPage(request.source, maxPixel: request.maxPixel),
                          caption: "\(Czech.count(try PDFBackend.document(request.source).pageCount, "stránka", "stránky", "stránek"))")
        },
        run: { context in
            var results: [URL] = []
            for source in context.selection.urls {
                try Task.checkCancellation()
                let document = try PDFBackend.document(source)
                let groups = try groups(mode: context.string("mode") ?? "each", count: context.int("count") ?? 10,
                                        pageCount: document.pageCount, ranges: context.string("ranges") ?? "")
                let base = source.deletingPathExtension().lastPathComponent
                let directory = context.output.directory(for: source)
                // Jeden výsledek (vybrané stránky) je soubor, víc je složka.
                if groups.count == 1 {
                    let destination = OutputPolicy.unique(directory.appendingPathComponent("\(base) (\(groups[0].label)).pdf"))
                    results.append(try await OutputPolicy.write(to: destination) { temporary in
                        guard PDFTools.extract(groups[0].pages, from: document).write(to: temporary) else {
                            throw ConvertError.writeFailed(destination.lastPathComponent)
                        }
                    })
                    continue
                }
                let folder = OutputPolicy.unique(directory.appendingPathComponent("\(base) (rozděleno)", isDirectory: true))
                results.append(try await OutputPolicy.write(to: folder) { temporary in
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    for (index, group) in groups.enumerated() {
                        try Task.checkCancellation()
                        let file = temporary.appendingPathComponent("\(base) \(group.label).pdf")
                        guard PDFTools.extract(group.pages, from: document).write(to: file) else {
                            throw ConvertError.writeFailed(file.lastPathComponent)
                        }
                        context.progress(Double(index + 1) / Double(groups.count))
                    }
                })
            }
            return results
        }
    )
}

// MARK: - Heslo

public enum PDFPassword {
    static let options: [ToolOption] = [
        .choice("action", "Co udělat", [.init("set", "Nastavit heslo"), .init("remove", "Odstranit heslo")], default: "set"),
        .secret("password", "Heslo", help: "Heslo se nikam neukládá. Zapomenuté heslo nejde obnovit."),
        .secret("confirm", "Heslo znovu", visibleWhen: .init("action", "set")),
    ]

    public static let tool = Tool(
        id: "pdf.tool.password", title: "Heslo", symbol: "lock", options: options,
        accepts: { $0.allPDFs },
        run: { context in
            let remove = context.string("action") == "remove"
            let password = context.string("password") ?? ""
            guard !password.isEmpty else { throw ConvertError.unsupportedInput("zadej heslo") }
            if !remove, password != (context.string("confirm") ?? "") { throw ConvertError.unsupportedInput("hesla se neshodují") }
            return try await PDFTools.each(context, tag: remove ? "bez hesla" : "s heslem", password: remove ? password : nil) { document, _, output, _ in
                let written: Bool
                if remove {
                    // Odemčený dokument by se zapsal znovu zašifrovaný – stránky se proto přenesou do nového.
                    written = PDFTools.extract(Array(0..<document.pageCount), from: document).write(to: output)
                } else {
                    // Vlastník i uživatel stejné heslo: otevření i úpravy vyžadují heslo.
                    written = document.write(to: output, withOptions: [
                        .userPasswordOption: password, .ownerPasswordOption: password,
                    ])
                }
                guard written else { throw ConvertError.writeFailed(output.lastPathComponent) }
            }
        }
    )
}

// MARK: - Vodoznak

public enum PDFWatermark {
    static let options: [ToolOption] = [
        .text("text", "Text", placeholder: "DŮVĚRNÉ", default: "DŮVĚRNÉ"),
        .choice("layout", "Rozložení", [.init("center", "Doprostřed"), .init("tiled", "Dlaždice")], default: "center"),
        .slider("size", "Velikost", 12...160, default: 72, step: 2, unit: " pt"),
        .slider("opacity", "Průhlednost", 0.05...1, default: 0.25, step: 0.05),
        .slider("angle", "Náklon", -90...90, default: 35, step: 5, unit: "°"),
        .color("color", "Barva", default: RGBA(0.8, 0.1, 0.1)),
    ]

    static func draw(text: String, in context: CGContext, rect: CGRect, size: Double, opacity: Double, angle: Double,
                     color: RGBA, tiled: Bool) {
        guard !text.isEmpty else { return }
        let font = NSFont.boldSystemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: opacity),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let extent = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        func place(at center: CGPoint) {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle * .pi / 180)
            string.draw(at: CGPoint(x: -extent.width / 2, y: -extent.height / 2))
            context.restoreGState()
        }
        if tiled {
            let stepX = extent.width * 1.6
            let stepY = extent.height * 3.2
            var row = 0
            var y = -stepY
            while y < rect.height + stepY {
                var x = -stepX + (row % 2 == 0 ? 0 : stepX / 2)
                while x < rect.width + stepX {
                    place(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            place(at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    public static let tool = Tool(
        id: "pdf.tool.watermark", title: "Vodoznak", symbol: "drop.halffull", options: options,
        accepts: { $0.allPDFs },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let document = try PDFBackend.document(request.source)
            let preview = OutputPolicy.unique(FileManager.default.temporaryDirectory.appendingPathComponent("fg-watermark-\(UUID().uuidString).pdf"))
            defer { try? FileManager.default.removeItem(at: preview) }
            try apply(to: PDFTools.extract([0], from: document), output: preview, context: context)
            return PreviewResult(image: try PDFTools.firstPage(preview, maxPixel: request.maxPixel),
                                 caption: "Odkazy a formuláře se do PDF s vodoznakem nepřenášejí.")
        },
        run: { context in
            try await PDFTools.each(context, tag: "vodoznak") { document, _, output, progress in
                try apply(to: document, output: output, context: context, progress: progress)
            }
        }
    )

    static func apply(to document: PDFDocument, output: URL, context: OperationContext,
                      progress: (Double) -> Void = { _ in }) throws {
        let text = context.string("text") ?? ""
        guard !text.trimmed.isEmpty else { throw ConvertError.unsupportedInput("vyplň text vodoznaku") }
        try PDFTools.rewrite(document, to: output, progress: progress) { pdf, _, rect, _ in
            draw(text: text, in: pdf, rect: rect, size: context.double("size") ?? 72, opacity: context.double("opacity") ?? 0.25,
                 angle: context.double("angle") ?? 35, color: context.color("color") ?? RGBA(0.8, 0.1, 0.1),
                 tiled: context.string("layout") == "tiled")
        }
    }
}
