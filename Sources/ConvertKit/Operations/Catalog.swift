import Foundation

/// Všechny vestavěné převody a nástroje v pořadí, v jakém je kolo ukazuje.
/// Tabulka „vstup → cíl → cesty“ je jediný zdroj pravdy; testy z ní ověřují, že každá buňka funguje.
/// Cesty jsou seřazené podle preference: nativní → ffmpeg / iWork → LibreOffice.
public enum Catalog {
    public static func makeRegistry() -> OperationRegistry {
        var registry = OperationRegistry()
        registry.register(conversions())
        registry.register(ToolCatalog.all())
        return registry
    }

    // Vstupy podle druhu
    static let images = ImageBackend.readable
    static let pdf: Set<String> = ["pdf"]
    static let nativeDocuments = TextBackend.readable
    static let pagesDocuments: Set<String> = ["pages"]
    static let slides: Set<String> = ["pptx", "ppt", "key", "odp"]
    static let nativeSheets: Set<String> = ["csv", "tsv", "xlsx"]
    static let officeSheets: Set<String> = ["xls", "xlsx", "ods", "numbers", "csv"]
    static let subtitles: Set<String> = ["srt", "vtt"]

    static func conversions() -> [any FileOperation] {
        var list: [any FileOperation] = []
        list += imageConversions()
        list += videoConversions()
        list += audioConversions()
        list += pdfConversions()
        list += documentConversions()
        list += slideConversions()
        list += sheetConversions()

        for format in [Format.srt, .vtt, .txt] {
            list.append(ConvertOperation("subtitle", to: format, from: subtitles, converter: Subtitles.convert))
        }
        for format in [Format.zip, .tar, .tgz] {
            list.append(ConvertOperation("archive", to: format, from: ArchiveBackend.readable, acceptsFolders: true,
                                         converter: ArchiveBackend.convert))
        }
        return list
    }

    // MARK: Obrázky

    static func imageConversions() -> [any FileOperation] {
        var list: [any FileOperation] = []
        for format in [Format.png, .jpg, .webp, .heic, .avif, .tiff, .bmp] {
            var routes: [ConvertRoute] = []
            if ImageBackend.canWrite(format) {
                routes.append(ConvertRoute(images, converter: ImageBackend.convert))
            }
            if format == .webp { routes.append(ConvertRoute(images, requires: [.tool(.cwebp)], converter: ImageEncoders.webp)) }
            if format == .avif { routes.append(ConvertRoute(images, requires: [.tool(.avifenc)], converter: ImageEncoders.avif)) }
            list.append(ConvertOperation("image", to: format, routes: routes))
        }
        list.append(ConvertOperation("image", to: .pdf, from: images, converter: ImageBackend.convert))
        return list
    }

    // MARK: Video a zvuk

