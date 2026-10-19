import CoreGraphics
import Foundation
import ImageIO

/// Čtení, úprava a mazání metadat obrázků (EXIF, GPS, IPTC, TIFF).
/// JPEG se upravuje bezeztrátově (pixely se nepřekódují); ostatní formáty se zapíšou znovu
/// (PNG bez ztráty, HEIC ve vysoké kvalitě), protože ImageIO u nich metadata na místě nemění.
public enum ImageMetadata {
    public struct Entry: Sendable, Equatable {
        public let group: String
        public let name: String
        public let value: String
    }

    public enum Action: String, Sendable {
        case strip, location, edit
    }

    public struct Edit: Sendable, Equatable {
        public var author: String?
        public var copyright: String?
        public var description: String?
        public var date: Date?
        public var make: String?
        public var model: String?
        /// Stupně; `nil` = beze změny.
        public var latitude: Double?
        public var longitude: Double?
        public var removeLocation = false

        public init() {}

        public var isEmpty: Bool {
            author == nil && copyright == nil && description == nil && date == nil && make == nil && model == nil
                && latitude == nil && longitude == nil && !removeLocation
        }
    }

    // MARK: Čtení

    /// Čitelný výpis metadat pro okno nástroje.
    public static func read(_ url: URL) -> [Entry] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        var entries: [Entry] = []
        if let width = all[kCGImagePropertyPixelWidth] as? Int, let height = all[kCGImagePropertyPixelHeight] as? Int {
            entries.append(Entry(group: "Soubor", name: "Rozměry", value: "\(width) × \(height) px"))
        }
        if let profile = all[kCGImagePropertyProfileName] as? String {
            entries.append(Entry(group: "Soubor", name: "Barevný profil", value: profile))
        }
        let tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = all[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        func add(_ group: String, _ name: String, _ value: Any?) {
            guard let value, !"\(value)".isEmpty else { return }
            entries.append(Entry(group: group, name: name, value: "\(value)"))
        }
        add("Fotoaparát", "Výrobce", tiff[kCGImagePropertyTIFFMake])
        add("Fotoaparát", "Model", tiff[kCGImagePropertyTIFFModel])
        add("Fotoaparát", "Objektiv", exif[kCGImagePropertyExifLensModel])
        add("Fotoaparát", "Software", tiff[kCGImagePropertyTIFFSoftware])
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double {
            add("Expozice", "Čas", time < 1 ? "1/\(Int((1 / time).rounded())) s" : "\(time) s")
        }
        add("Expozice", "Clona", (exif[kCGImagePropertyExifFNumber] as? Double).map { "f/\($0)" })
        add("Expozice", "ISO", (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first)
        add("Expozice", "Ohnisko", (exif[kCGImagePropertyExifFocalLength] as? Double).map { "\(Int($0.rounded())) mm" })
        add("Datum", "Pořízeno", exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        add("Autor", "Autor", tiff[kCGImagePropertyTIFFArtist])
        add("Autor", "Autorská práva", tiff[kCGImagePropertyTIFFCopyright])
        add("Autor", "Popis", tiff[kCGImagePropertyTIFFImageDescription])
        add("Autor", "Komentář", exif[kCGImagePropertyExifUserComment])
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            add("Poloha", "Souřadnice", String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef))
        }
        return entries
    }

    public static func hasLocation(_ url: URL) -> Bool {
        read(url).contains { $0.group == "Poloha" }
    }

