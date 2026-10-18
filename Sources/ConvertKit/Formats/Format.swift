import Foundation

/// Cílový formát převodu.
public struct Format: Sendable, Hashable {
    public let id: String
    /// Popisek na lístku a ve jméně výsledku („PNG“ → „foto (PNG).png“).
    public let label: String
    /// Přípona výsledku.
    public let ext: String
    /// Další přípony téhož formátu (jpeg = jpg) – převod do stejného formátu se nenabízí.
    public let aliases: Set<String>

    public init(_ id: String, _ label: String, ext: String? = nil, aliases: Set<String> = []) {
        self.id = id
        self.label = label
        self.ext = ext ?? id
        self.aliases = aliases
    }

    /// Je přípona tímto formátem?
    public func matches(_ fileExtension: String) -> Bool {
        let lower = fileExtension.lowercased()
        return lower == ext || aliases.contains(lower)
    }
}

public extension Format {
    // Obrázky
    static let png = Format("png", "PNG")
    static let jpg = Format("jpg", "JPG", aliases: ["jpeg", "jpe"])
    static let webp = Format("webp", "WEBP")
    static let heic = Format("heic", "HEIC", aliases: ["heif"])
    static let avif = Format("avif", "AVIF")
    static let tiff = Format("tiff", "TIFF", aliases: ["tif"])
    static let bmp = Format("bmp", "BMP")
    static let gif = Format("gif", "GIF")
    static let pdf = Format("pdf", "PDF")

    // Video
    static let mp4 = Format("mp4", "MP4", aliases: ["m4v"])
    static let mov = Format("mov", "MOV")
    static let mkv = Format("mkv", "MKV")
    static let webm = Format("webm", "WEBM")
    static let avi = Format("avi", "AVI")
    static let wmv = Format("wmv", "WMV")

    // Zvuk
    static let mp3 = Format("mp3", "MP3")
    static let m4a = Format("m4a", "M4A", aliases: ["aac"])
    static let wav = Format("wav", "WAV")
    static let flac = Format("flac", "FLAC")
    static let ogg = Format("ogg", "OGG", aliases: ["oga"])
    static let opus = Format("opus", "OPUS")
    static let aiff = Format("aiff", "AIFF", aliases: ["aif", "aifc"])
    static let wma = Format("wma", "WMA")

    // Dokumenty
    static let docx = Format("docx", "DOCX")
    static let pages = Format("pages", "PAGES")
    static let txt = Format("txt", "TXT", aliases: ["text"])
    static let md = Format("md", "MD", aliases: ["markdown"])
    static let html = Format("html", "HTML", aliases: ["htm"])
    static let rtf = Format("rtf", "RTF")
    static let epub = Format("epub", "EPUB")
    static let odt = Format("odt", "ODT")

    // Prezentace a tabulky
    static let pptx = Format("pptx", "PPTX")
    static let xlsx = Format("xlsx", "XLSX")
    static let csv = Format("csv", "CSV")
    static let tsv = Format("tsv", "TSV")
    static let ods = Format("ods", "ODS")

    // Titulky
    static let srt = Format("srt", "SRT")
    static let vtt = Format("vtt", "VTT")

    // Archivy
    static let zip = Format("zip", "ZIP")
    static let tar = Format("tar", "TAR")
    static let tgz = Format("tgz", "GZIP", ext: "tar.gz", aliases: ["tgz", "gz"])
}