    static func videoConversions() -> [any FileOperation] {
        let native = AVBackend.readableVideo
        let all = FFmpegBackend.videoInputs
        let ffmpeg = ConvertRoute(all, requires: [.ffmpeg], converter: FFmpegBackend.convert)
        return [
            ConvertOperation("video", to: .mp4, routes: [ConvertRoute(native, converter: AVBackend.export), ffmpeg], lane: .heavy),
            ConvertOperation("video", to: .mov, routes: [ConvertRoute(native, converter: AVBackend.export), ffmpeg], lane: .heavy),
            ConvertOperation("video", to: .mkv, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("video", to: .webm, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("video", to: .avi, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("video", to: .wmv, routes: [ffmpeg], lane: .heavy),
            // GIF z ffmpeg má lepší paletu; bez něj nativně.
            ConvertOperation("video", to: .gif, routes: [ffmpeg, ConvertRoute(native, converter: AVBackend.gif)], lane: .heavy),
            ConvertOperation("video", to: .mp3, routes: [ffmpeg], lane: .heavy),
        ]
    }

    static func audioConversions() -> [any FileOperation] {
        let native = AVBackend.readableAudio
        let ffmpeg = ConvertRoute(FFmpegBackend.audioInputs, requires: [.ffmpeg], converter: FFmpegBackend.convert)
        func both() -> [ConvertRoute] { [ConvertRoute(native, converter: AVBackend.audio), ffmpeg] }
        return [
            ConvertOperation("audio", to: .mp3, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("audio", to: .m4a, routes: both(), lane: .heavy),
            ConvertOperation("audio", to: .wav, routes: both(), lane: .heavy),
            ConvertOperation("audio", to: .flac, routes: both(), lane: .heavy),
            ConvertOperation("audio", to: .ogg, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("audio", to: .opus, routes: [ffmpeg], lane: .heavy),
            ConvertOperation("audio", to: .aiff, routes: both(), lane: .heavy),
            ConvertOperation("audio", to: .wma, routes: [ffmpeg], lane: .heavy),
        ]
    }

    // MARK: PDF

    static func pdfConversions() -> [any FileOperation] {
        let toPages = chain(PDFBackend.document, via: .docx, then: IWorkBackend.converter(.pages))
        return [
            ConvertOperation("pdf", to: .docx, from: pdf, approximate: true, converter: PDFBackend.document),
            ConvertOperation("pdf", to: .pages, from: pdf, requires: [.pages], approximate: true, converter: toPages),
            ConvertOperation("pdf", to: .pptx, from: pdf, approximate: true, converter: PDFBackend.presentation),
            ConvertOperation("pdf", to: .xlsx, from: pdf, approximate: true, converter: PDFBackend.spreadsheet),
            ConvertOperation("pdf", to: .jpg, from: pdf, converter: PDFBackend.images),
            ConvertOperation("pdf", to: .png, from: pdf, converter: PDFBackend.images),
            ConvertOperation("pdf", to: .epub, from: pdf, approximate: true, converter: PDFBackend.document),
            ConvertOperation("pdf", to: .txt, from: pdf, converter: PDFBackend.text),
            ConvertOperation("pdf", to: .md, from: pdf, approximate: true, converter: PDFBackend.document),
        ]
    }

    // MARK: Dokumenty

    static func documentConversions() -> [any FileOperation] {
        var list: [any FileOperation] = []
        // .pages: export přímo z Pages, jinak LibreOffice; formáty, které Pages neumí, přes DOCX.
        let pagesDirect = IWorkBackend.converter(.pages)
        let pagesViaDocx = chain(pagesDirect, via: .docx, then: TextBackend.convert)
        let officeViaDocx = chain(LibreOfficeBackend.convert, via: .docx, then: TextBackend.convert)
        for format in [Format.docx, .md, .txt, .epub, .html, .rtf] {
            let direct = IWorkBackend.exportFormat(app: .pages, target: format) != nil
            let usesOfficeDirectly = LibreOfficeBackend.filter(for: format) != nil
            list.append(ConvertOperation("document", to: format, routes: [
                ConvertRoute(nativeDocuments, converter: TextBackend.convert),
                ConvertRoute(pagesDocuments, requires: [.pages], converter: direct ? pagesDirect : pagesViaDocx),
                ConvertRoute(pagesDocuments, requires: [.libreOffice],
                             converter: usesOfficeDirectly ? LibreOfficeBackend.convert : officeViaDocx),
            ]))
            if format == .docx {
                // Pages za DOCX (pořadí lístků jako u ostatních převodníků).
                let toPages = chain(TextBackend.convert, via: .docx, then: pagesDirect)
                let pagesNative: Set<String> = ["docx", "doc", "rtf", "txt"]
                list.append(ConvertOperation("document", to: .pages, routes: [
                    ConvertRoute(pagesNative, requires: [.pages], converter: pagesDirect),
                    ConvertRoute(nativeDocuments, requires: [.pages], converter: toPages),
                ]))
            }
        }
        return list
    }

    // MARK: Prezentace

    static func slideConversions() -> [any FileOperation] {
        let keynote = IWorkBackend.converter(.keynote)
        let keynoteInputs: Set<String> = ["pptx", "ppt", "key"]
        let office = LibreOfficeBackend.convert
        let officeImages = chain(office, via: .pdf, then: PDFBackend.images)
        return [
            ConvertOperation("slides", to: .pdf, routes: [
                ConvertRoute(keynoteInputs, requires: [.keynote], converter: keynote),
                ConvertRoute(slides, requires: [.libreOffice], converter: office),
            ]),
            ConvertOperation("slides", to: .jpg, routes: [
                ConvertRoute(keynoteInputs, requires: [.keynote], converter: keynote),
                ConvertRoute(slides, requires: [.libreOffice], converter: officeImages),
            ]),
            ConvertOperation("slides", to: .png, routes: [
                ConvertRoute(keynoteInputs, requires: [.keynote], converter: keynote),
                ConvertRoute(slides, requires: [.libreOffice], converter: officeImages),
            ]),
            ConvertOperation("slides", to: .pptx, routes: [
                ConvertRoute(["key", "ppt"], requires: [.keynote], converter: keynote),
                ConvertRoute(["key", "ppt", "odp"], requires: [.libreOffice], converter: office),
            ]),
        ]
    }

    // MARK: Tabulky

    static func sheetConversions() -> [any FileOperation] {
        let numbers = IWorkBackend.converter(.numbers)
        let numbersInputs: Set<String> = ["xls", "xlsx", "numbers", "csv"]
        let office = LibreOfficeBackend.convert
        let viaNumbers = chain(numbers, via: .xlsx, then: Spreadsheet.convert)
        let viaOffice = chain(office, via: .xlsx, then: Spreadsheet.convert)
        func routes(_ target: Format, numbersDirect: Bool) -> [ConvertRoute] {
            [
                ConvertRoute(nativeSheets, converter: Spreadsheet.convert),
                ConvertRoute(numbersInputs, requires: [.numbers], converter: numbersDirect ? numbers : viaNumbers),
                ConvertRoute(officeSheets, requires: [.libreOffice], converter: target == .tsv ? viaOffice : office),
            ]
        }
        return [
            ConvertOperation("sheet", to: .xlsx, routes: routes(.xlsx, numbersDirect: true)),
            ConvertOperation("sheet", to: .csv, routes: routes(.csv, numbersDirect: false)),
            ConvertOperation("sheet", to: .tsv, routes: routes(.tsv, numbersDirect: false)),
            ConvertOperation("sheet", to: .ods, routes: [ConvertRoute(officeSheets.union(["tsv"]), requires: [.libreOffice], converter: office)]),
            ConvertOperation("sheet", to: .pdf, routes: [
                ConvertRoute(numbersInputs, requires: [.numbers], converter: numbers),
                ConvertRoute(officeSheets.union(["tsv"]), requires: [.libreOffice], converter: office),
            ]),
        ]
    }
}
