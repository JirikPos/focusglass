import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ConvertKit

@Suite(.serialized) struct ImageToolTests {
    let registry = Catalog.makeRegistry()

    private func tool(_ id: String) throws -> Tool {
        try #require(registry.operation(id: id) as? Tool, "chybí nástroj \(id)")
    }

    @discardableResult
    private func run(_ id: String, on sources: [URL], options: [String: OptionValue] = [:]) async throws -> [URL] {
        let tool = try tool(id)
        let selection = Selection(urls: sources)
        #expect(tool.accepts(selection), "\(id) nepřijme výběr")
        return try await tool.run(OperationContext(selection: selection, options: options))
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    // MARK: Kolo

    @Test func wheelContentsPerSelection() {
        func ids(_ paths: [String]) -> [String] {
            registry.operations(for: Selection(urls: paths.map { URL(fileURLWithPath: $0) }), wheel: .tools).map(\.id)
        }
        let single = ids(["/a.jpg"])
        #expect(single == ["image.tool.compress", "image.tool.metadata", "image.tool.edit", "image.tool.annotate",
                           "image.tool.background", "image.tool.crop", "image.tool.redact", "image.tool.cutout"])
        let multiple = ids(["/a.jpg", "/b.png"])
        #expect(multiple.contains("image.tool.pdf") && multiple.contains("image.tool.collage"))
        #expect(!multiple.contains("image.tool.annotate"))
        #expect(ids(["/a.jpg", "/b.mp4"]).isEmpty)
    }

    @Test func toolDefaultsAndVisibility() throws {
        let compress = try tool("image.tool.compress")
        let defaults = compress.defaults
        #expect(defaults["mode"] == .string("preset"))
        let target = try #require(compress.options.first { $0.id == "targetKB" })
        #expect(!target.isVisible(in: defaults))
        #expect(target.isVisible(in: defaults.merging(["mode": .string("target")]) { $1 }))
        #expect(compress.needsDialog)
    }

    // MARK: Komprese

    @Test func compressToTargetSize() async throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url)
        let originalBytes = ImageBackend.fileSize(source)
        #expect(originalBytes > 200_000)
        let result = try await run("image.tool.compress", on: [source],
                                   options: ["mode": .string("target"), "targetKB": .int(120)])[0]
        #expect(ImageBackend.fileSize(result) <= 120 * 1024)
        #expect(ImageBackend.fileSize(result) > 60 * 1024, "nemá se zbytečně zničit kvalita")
        #expect(result.lastPathComponent == "foto (komprese).jpg")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func compressByPercentAndPreset() async throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url)
        let original = ImageBackend.fileSize(source)
        let half = try await run("image.tool.compress", on: [source], options: ["mode": .string("percent"), "percent": .double(50)])[0]
        #expect(ImageBackend.fileSize(half) <= original / 2)
        let small = try await run("image.tool.compress", on: [source], options: ["mode": .string("preset"), "preset": .string("small")])[0]
        #expect(ImageBackend.fileSize(small) < original * 6 / 10)
        let wide = try Fixtures.noisy(in: dir.url, name: "siroka.jpg", width: 2600, height: 1000)
        let resized = try await run("image.tool.compress", on: [wide], options: ["mode": .string("preset"), "preset": .string("small")])[0]
        #expect(ImageBackend.pixelSize(of: resized)!.width == 1920, "malá předvolba zmenší delší stranu na 1920 px")
    }

    @Test func compressResizesLosslessPNGToReachTarget() async throws {
        let dir = try TempDir()
        let png = dir.url.appendingPathComponent("sum.png")
        let noisyJPEG = try Fixtures.noisy(in: dir.url, name: "zdroj.jpg", width: 800, height: 600)
        try ImageBackend.write(noisyJPEG, to: png, format: .png)
        let original = ImageBackend.fileSize(png)
        let result = try await run("image.tool.compress", on: [png],
                                   options: ["mode": .string("target"), "targetKB": .int(Int(original / 1024 / 3))])[0]
        #expect(result.pathExtension == "png")
        #expect(ImageBackend.fileSize(result) <= original / 3)
        #expect(ImageBackend.pixelSize(of: result)!.width < 800)
    }

    @Test func compressConvertsFormatAndStripsMetadata() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        let result = try await run("image.tool.compress", on: [source], options: ["strip": .bool(true), "format": .string("heic")])[0]
        #expect(result.pathExtension == "heic")
        #expect(!ImageMetadata.hasLocation(result))
    }

    @Test func compressNeverGrowsAlreadySmallFile() throws {
        let dir = try TempDir()
        let source = try Fixtures.halves(in: dir.url, name: "maly.png", width: 40, height: 20)
        let result = try ImageCompress.compress(source, settings: .init(mode: .preset(.high)))
        #expect(result.data.count <= ImageBackend.fileSize(source))
        #expect(result.alreadyOptimal)
    }

    @Test func compressCaptionDescribesSavings() throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url)
        let result = try ImageCompress.compress(source, settings: .init(mode: .percent(60)))
        let caption = ImageCompress.caption(result)
        #expect(caption.contains("→") && caption.contains("−"))
    }

    // MARK: Metadata

    @Test func jpegStripIsLosslessAndKeepsOrientation() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url, orientation: 6)
        let result = try await run("image.tool.metadata", on: [source], options: ["action": .string("strip")])[0]
        #expect(result.lastPathComponent == "exif (bez metadat).jpg")
        let after = try properties(result)
        #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] == nil)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(after[kCGImagePropertyOrientation] as? Int == 6)
        // Pixely se nepřekódovaly: dekódovaný obraz je bajt po bajtu stejný.
        let a = try ImageBackend.load(source)
        let b = try ImageBackend.load(result)
        #expect(a.dataProvider?.data == b.dataProvider?.data)
    }

    @Test func jpegRemoveLocationKeepsAuthor() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        #expect(ImageMetadata.hasLocation(source))
        let result = try await run("image.tool.metadata", on: [source], options: ["action": .string("location")])[0]
        #expect(!ImageMetadata.hasLocation(result))
        #expect(ImageMetadata.read(result).contains { $0.name == "Autor" && $0.value == "Ada" })
    }

    @Test func jpegEditSetsFields() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        let result = try await run("image.tool.metadata", on: [source], options: [
            "action": .string("edit"), "author": .string("Bob"), "copyright": .string("(c) Bob"),
            "location": .string("48.8584, 2.2945"), "date": .string("2024-05-01 14:30"), "model": .string("Z9"),
        ])[0]
        let entries = ImageMetadata.read(result)
        #expect(entries.contains { $0.name == "Autor" && $0.value == "Bob" })
        #expect(entries.contains { $0.name == "Model" && $0.value == "Z9" })
        #expect(entries.contains { $0.name == "Pořízeno" && $0.value.hasPrefix("2024:05:01 14:30") })
        let gps = try #require(properties(result)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(abs((gps[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 48.8584) < 0.001)
        #expect(abs((gps[kCGImagePropertyGPSLongitude] as? Double ?? 0) - 2.2945) < 0.001)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
    }

    @Test func pngMetadataIsRewritten() async throws {
        let dir = try TempDir()
        let png = dir.url.appendingPathComponent("a.png")
        try ImageBackend.write(try ImageBackend.load(try Fixtures.exifJPEG(in: dir.url)), to: png, format: .png)
        // PNG z ImageIO nese TIFF/GPS jen tehdy, když je dostal – doplníme je přímo.
        let withMeta = dir.url.appendingPathComponent("meta.png")
        _ = try Fixtures.write(try ImageBackend.load(png), to: withMeta, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 50.08, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 14.42, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
        #expect(ImageMetadata.hasLocation(withMeta))
        let result = try await run("image.tool.metadata", on: [withMeta], options: ["action": .string("location")])[0]
        #expect(!ImageMetadata.hasLocation(result))
        #expect(result.pathExtension == "png")
    }

    @Test func emptyEditIsRejected() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        await #expect(throws: ConvertError.self) {
            try await run("image.tool.metadata", on: [source], options: ["action": .string("edit")])
        }
    }

    @Test func parsers() {
        #expect(ImageMetadata.parseCoordinates("50.0875, 14.4213")! == (50.0875, 14.4213))
        #expect(ImageMetadata.parseCoordinates("50,0875, 14,4213")! == (50.0875, 14.4213))
        #expect(ImageMetadata.parseCoordinates("-33.86; 151.21")! == (-33.86, 151.21))
        #expect(ImageMetadata.parseCoordinates("91, 14") == nil)
        #expect(ImageMetadata.parseCoordinates("abc") == nil)
        #expect(ImageMetadata.parseDate("2024-05-01 14:30") != nil)
        #expect(ImageMetadata.parseDate("1. 5. 2024") != nil)
        #expect(ImageMetadata.parseDate("včera") == nil)
        #expect(ImageMetadata.gpsString(50.5, positive: "N", negative: "S") == "50,30.000000N")
        #expect(ImageMetadata.gpsString(-14.25, positive: "E", negative: "W") == "14,15.000000W")
    }

    // MARK: Úpravy

    @Test func adjustmentsBehave() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.halves(in: dir.url))

        var brighter = ImageAdjust.Adjustments()
        brighter.exposure = 1
        let bright = try ImageAdjust.apply(brighter, to: try ImageBackend.load(try Fixtures.noisy(in: dir.url, width: 200, height: 150)))
        let base = Fixtures.mean(try ImageBackend.load(try Fixtures.noisy(in: dir.url, width: 200, height: 150)))
        #expect(Fixtures.mean(bright).g > base.g + 10)

        var gray = ImageAdjust.Adjustments()
        gray.saturation = 0
        let desaturated = try ImageAdjust.apply(gray, to: image)
        let p = Fixtures.sample(desaturated, x: 10, y: 10)
        #expect(abs(p.r - p.g) < 4 && abs(p.g - p.b) < 4)

        var rotated = ImageAdjust.Adjustments()
        rotated.rotation = 90
        let turned = try ImageAdjust.apply(rotated, to: image)
        #expect(turned.width == 100 && turned.height == 200)
        // Po otočení o 90° doprava je původní levá (červená) strana nahoře.
        #expect(Fixtures.sample(turned, x: 50, y: 10).isRedish)
        #expect(Fixtures.sample(turned, x: 50, y: 190).isBluish)

        var flipped = ImageAdjust.Adjustments()
        flipped.flipHorizontal = true
        let mirrored = try ImageAdjust.apply(flipped, to: image)
        #expect(Fixtures.sample(mirrored, x: 10, y: 50).isBluish)
        #expect(Fixtures.sample(mirrored, x: 190, y: 50).isRedish)
    }

    @Test func warmerTemperatureAddsRed() throws {
        let dir = try TempDir()
        let gray = try ImageBackend.load(try Fixtures.gray(in: dir.url))
        var warm = ImageAdjust.Adjustments()
        warm.temperature = 1
        var cool = warm
        cool.temperature = -1
        let warmMean = Fixtures.mean(try ImageAdjust.apply(warm, to: gray))
        let coolMean = Fixtures.mean(try ImageAdjust.apply(cool, to: gray))
        #expect(warmMean.r - warmMean.b > 10, "teplejší = víc červené než modré: \(warmMean)")
        #expect(coolMean.b - coolMean.r > 10, "chladnější = víc modré než červené: \(coolMean)")
    }

    @Test func editToolWritesAndRejectsNoOp() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        let result = try await run("image.tool.edit", on: [source], options: ["saturation": .double(0), "filter": .string("noir")])[0]
        #expect(result.lastPathComponent == "exif (upraveno).jpg")
        #expect(ImageMetadata.hasLocation(result), "úpravy mají zachovat metadata")
        await #expect(throws: ConvertError.self) { try await run("image.tool.edit", on: [source]) }
    }

    @Test func editPreviewIsFast() async throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url, width: 3000, height: 2000)
        let tool = try tool("image.tool.edit")
        let start = Date()
        let preview = try #require(try await tool.preview(PreviewRequest(
            source: source, options: ["exposure": .double(0.5), "filter": .string("chrome"), "vignette": .double(0.5)],
            maxPixel: 1000, selection: Selection(urls: [source]))))
        #expect(preview.image.width == 1000)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    // MARK: Ořez

    @Test func cropModes() async throws {
        let dir = try TempDir()
        let source = try Fixtures.halves(in: dir.url) // 200×100
        let square = try await run("image.tool.crop", on: [source], options: ["mode": .string("aspect"), "ratio": .string("square")])[0]
        #expect(ImageBackend.pixelSize(of: square) == CGSize(width: 100, height: 100))
        let exact = try await run("image.tool.crop", on: [source], options: [
            "mode": .string("dimensions"), "width": .int(50), "height": .int(50)])[0]
        #expect(ImageBackend.pixelSize(of: exact) == CGSize(width: 50, height: 50))
        let enlarged = try await run("image.tool.crop", on: [source], options: [
            "mode": .string("dimensions"), "width": .int(400), "height": .int(100)])[0]
        #expect(ImageBackend.pixelSize(of: enlarged) == CGSize(width: 400, height: 100))

        let rectJSON = try JSONEncoder().encode(NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let right = try await run("image.tool.crop", on: [source], options: ["mode": .string("free"), "rect": .data(rectJSON)])[0]
        let image = try ImageBackend.load(right)
        #expect(image.width == 100)
        #expect(Fixtures.sample(image, x: 50, y: 50).isBluish)
    }

    @Test func cropAppliesSameRatioToEverything() async throws {
        let dir = try TempDir()
        let a = try Fixtures.halves(in: dir.url, name: "a.png", width: 300, height: 200)
        let b = try Fixtures.halves(in: dir.url, name: "b.png", width: 120, height: 400)
        let results = try await run("image.tool.crop", on: [a, b], options: ["mode": .string("aspect"), "ratio": .string("r16x9")])
        for url in results {
            let size = try #require(ImageBackend.pixelSize(of: url))
            #expect(abs(Double(size.width / size.height) - 16.0 / 9) < 0.03)
        }
    }

    @Test func cropPlanIsPureMath() throws {
        let plan = try ImageCrop.plan(for: CGSize(width: 1000, height: 500), spec: .aspect(1, anchorX: 0, anchorY: 0.5))
        #expect(plan.rect == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(throws: ConvertError.self) { try ImageCrop.plan(for: CGSize(width: 10, height: 10), spec: .dimensions(width: 0, height: 5)) }
    }

    // MARK: Pozadí

    @Test func backgroundGeometry() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.halves(in: dir.url)) // 200×100
        var settings = ImageBackground.Settings()
        settings.fill = .solid(RGBA(0, 1, 0))
        settings.padding = 0.1
        settings.shadow = false
        let plain = try ImageBackground.render(image, settings: settings)
        // Okraj 10 % kratší strany (100 px) = 10 px kolem dokola.
        #expect(plain.width == 220 && plain.height == 120)
        #expect(Fixtures.sample(plain, x: 2, y: 2) == Fixtures.Pixel(r: 0, g: 255, b: 0, a: 255))
        #expect(Fixtures.sample(plain, x: 60, y: 70).isRedish)

        settings.ratio = .square
        let square = try ImageBackground.render(image, settings: settings)
        #expect(square.width == square.height && square.width == 220)

        settings.maxPixel = 120
        let capped = try ImageBackground.render(image, settings: settings)
        #expect(max(capped.width, capped.height) == 120)
    }

    @Test func backgroundCornersAndClear() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.halves(in: dir.url))
        var settings = ImageBackground.Settings()
        settings.fill = .clear
        settings.shadow = false
        settings.cornerRadius = 0.25
        settings.padding = 0.1
        let result = try ImageBackground.render(image, settings: settings)
        #expect(Fixtures.sample(result, x: 1, y: 1).a == 0)
        // Roh obrázku (10,10) je kvůli zaoblení (poloměr 25 px) průhledný, střed ne.
        #expect(Fixtures.sample(result, x: 12, y: 12).a == 0)
        #expect(Fixtures.sample(result, x: 120, y: 70).a == 255)
    }

    @Test func backgroundFillVariantsAndTool() async throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url, name: "zaklad.png", width: 300, height: 200)
        let other = try Fixtures.halves(in: dir.url, name: "jine.png")
        for options: [String: OptionValue] in [
            ["fill": .string("blur")], ["fill": .string("solid"), "color": .color(RGBA(1, 0, 0))],
            ["fill": .string("image"), "image": .string(other.path)], ["fill": .string("gradient"), "gradient": .string("custom")],
        ] {
            let result = try await run("image.tool.background", on: [source], options: options)[0]
            let size = try #require(ImageBackend.pixelSize(of: result))
            #expect(size.width > 300)
            try? FileManager.default.removeItem(at: result)
        }
        let transparent = try await run("image.tool.background", on: [try Fixtures.exifJPEG(in: dir.url)],
                                        options: ["fill": .string("clear")])[0]
        #expect(transparent.pathExtension == "png")
    }

    // MARK: Krytí

    @Test func redactStyles() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.noisy(in: dir.url, width: 400, height: 300))
        let region = ImageRedact.Region(rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), kind: .manual)
        let solid = try ImageRedact.apply([region], style: .solid(.black), to: image)
        #expect(Fixtures.sample(solid, x: 200, y: 150).isDark)
        #expect(Fixtures.sample(solid, x: 20, y: 20) == Fixtures.sample(image, x: 20, y: 20), "mimo oblast se nic nemění")

        let pixelated = try ImageRedact.apply([region], style: .pixelate, to: image)
        #expect(Fixtures.sample(pixelated, x: 200, y: 150) != Fixtures.sample(image, x: 200, y: 150))
        // Pixelizace = bloky: sousední pixely uvnitř bloku mají stejnou barvu.
        #expect(Fixtures.sample(pixelated, x: 200, y: 150) == Fixtures.sample(pixelated, x: 201, y: 151))

        let blurred = try ImageRedact.apply([region], style: .blur, to: image)
        #expect(Fixtures.sample(blurred, x: 200, y: 150) != Fixtures.sample(image, x: 200, y: 150))
        #expect(try ImageRedact.apply([], style: .blur, to: image) === image)
    }

    @Test func sensitiveTextDetection() {
        func found(_ text: String) -> [String] {
            ImageRedact.sensitiveRanges(in: text).map { String(text[$0]) }
        }
        #expect(found("Kontakt: jan.novak@example.com dnes") == ["jan.novak@example.com"])
        #expect(found("Tel +420 777 123 456 ok").contains { $0.contains("777 123 456") })
        #expect(found("Karta 4111 1111 1111 1111").first?.hasPrefix("4111") == true)
        #expect(found("IBAN CZ65 0800 0000 1920 0014 5399 ok").first?.hasPrefix("CZ65") == true)
        #expect(found("RČ 800101/1234").contains("800101/1234"))
        #expect(found("https://example.com/x").count == 1)
        #expect(found("Dobrý den, děkuji za zprávu 2024").isEmpty)
    }

    @Test func redactFindsEmailInRenderedText() async throws {
        let dir = try TempDir()
        let source = try Fixtures.textImage(in: dir.url, text: "Napiš na jan.novak@example.com dnes")
        let image = try ImageBackend.load(source)
        let sensitive = try ImageRedact.detect(in: image, faces: false, text: .sensitive)
        #expect(!sensitive.isEmpty)
        let all = try ImageRedact.detect(in: image, faces: false, text: .all)
        #expect(!all.isEmpty)
        // Jen e-mail: oblast je užší než celý řádek.
        #expect(sensitive.map(\.rect.width).max()! < all.map(\.rect.width).max()!)

        let result = try await run("image.tool.redact", on: [source], options: ["faces": .bool(false), "text": .string("sensitive")])[0]
        #expect(result.lastPathComponent == "text (kryto).png")
        let covered = try ImageBackend.load(result)
        let region = try #require(sensitive.first)
        let px = Fixtures.sample(covered, x: Int((region.rect.x + region.rect.width / 2) * 1800), y: Int((region.rect.y + region.rect.height / 2) * 400))
        #expect(px.isDark)
    }

    @Test func redactWithManualRegionsAndStripsMetadata() async throws {
        let dir = try TempDir()
        let source = try Fixtures.exifJPEG(in: dir.url)
        let regions = [ImageRedact.Region(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), kind: .manual)]
        let result = try await run("image.tool.redact", on: [source], options: [
            "regions": .data(try JSONEncoder().encode(regions)), "style": .string("solid")])[0]
        let image = try ImageBackend.load(result)
        #expect(Fixtures.sample(image, x: 50, y: 50).isDark)
        #expect(Fixtures.sample(image, x: 150, y: 50).isBluish)
        #expect(!ImageMetadata.hasLocation(result), "krytý obrázek nesmí prozradit polohu")
    }

    @Test func redactWithNothingFoundSaysSo() async throws {
        let dir = try TempDir()
        let source = try Fixtures.halves(in: dir.url)
        await #expect(throws: ConvertError.self) {
            try await run("image.tool.redact", on: [source], options: ["faces": .bool(false), "text": .string("all")])
        }
    }

    // MARK: Anotace

    @Test func annotationsRender() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.halves(in: dir.url, width: 400, height: 200))
        let rectangle = ImageAnnotate.Annotation(kind: .rectangle, start: .init(0.1, 0.2), end: .init(0.3, 0.8),
                                                 color: RGBA(0, 1, 0), strokeWidth: 0.02, filled: true)
        let arrow = ImageAnnotate.Annotation(kind: .arrow, start: .init(0.6, 0.2), end: .init(0.9, 0.2), color: .yellow, strokeWidth: 0.02)
        let number = ImageAnnotate.Annotation(kind: .number, start: .init(0.5, 0.7), end: .init(0.5, 0.7), text: "3", color: .red, strokeWidth: 0.02)
        let label = ImageAnnotate.Annotation(kind: .text, start: .init(0.55, 0.45), end: .init(0.55, 0.45), text: "Pozor", color: .white, strokeWidth: 0.02)
        let result = try ImageAnnotate.render([rectangle, arrow, number, label], onto: image)
        #expect(result.width == 400 && result.height == 200)
        #expect(Fixtures.sample(result, x: 80, y: 100) == Fixtures.Pixel(r: 0, g: 255, b: 0, a: 255))      // plný obdélník
        #expect(Fixtures.sample(result, x: 300, y: 40).r > 200 && Fixtures.sample(result, x: 300, y: 40).g > 180) // žlutá šipka
        #expect(Fixtures.sample(result, x: 188, y: 140).isRedish)                                          // číslo (kruh)
        #expect(Fixtures.sample(result, x: 390, y: 190) == Fixtures.sample(image, x: 390, y: 190))         // jinde beze změny
    }

    @Test func pixelateAnnotationAndCodable() throws {
        let dir = try TempDir()
        let image = try ImageBackend.load(try Fixtures.noisy(in: dir.url, width: 300, height: 200))
        let pixelate = ImageAnnotate.Annotation(kind: .pixelate, start: .init(0.2, 0.2), end: .init(0.8, 0.8))
        let result = try ImageAnnotate.render([pixelate], onto: image)
        #expect(Fixtures.sample(result, x: 150, y: 100) != Fixtures.sample(image, x: 150, y: 100))
        let data = try JSONEncoder().encode([pixelate])
        #expect(try JSONDecoder().decode([ImageAnnotate.Annotation].self, from: data) == [pixelate])
    }

    @Test func annotateToolRules() async throws {
        let dir = try TempDir()
        let source = try Fixtures.halves(in: dir.url)
        let tool = try tool("image.tool.annotate")
        #expect(!tool.accepts(Selection(urls: [source, try Fixtures.halves(in: dir.url, name: "b.png")])))
        await #expect(throws: ConvertError.self) { try await run("image.tool.annotate", on: [source]) }
        let annotations = [ImageAnnotate.Annotation(kind: .line, start: .init(0, 0), end: .init(1, 1))]
        let result = try await run("image.tool.annotate", on: [source], options: ["annotations": .data(try JSONEncoder().encode(annotations))])[0]
        #expect(result.lastPathComponent == "pulky (anotace).png")
    }

    // MARK: Bez pozadí

    @Test func cutoutEitherWorksOrExplains() async throws {
        let dir = try TempDir()
        let source = try Fixtures.noisy(in: dir.url, name: "predmet.png", width: 300, height: 300)
        do {
            let result = try await run("image.tool.cutout", on: [source])[0]
            #expect(result.pathExtension == "png")
        } catch let error as ConvertError {
            #expect(error.localizedDescription.contains("předmět"))
        }
    }

    // MARK: PDF z obrázků

    @Test func pdfFromImagesKeepsOrderAndSize() async throws {
        let dir = try TempDir()
        let landscape = try Fixtures.halves(in: dir.url, name: "a.png", width: 400, height: 200)
        let portrait = try Fixtures.halves(in: dir.url, name: "b.png", width: 200, height: 400)
        let result = try await run("image.tool.pdf", on: [landscape, portrait])[0]
        #expect(result.lastPathComponent == "PDF (2 obrázky).pdf")
        let document = try #require(PDFDocument(url: result))
        #expect(document.pageCount == 2)
        let first = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let second = try #require(document.page(at: 1)).bounds(for: .mediaBox)
        #expect(first.width > first.height && second.height > second.width)
        #expect(abs(max(first.width, first.height) - 842) < 1)

        // Změněné pořadí z editoru.
        let order = try JSONEncoder().encode([portrait.path, landscape.path])
        let swapped = try await run("image.tool.pdf", on: [landscape, portrait], options: ["order": .data(order)])[0]
        let page = try #require(PDFDocument(url: swapped)?.page(at: 0)).bounds(for: .mediaBox)
        #expect(page.height > page.width)
    }

    @Test func pdfFixedPageSize() async throws {
        let dir = try TempDir()
        let a = try Fixtures.halves(in: dir.url, name: "a.png", width: 400, height: 200)
        let b = try Fixtures.halves(in: dir.url, name: "b.png", width: 400, height: 200)
        let result = try await run("image.tool.pdf", on: [a, b], options: ["pageSize": .string("a4")])[0]
        let page = try #require(PDFDocument(url: result)?.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(page.width - 841.89) < 1 && abs(page.height - 595.28) < 1) // na šířku podle obrázku
    }

    @Test func pdfRespectsExifOrientation() async throws {
        let dir = try TempDir()
        // 200×100 pixelů s orientací 6 (otočit o 90° doprava) se zobrazuje 100×200: červená vlevo → nahoře.
        let rotated = try Fixtures.exifJPEG(in: dir.url, name: "otocena.jpg", orientation: 6)
        let plain = try Fixtures.halves(in: dir.url, name: "rovna.jpg")
        let result = try await run("image.tool.pdf", on: [rotated, plain], options: ["pageSize": .string("a4")])[0]
        let page = try #require(PDFDocument(url: result)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        #expect(box.height > box.width)
        let image = try PDFBackend.render(page, dpi: 36)
        // Nahoře červená, dole modrá (s ohledem na okraje stránky uprostřed).
        #expect(Fixtures.sample(image, x: image.width / 2, y: image.height / 2 - 60).isRedish)
        #expect(Fixtures.sample(image, x: image.width / 2, y: image.height / 2 + 60).isBluish)
    }

    @Test func pdfEmbedsJPEGWithoutBloating() async throws {
        let dir = try TempDir()
        let a = try Fixtures.noisy(in: dir.url, name: "a.jpg")
        let b = try Fixtures.noisy(in: dir.url, name: "b.jpg")
        let jpegBytes = ImageBackend.fileSize(a) + ImageBackend.fileSize(b)
        let result = try await run("image.tool.pdf", on: [a, b])[0]
        // Bez předání JPEG by měl PDF desítky MB (nekomprimované pixely se Flate).
        #expect(ImageBackend.fileSize(result) < jpegBytes * 2, "PDF \(ImageBackend.fileSize(result)) vs JPEG \(jpegBytes)")
    }

    // MARK: Koláž

    @Test func collageLayoutsNeverOverlapOrEscape() {
        for layout in ImageCombine.Layout.allCases {
            for count in 2...9 {
                for ratio in [AspectRatio.original, .square, .r16x9, .r9x16] {
                    var settings = ImageCombine.CollageSettings()
                    settings.layout = layout
                    settings.ratio = ratio
                    let aspects = (0..<count).map { [1.5, 0.75, 1.0, 1.78][$0 % 4] }
                    let result = ImageCombine.cells(count: count, aspects: aspects, settings: settings)
                    #expect(result.cells.count == count, "\(layout) \(count)")
                    let canvas = CGRect(origin: .zero, size: result.size)
                    for (i, cell) in result.cells.enumerated() {
                        #expect(cell.width > 1 && cell.height > 1, "\(layout) \(count) \(ratio): buňka \(i) je \(cell)")
                        #expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(cell), "\(layout) \(count) \(ratio): buňka \(i) mimo plátno")
                        for other in result.cells[(i + 1)...] {
                            let overlap = cell.intersection(other)
                            #expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5, "\(layout) \(count) \(ratio): překryv")
                        }
                    }
                }
            }
        }
    }

    @Test func collageRendersAndNamesResult() async throws {
        let dir = try TempDir()
        let red = try Fixtures.halves(in: dir.url, name: "a.png", width: 300, height: 200)
        let blue = try Fixtures.halves(in: dir.url, name: "b.png", width: 300, height: 200)
        let result = try await run("image.tool.collage", on: [red, blue], options: [
            "layout": .string("row"), "ratio": .string("square"), "size": .string("2000"), "spacing": .double(0)])[0]
        #expect(result.lastPathComponent == "Koláž (2 obrázky).jpg")
        let size = try #require(ImageBackend.pixelSize(of: result))
        #expect(size.width == size.height && size.width == 2000)

        let natural = try await run("image.tool.collage", on: [red, blue], options: ["layout": .string("row"), "size": .string("2000")])[0]
        let naturalSize = try #require(ImageBackend.pixelSize(of: natural))
        #expect(abs(Double(naturalSize.width / naturalSize.height) - 3.0) < 0.05) // 1,5 + 1,5
    }

    @Test func collageNeedsTwoOrMoreAndAllImages() throws {
        let collage = try tool("image.tool.collage")
        #expect(!collage.accepts(Selection(urls: [URL(fileURLWithPath: "/a.png")])))
        #expect(!collage.accepts(Selection(urls: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.mp4")])))
        #expect(collage.accepts(Selection(urls: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.jpg")])))
    }
}
