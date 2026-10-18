import Foundation
import UniformTypeIdentifiers

/// Druh souboru – určuje, jaké převody a nástroje kolo nabídne.
public enum FileKind: String, CaseIterable, Sendable {
    case image
    case video
    case audio
    case pdf
    case document
    case slides
    case spreadsheet
    case epub
    case subtitle
    case archive
    case folder
    case other

    public var title: String {
        switch self {
        case .image: "Obrázek"
        case .video: "Video"
        case .audio: "Zvuk"
        case .pdf: "PDF"
        case .document: "Dokument"
        case .slides: "Prezentace"
        case .spreadsheet: "Tabulka"
        case .epub: "E-kniha"
        case .subtitle: "Titulky"
        case .archive: "Archiv"
        case .folder: "Složka"
        case .other: "Soubor"
        }
    }

    /// Přípony s jednoznačným druhem. Mají přednost před UTType, který se mezi systémy liší
    /// (např. `.srt` nebo `.md` nemusí mít registrovaný typ vůbec).
    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.image, "jpg jpeg png heic heif webp avif tif tiff bmp gif svg ico jp2 psd raw dng cr2 nef arw")
        add(.video, "mp4 m4v mov mkv webm avi wmv flv mpg mpeg 3gp ts mts")
        add(.audio, "mp3 m4a aac wav aif aiff aifc flac ogg oga opus wma caf alac")
        add(.pdf, "pdf")
        add(.document, "docx doc pages rtf rtfd txt text md markdown html htm odt textclipping")
        add(.slides, "pptx ppt key odp")
        add(.spreadsheet, "xlsx xls numbers csv tsv ods")
        add(.epub, "epub")
        add(.subtitle, "srt vtt")
        add(.archive, "zip tar gz tgz bz2 xz rar 7z")
        return map
    }()

    /// Druh podle přípony; bez souborového systému (vhodné pro testy a výběry z pasteboardu).
    public static func of(fileExtension ext: String) -> FileKind {
        let ext = ext.lowercased()
        if let kind = byExtension[ext] { return kind }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        return of(type: type)
    }

    public static func of(type: UTType) -> FileKind {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .epub) { return .epub }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .presentation) { return .slides }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }

    /// Druh skutečného souboru. Balíčky (`.rtfd`, `.pages`, `.key`) se berou jako soubory, ne složky.
    public static func of(_ url: URL) -> FileKind {
        let kind = of(fileExtension: url.pathExtension)
        if kind != .other { return kind }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return .folder }
        return .other
    }
}
