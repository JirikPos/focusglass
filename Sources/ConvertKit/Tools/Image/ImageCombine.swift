import CoreGraphics
import Foundation
import ImageIO

/// Nástroje nad více obrázky: PDF (stránka na obrázek) a koláž.
public enum ImageCombine {
    // MARK: Pořadí

    /// Pořadí z editoru (cesty); neznámé soubory zůstanou na konci v původním pořadí.
    static func ordered(_ selection: Selection, _ context: OperationContext) -> [URL] {
        guard let paths = context.decoded([String].self, "order") else { return selection.urls }
        let byPath = Dictionary(uniqueKeysWithValues: selection.urls.map { ($0.path, $0) })
        let first = paths.compactMap { byPath[$0] }
        return first + selection.urls.filter { !first.contains($0) }
    }

    /// Kam se uloží výsledek ze sloučení: vedle prvního souboru, jméno podle počtu.
    static func destination(_ context: OperationContext, first: URL, tag: String, ext: String, count: Int) -> URL {
        let directory = context.output.directory(for: first)
        let name = "\(tag) (\(Czech.count(count, "obrázek", "obrázky", "obrázků"))).\(ext)"
        return OutputPolicy.unique(directory.appendingPathComponent(name))
    }

    // MARK: PDF

    public enum PageSize: String, Sendable, CaseIterable {
        case fit, a4, letter

        /// Rozměry na výšku v bodech; `nil` = podle obrázku.
        var portrait: CGSize? {
            switch self {
            case .fit: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    /// Jedna stránka na obrázek. JPEG se vkládá beze změny (soubor nenaroste), orientace z EXIF se
    /// řeší transformací stránky.
    public static func writePDF(_ urls: [URL], to output: URL, pageSize: PageSize, margin: CGFloat,
                                progress: (Double) -> Void = { _ in }) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let loaded = try load(url)
            let displayed = loaded.displayedSize
            // Stránka: podle obrázku (delší strana 842 pt ≈ A4), nebo pevná s orientací podle obrázku.
            var page: CGSize
            if let portrait = pageSize.portrait {
                page = displayed.width > displayed.height ? CGSize(width: portrait.height, height: portrait.width) : portrait
            } else {
                let scale = 842 / max(displayed.width, displayed.height)
                page = CGSize(width: (displayed.width * scale).rounded(), height: (displayed.height * scale).rounded())
            }
            var box = CGRect(origin: .zero, size: page)
            pdf.beginPage(mediaBox: &box)
            let area = box.insetBy(dx: pageSize == .fit ? 0 : margin, dy: pageSize == .fit ? 0 : margin)
            let fit = min(area.width / displayed.width, area.height / displayed.height)
            let size = CGSize(width: displayed.width * fit, height: displayed.height * fit)
            let target = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)

            pdf.saveGState()
            pdf.interpolationQuality = .high
            pdf.concatenate(loaded.transform(into: target))
            pdf.draw(loaded.image, in: CGRect(x: 0, y: 0, width: CGFloat(loaded.image.width), height: CGFloat(loaded.image.height)))
            pdf.restoreGState()
            pdf.endPage()
            progress(Double(index + 1) / Double(urls.count))
        }
        pdf.closePDF()
    }

    /// Obrázek s EXIF orientací; pixely zůstávají nedotčené (kvůli předání JPEG do PDF beze změny).
    struct Loaded {
        let image: CGImage
        let orientation: Int

        var displayedSize: CGSize {
            orientation >= 5 ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
        }

        /// Zobrazí obrázek (kreslený v obdélníku `(0,0,w,h)`) otočený správně do `target`.
        func transform(into target: CGRect) -> CGAffineTransform {
            let w = CGFloat(image.width)
            let h = CGFloat(image.height)
            let display = displayedSize
            // Orientace → převod pixelů na zobrazený obrázek v jednotkovém čtverci displayed (y nahoru).
            var t = CGAffineTransform.identity
            switch orientation {
            case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
            case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
            case 5: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
            case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            case 7: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
            case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            default: break
            }
            let scale = CGAffineTransform(scaleX: target.width / display.width, y: target.height / display.height)
            return t.concatenating(scale).concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        }
    }

