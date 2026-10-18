import Foundation

/// Všechny vestavěné převody a nástroje v pořadí, v jakém je kolo ukazuje.
/// Tabulka „vstup → cíl → převodník“ je jediný zdroj pravdy; testy z ní ověřují, že každá buňka funguje.
public enum Catalog {
    public static func makeRegistry() -> OperationRegistry {
        var registry = OperationRegistry()
        registry.register(conversions())
        return registry
    }

    static func conversions() -> [any FileOperation] {
        var list: [any FileOperation] = []

        // Obrázky (8 lístků = celé kolo bez stránkování; vlastní formát se nenabízí)
        let images = ImageBackend.readable
        for format in [Format.png, .jpg, .webp, .heic, .avif, .tiff, .bmp] {
            list.append(imageConversion(to: format, from: images))
        }
        list.append(ConvertOperation("image", to: .pdf, from: images, converter: ImageBackend.convert))

        // Video
        let video = AVBackend.readableVideo
        list.append(ConvertOperation("video", to: .mp4, from: video, lane: .heavy, converter: AVBackend.export))
        list.append(ConvertOperation("video", to: .mov, from: video, lane: .heavy, converter: AVBackend.export))
        list.append(ConvertOperation("video", to: .gif, from: video, lane: .heavy, converter: AVBackend.gif))
        list.append(ConvertOperation("video", to: .m4a, from: video, lane: .heavy, converter: AVBackend.export))

        // Zvuk
        let audio = AVBackend.readableAudio
        for format in [Format.m4a, .wav, .aiff, .flac] {
            list.append(ConvertOperation("audio", to: format, from: audio, lane: .heavy, converter: AVBackend.audio))
        }

        // PDF
        list.append(ConvertOperation("pdf", to: .png, from: ["pdf"], converter: PDFBackend.images))
        list.append(ConvertOperation("pdf", to: .jpg, from: ["pdf"], converter: PDFBackend.images))
        list.append(ConvertOperation("pdf", to: .txt, from: ["pdf"], converter: PDFBackend.text))
        list.append(ConvertOperation("pdf", to: .md, from: ["pdf"], approximate: true, converter: PDFBackend.markdown))

        // Dokumenty a e-knihy
        let documents = TextBackend.readable
        for format in [Format.docx, .md, .txt, .epub, .html, .rtf] {
            list.append(ConvertOperation("document", to: format, from: documents, converter: TextBackend.convert))
        }

        // Tabulky
        let sheets: Set<String> = ["csv", "tsv", "xlsx"]
        for format in [Format.xlsx, .csv, .tsv] {
            list.append(ConvertOperation("sheet", to: format, from: sheets, converter: Spreadsheet.convert))
        }

        // Titulky
        let subtitles: Set<String> = ["srt", "vtt"]
        for format in [Format.srt, .vtt, .txt] {
            list.append(ConvertOperation("subtitle", to: format, from: subtitles, converter: Subtitles.convert))
        }

        // Archivy a složky
        for format in [Format.zip, .tar, .tgz] {
            list.append(ConvertOperation("archive", to: format, from: ArchiveBackend.readable, acceptsFolders: true,
                                         converter: ArchiveBackend.convert))
        }
        return list
    }

    /// Zápis přes ImageIO; WebP a AVIF jen tam, kde je systém umí (jinak je doplní fáze s nástroji).
    static func imageConversion(to format: Format, from inputs: Set<String>) -> ConvertOperation {
        ConvertOperation("image", to: format, from: inputs, requires: ImageBackend.canWrite(format) ? [] : [.tool(tool(for: format))],
                         converter: ImageBackend.convert)
    }

    private static func tool(for format: Format) -> ExternalTool {
        format == .avif ? .avifenc : .cwebp
    }
}