    /// „50.0875, 14.4213“ nebo „50,0875; 14,4213“ → (lat, lon); `nil`, když to není souřadnice.
    public static func parseCoordinates(_ text: String) -> (Double, Double)? {
        let parts = text.replacingOccurrences(of: ";", with: ",").components(separatedBy: ",")
        // Desetinná čárka: „50,0875, 14,4213“ má čtyři části.
        let numbers: [Double]
        if parts.count == 4 {
            numbers = [Double("\(parts[0].trimmed).\(parts[1].trimmed)"), Double("\(parts[2].trimmed).\(parts[3].trimmed)")].compactMap { $0 }
        } else if parts.count == 2 {
            numbers = parts.compactMap { Double($0.trimmed) }
        } else {
            return nil
        }
        guard numbers.count == 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]) else { return nil }
        return (numbers[0], numbers[1])
    }

    // MARK: Zápis

    /// Zapíše kopii `source` do `output` s upravenými metadaty.
    public static func apply(_ action: Action, edit: Edit = Edit(), source: URL, output: URL) throws {
        let isJPEG = ["jpg", "jpeg", "jpe"].contains(source.pathExtension.lowercased())
        if isJPEG, (try? applyLossless(action, edit: edit, source: source, output: output)) != nil { return }
        try applyByRewriting(action, edit: edit, source: source, output: output)
    }

    // MARK: JPEG beze ztráty

    private static func applyLossless(_ action: Action, edit: Edit, source: URL, output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(imageSource),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw ConvertError.unreadable(source.lastPathComponent)
        }
        let metadata = CGImageMetadataCreateMutable()
        let existing = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil)

        /// Smaže existující značky, které vyhovují filtru (kCFNull = odstranit).
        func remove(where matches: @escaping (String, String) -> Bool) {
            guard let existing else { return }
            CGImageMetadataEnumerateTagsUsingBlock(existing, nil, nil) { _, tag in
                guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                      let namespace = CGImageMetadataTagCopyNamespace(tag),
                      let name = CGImageMetadataTagCopyName(tag) as String? else { return true }
                if matches(prefix, name) {
                    CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix as CFString, nil)
                    _ = CGImageMetadataSetValueWithPath(metadata, nil, "\(prefix):\(name)" as CFString, kCFNull)
                }
                return true
            }
        }
        func set(_ path: String, _ value: String) {
            _ = CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }

        switch action {
        case .strip:
            // Orientace zůstává, jinak by se fotka otočila.
            remove { prefix, name in !(prefix == "tiff" && name == "Orientation") }
        case .location:
            remove { _, name in name.hasPrefix("GPS") }
        case .edit:
            if edit.removeLocation { remove { _, name in name.hasPrefix("GPS") } }
            // Autor, práva a popis ImageIO zapisuje přes XMP (Dublin Core) – přímý zápis `tiff:Artist` se ignoruje.
            if let value = edit.author { set("dc:creator", value) }
            if let value = edit.copyright { set("dc:rights", value) }
            if let value = edit.description { set("dc:description", value) }
            if let value = edit.make { set("tiff:Make", value) }
            if let value = edit.model { set("tiff:Model", value) }
            if let date = edit.date {
                let text = xmpDate(date)
                set("exif:DateTimeOriginal", text)
                set("exif:DateTimeDigitized", text)
                set("tiff:DateTime", text)
            }
            if let lat = edit.latitude, let lon = edit.longitude {
                set("exif:GPSLatitude", gpsString(lat, positive: "N", negative: "S"))
                set("exif:GPSLongitude", gpsString(lon, positive: "E", negative: "W"))
            }
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, imageSource, options as CFDictionary, &error) else {
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
    }

    // MARK: Ostatní formáty: nový zápis

    private static func applyByRewriting(_ action: Action, edit: Edit, source: URL, output: URL) throws {
        let image = try ImageBackend.load(source)
        let format = ImageBackend.keepFormat(for: source)
        var properties = ImageBackend.carriedProperties(of: source, stripping: action == .strip)
        func update(_ key: CFString, _ change: (inout [CFString: Any]) -> Void) {
            var dictionary = properties[key] as? [CFString: Any] ?? [:]
            change(&dictionary)
            properties[key] = dictionary.isEmpty ? nil : dictionary
        }
        switch action {
        case .strip: break
        case .location: properties[kCGImagePropertyGPSDictionary] = nil
        case .edit:
            if edit.removeLocation { properties[kCGImagePropertyGPSDictionary] = nil }
            update(kCGImagePropertyTIFFDictionary) { tiff in
                if let value = edit.author { tiff[kCGImagePropertyTIFFArtist] = value }
                if let value = edit.copyright { tiff[kCGImagePropertyTIFFCopyright] = value }
                if let value = edit.description { tiff[kCGImagePropertyTIFFImageDescription] = value }
                if let value = edit.make { tiff[kCGImagePropertyTIFFMake] = value }
                if let value = edit.model { tiff[kCGImagePropertyTIFFModel] = value }
                if let date = edit.date { tiff[kCGImagePropertyTIFFDateTime] = exifDate(date) }
            }
            if let date = edit.date {
                update(kCGImagePropertyExifDictionary) { exif in
                    exif[kCGImagePropertyExifDateTimeOriginal] = exifDate(date)
                    exif[kCGImagePropertyExifDateTimeDigitized] = exifDate(date)
                }
            }
            if let lat = edit.latitude, let lon = edit.longitude {
                update(kCGImagePropertyGPSDictionary) { gps in
                    gps[kCGImagePropertyGPSLatitude] = abs(lat)
                    gps[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
                    gps[kCGImagePropertyGPSLongitude] = abs(lon)
                    gps[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
                }
            }
        }
        // HEIC se zapisuje znovu, proto vysoká kvalita; PNG a TIFF jsou bezeztrátové.
        try ImageBackend.encode(image, as: format, quality: ImageBackend.isLossy(format) ? 0.95 : nil, properties: properties)
            .write(to: output)
    }

    // MARK: Formáty

    /// 50.0875 → „50,5.2500N“ (stupně, minuty s desetinami) – tvar, který ImageIO přijímá v XMP.
    static func gpsString(_ value: Double, positive: String, negative: String) -> String {
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutes = (absolute - Double(degrees)) * 60
        return String(format: "%d,%.6f%@", degrees, minutes, value >= 0 ? positive : negative)
    }

    static func xmpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    static func exifDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// „2024-05-01“ nebo „2024-05-01 14:30“ (i s tečkami „1. 5. 2024“); `nil`, když to není datum.
    public static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "d. M. yyyy HH:mm", "d. M. yyyy", "d.M.yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: Nástroj

    static let options: [ToolOption] = [
        .choice("action", "Co udělat", [.init("strip", "Odstranit všechna metadata"), .init("location", "Odstranit jen polohu"),
                                        .init("edit", "Upravit")], default: "strip"),
        .text("author", "Autor", visibleWhen: .init("action", "edit")),
        .text("copyright", "Autorská práva", visibleWhen: .init("action", "edit")),
        .text("description", "Popis", visibleWhen: .init("action", "edit")),
        .text("date", "Datum pořízení", placeholder: "2024-05-01 14:30", visibleWhen: .init("action", "edit"),
              help: "Prázdné = beze změny."),
        .text("make", "Výrobce fotoaparátu", visibleWhen: .init("action", "edit")),
        .text("model", "Model fotoaparátu", visibleWhen: .init("action", "edit")),
        .text("location", "Poloha", placeholder: "50.0875, 14.4213", visibleWhen: .init("action", "edit")),
        .toggle("removeLocation", "Odstranit polohu", visibleWhen: .init("action", "edit")),
    ]

    static func edit(from context: OperationContext) -> Edit {
        func text(_ key: String) -> String? {
            let value = (context.string(key) ?? "").trimmed
            return value.isEmpty ? nil : value
        }
        var edit = Edit()
        edit.author = text("author")
        edit.copyright = text("copyright")
        edit.description = text("description")
        edit.make = text("make")
        edit.model = text("model")
        edit.date = text("date").flatMap(parseDate)
        if let coordinates = text("location").flatMap(parseCoordinates) {
            edit.latitude = coordinates.0
            edit.longitude = coordinates.1
        }
        edit.removeLocation = context.bool("removeLocation") ?? false
        return edit
    }

    public static let tool = Tool(
        id: "image.tool.metadata", title: "Metadata", symbol: "tag.slash", options: options,
        accepts: { $0.allImages },
        preview: { request in
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            let lines = read(request.source).map { "\($0.name): \($0.value)" }
            return PreviewResult(image: image, caption: lines.isEmpty ? "Žádná metadata" : lines.joined(separator: "\n"))
        },
        run: { context in
            let action = Action(rawValue: context.string("action") ?? "") ?? .strip
            let edit = edit(from: context)
            if action == .edit, edit.isEmpty { throw ConvertError.unsupportedInput("nic k úpravě – vyplň aspoň jedno pole") }
            let tag = switch action {
            case .strip: "bez metadat"
            case .location: "bez polohy"
            case .edit: "upraveno"
            }
            return try await EachImage.run(context, tag: tag, outputExtension: EachImage.keepExtension) { source, output, progress in
                try apply(action, edit: edit, source: source, output: output)
                progress(1)
            }
        }
    )
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