    static func load(_ url: URL) throws -> Loaded {
        if url.pathExtension.lowercased() == "svg" {
            return Loaded(image: try ImageBackend.image(at: url), orientation: 1)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return Loaded(image: image, orientation: properties?[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    static let pdfOptions: [ToolOption] = [
        .choice("pageSize", "Velikost stránky", [.init("fit", "Podle obrázku"), .init("a4", "A4"), .init("letter", "Letter")],
                default: "fit"),
        .slider("margin", "Okraj", 0...72, default: 24, step: 4, unit: " pt", visibleWhen: .init("pageSize", "a4", "letter")),
    ]

    public static let pdfTool = Tool(
        id: "image.tool.pdf", title: "PDF", symbol: "doc.richtext", options: pdfOptions, editor: .order,
        needsMultiple: true,
        accepts: { $0.allImages },
        run: { context in
            let urls = ordered(context.selection, context)
            let size = PageSize(rawValue: context.string("pageSize") ?? "") ?? .fit
            let destination = destination(context, first: urls[0], tag: "PDF", ext: "pdf", count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                try writePDF(urls, to: temporary, pageSize: size, margin: CGFloat(context.double("margin") ?? 24),
                             progress: context.progress)
            }
            return [result]
        }
    )

    // MARK: Koláž

    public enum Layout: String, Sendable, CaseIterable {
        case grid, row, column, featured

        var title: String {
            switch self {
            case .grid: "Mřížka"
            case .row: "Řada"
            case .column: "Sloupec"
            case .featured: "Hlavní + ostatní"
            }
        }
    }

    public struct CollageSettings: Sendable, Equatable {
        public var layout = Layout.grid
        public var ratio = AspectRatio.original // „původní“ = podle uspořádání
        /// Mezery jako podíl delší strany plátna.
        public var spacing = 0.012
        /// Zaoblení jako podíl kratší strany buňky.
        public var cornerRadius = 0.04
        public var background = RGBA.white
        /// `true`: obrázek vyplní buňku (ořízne se); `false`: vejde se celý.
        public var fill = true
        public var longSide = 3000

        public init() {}
    }

    /// Obdélníky buněk (v jednotkách plátna, počátek vlevo nahoře) a poměr stran plátna.
    static func cells(count n: Int, aspects: [Double], settings: CollageSettings) -> (size: CGSize, cells: [CGRect]) {
        let fixed = settings.ratio.value
        let natural: Double
        switch settings.layout {
        case .grid:
            let columns = bestColumns(count: n, aspects: aspects, ratio: fixed)
            let rows = (n + columns - 1) / columns
            natural = (Double(columns) * average(aspects)) / Double(rows)
        case .row: natural = aspects.reduce(0, +)
        case .column: natural = 1 / aspects.map { 1 / $0 }.reduce(0, +)
        case .featured: natural = 3.0 / 2
        }
        let ratio = fixed ?? natural
        let long = Double(settings.longSide)
        let size = ratio >= 1 ? CGSize(width: long, height: (long / ratio).rounded()) : CGSize(width: (long * ratio).rounded(), height: long)
        let gap = settings.spacing * Double(max(size.width, size.height))
        let area = CGRect(x: gap, y: gap, width: Double(size.width) - 2 * gap, height: Double(size.height) - 2 * gap)

        var rects: [CGRect] = []
        switch settings.layout {
        case .grid:
            let columns = bestColumns(count: n, aspects: aspects, ratio: ratio)
            let rows = (n + columns - 1) / columns
            let cellW = (area.width - gap * Double(columns - 1)) / Double(columns)
            let cellH = (area.height - gap * Double(rows - 1)) / Double(rows)
            for i in 0..<n {
                let row = i / columns
                let inRow = row == rows - 1 ? n - row * columns : columns
                // Poslední neúplná řada je vystředěná.
                let offset = (Double(columns - inRow) * (cellW + gap)) / 2
                rects.append(CGRect(x: area.minX + offset + Double(i % columns) * (cellW + gap),
                                    y: area.minY + Double(row) * (cellH + gap), width: cellW, height: cellH))
            }
        case .row, .column:
            let horizontal = settings.layout == .row
            // Bez pevného poměru: každý obrázek zabere úměrně svému poměru stran (nic se neořezává).
            let weights = fixed == nil ? aspects.map { horizontal ? $0 : 1 / $0 } : [Double](repeating: 1, count: n)
            let total = weights.reduce(0, +)
            let span = (horizontal ? area.width : area.height) - gap * Double(n - 1)
            var position = horizontal ? area.minX : area.minY
            for weight in weights {
                let length = span * weight / total
                rects.append(horizontal
                    ? CGRect(x: position, y: area.minY, width: length, height: area.height)
                    : CGRect(x: area.minX, y: position, width: area.width, height: length))
                position += length + gap
            }
        case .featured:
            if n == 1 {
                rects = [area]
            } else {
                let mainWidth = (area.width - gap) * 0.62
                rects.append(CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height))
                let others = n - 1
                let columns = others > 3 ? 2 : 1
                let rows = (others + columns - 1) / columns
                let sideX = area.minX + mainWidth + gap
                let sideW = area.width - mainWidth - gap
                let cellW = (sideW - gap * Double(columns - 1)) / Double(columns)
                let cellH = (area.height - gap * Double(rows - 1)) / Double(rows)
                for i in 0..<others {
                    rects.append(CGRect(x: sideX + Double(i % columns) * (cellW + gap),
                                        y: area.minY + Double(i / columns) * (cellH + gap), width: cellW, height: cellH))
                }
            }
        }
        return (size, rects)
    }

    /// Počet sloupců mřížky, při kterém mají buňky nejblíž k průměrnému poměru stran obrázků.
    static func bestColumns(count n: Int, aspects: [Double], ratio: Double?) -> Int {
        let target = average(aspects)
        let canvas = ratio ?? 1.5
        var best = 1
        var bestScore = Double.infinity
        for columns in 1...n {
            let rows = (n + columns - 1) / columns
            let cell = (canvas / Double(columns)) / (1 / Double(rows))
            let empty = Double(columns * rows - n)
            let score = abs(log(cell / target)) + empty * 0.15
            if score < bestScore { best = columns; bestScore = score }
        }
        return best
    }

    private static func average(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

    public static func collage(_ urls: [URL], settings: CollageSettings, progress: (Double) -> Void = { _ in }) throws -> CGImage {
        guard urls.count >= 2 else { throw ConvertError.unsupportedInput("koláž potřebuje aspoň dva obrázky") }
        let sizes = urls.map { ImageBackend.pixelSize(of: $0) ?? CGSize(width: 4, height: 3) }
        let aspects = sizes.map { Double($0.width / max($0.height, 1)) }
        let layout = cells(count: urls.count, aspects: aspects, settings: settings)

        let context = try ImageBackend.makeContext(width: Int(layout.size.width), height: Int(layout.size.height))
        context.setFillColor(settings.background.cgColor)
        context.fill(CGRect(origin: .zero, size: layout.size))
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            // Souřadnice shora → CG (zdola).
            let cell = layout.cells[index]
            let flipped = CGRect(x: cell.minX, y: Double(layout.size.height) - cell.maxY, width: cell.width, height: cell.height)
            let image = try ImageBackend.load(url, maxPixel: Int(max(flipped.width, flipped.height).rounded(.up)) * 2)
            var frame = flipped
            if !settings.fill {
                let scale = min(flipped.width / Double(image.width), flipped.height / Double(image.height))
                let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                frame = CGRect(x: flipped.midX - size.width / 2, y: flipped.midY - size.height / 2, width: size.width, height: size.height)
            }
            let radius = settings.cornerRadius * min(frame.width, frame.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            try ImageBackground.drawCover(image, in: context, rect: frame)
            context.restoreGState()
            progress(Double(index + 1) / Double(urls.count))
        }
        guard let result = context.makeImage() else { throw ConvertError.writeFailed("koláž") }
        return result
    }

    static let collageOptions: [ToolOption] = [
        .choice("layout", "Uspořádání", Layout.allCases.map { .init($0.rawValue, $0.title) }, default: "grid"),
        .choice("ratio", "Poměr stran", AspectRatio.choices(includingOriginal: true), default: AspectRatio.original.rawValue),
        .slider("spacing", "Mezery", 0...0.05, default: 0.012, step: 0.002),
        .slider("radius", "Zaoblení rohů", 0...0.3, default: 0.04, step: 0.01),
        .color("background", "Pozadí", default: .white),
        .toggle("fill", "Vyplnit buňky (ořízne)", default: true),
        .choice("size", "Velikost", [.init("2000", "2000 px"), .init("3000", "3000 px"), .init("4000", "4000 px")], default: "3000"),
    ]

    static func collageSettings(from context: OperationContext) -> CollageSettings {
        var settings = CollageSettings()
        settings.layout = Layout(rawValue: context.string("layout") ?? "") ?? .grid
        settings.ratio = AspectRatio(rawValue: context.string("ratio") ?? "") ?? .original
        settings.spacing = context.double("spacing") ?? 0.012
        settings.cornerRadius = context.double("radius") ?? 0.04
        settings.background = context.color("background") ?? .white
        settings.fill = context.bool("fill") ?? true
        settings.longSide = Int(context.string("size") ?? "") ?? 3000
        return settings
    }

    public static let collageTool = Tool(
        id: "image.tool.collage", title: "Koláž", symbol: "square.grid.2x2", options: collageOptions, editor: .order,
        needsMultiple: true,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            var settings = collageSettings(from: context)
            settings.longSide = min(settings.longSide, request.maxPixel)
            return PreviewResult(image: try collage(ordered(request.selection, context), settings: settings))
        },
        run: { context in
            let urls = ordered(context.selection, context)
            let settings = collageSettings(from: context)
            let destination = destination(context, first: urls[0], tag: "Koláž", ext: "jpg", count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                let image = try collage(urls, settings: settings, progress: context.progress)
                try ImageBackend.encode(image, as: .jpg, quality: 0.92).write(to: temporary)
            }
            return [result]
        }
    )
}
