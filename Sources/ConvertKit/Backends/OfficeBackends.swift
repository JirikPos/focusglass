import Foundation

/// Pages, Keynote a Numbers přes AppleScript (`osascript`). Při prvním použití se macOS zeptá
/// na povolení ovládat aplikaci (Nastavení systému → Soukromí → Automatizace).
public enum IWorkBackend {
    public enum App: String, Sendable {
        case pages = "Pages"
        case keynote = "Keynote"
        case numbers = "Numbers"

        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    /// Formát exportu v AppleScript slovníku aplikace pro cílový formát.
    static func exportFormat(app: App, target: Format) -> String? {
        switch (app, target.id) {
        case (.pages, "docx"): "Microsoft Word"
        case (.pages, "pdf"), (.keynote, "pdf"), (.numbers, "pdf"): "PDF"
        case (.pages, "epub"): "EPUB"
        case (.pages, "txt"): "unformatted text"
        case (.keynote, "pptx"): "Microsoft PowerPoint"
        case (.keynote, "png"), (.keynote, "jpg"): "slide images"
        case (.numbers, "xlsx"): "Microsoft Excel"
        case (.numbers, "csv"): "CSV"
        default: nil
        }
    }

    /// Převodník: otevře vstup v aplikaci, exportuje / uloží a dokument zavře bez uložení změn.
    public static func converter(_ app: App) -> Converter {
        { job in
            let work = try workDirectory(for: app)
            defer { try? FileManager.default.removeItem(at: work) }
            let exported = work.appendingPathComponent(job.file.lastPathComponent)
            try await ProcessRunner.run(osascript, ["-e", script(app: app, input: job.source, output: exported, target: job.target)])
            job.progress(0.9)
            // Keynote exportuje snímky do složky; Numbers CSV s víc tabulkami také.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: exported.path, isDirectory: &isDirectory) else {
                throw ConvertError.invalidOutput(job.file.lastPathComponent)
            }
            let destination = isDirectory.boolValue ? job.scratch.appendingPathComponent(job.baseName) : job.file
            try FileManager.default.moveItem(at: exported, to: destination)
            job.progress(1)
            return destination
        }
    }

    /// AppleScript pro export. Cesty jsou escapované; chyba exportu dokument stejně zavře.
    static func script(app: App, input: URL, output: URL, target: Format) -> String {
        let inPath = escape(input.path)
        let outPath = escape(output.path)
        let action: String
        if (app == .pages && target.id == "pages") || (app == .keynote && target.id == "key")
            || (app == .numbers && target.id == "numbers") {
            action = #"save theDoc in (POSIX file "\#(outPath)")"#
        } else if let format = exportFormat(app: app, target: target) {
            if format == "slide images" {
                let imageFormat = target.id == "png" ? "PNG" : "JPEG"
                action = #"export theDoc to (POSIX file "\#(outPath)") as slide images with properties {image format:\#(imageFormat)}"#
            } else {
                action = #"export theDoc to (POSIX file "\#(outPath)") as \#(format)"#
            }
        } else {
            action = #"error "Nepodporovaný formát""#
        }
        return """
        tell application id "\(app.bundleID)"
            set theDoc to open (POSIX file "\(inPath)")
            try
                \(action)
            on error errorMessage number errorNumber
                close theDoc saving no
                error errorMessage number errorNumber
            end try
            close theDoc saving no
        end tell
        """
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// iWork aplikace jsou v sandboxu: export spolehlivě zapíšou jen do vlastního kontejneru.
    /// Výsledek se odtud přesune do scratch složky.
    static func workDirectory(for app: App) throws -> URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(app.bundleID)/Data/tmp", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: container.path) ? container : FileManager.default.temporaryDirectory
        let work = base.appendingPathComponent("FocusGlass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }
}

/// LibreOffice v režimu bez okna (`soffice --headless --convert-to`). Záloha, když chybí iWork,
/// a jediná cesta pro ODS / ODP.
public enum LibreOfficeBackend {
    /// Filtr `--convert-to` pro cílový formát.
    static func filter(for target: Format) -> String? {
        switch target.id {
        case "pdf", "docx", "xlsx", "pptx", "ods", "odt", "rtf", "html": target.ext
        case "csv": "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case "txt": "txt:Text"
        default: nil
        }
    }

    public static let convert: Converter = { job in
        let soffice = try job.tools.require(.soffice)
        guard let filter = filter(for: job.target) else { throw ConvertError.unsupportedInput(job.source.lastPathComponent) }
        let outDir = job.temporary("libreoffice")
        // Vlastní profil: nekoliduje s otevřeným LibreOffice a nemění nastavení uživatele.
        let profile = job.temporary("profil")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try await ProcessRunner.run(soffice, [
            "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nologo",
            "--convert-to", filter, "--outdir", outDir.path, job.source.path,
        ])
        let produced = outDir.appendingPathComponent(job.source.deletingPathExtension().lastPathComponent + "." + job.target.ext)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConvertError.invalidOutput(job.file.lastPathComponent)
        }
        try FileManager.default.moveItem(at: produced, to: job.file)
        job.progress(1)
        return job.file
    }
}
