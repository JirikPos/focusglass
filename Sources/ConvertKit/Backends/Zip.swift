import Foundation

/// ZIP přes systémové nástroje (`/usr/bin/zip`, `/usr/bin/unzip`, `ditto`) – bez závislostí.
public enum Zip {
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Zabalí obsah složky (ne složku samotnou) – pro DOCX, XLSX a EPUB.
    /// `storedFirst` se uloží jako první položka bez komprese (EPUB vyžaduje `mimetype`).
    public static func archiveContents(of folder: URL, to output: URL, storedFirst: String? = nil) async throws {
        var entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        if let first = storedFirst {
            entries.removeAll { $0 == first }
            try await ProcessRunner.run(zip, ["-X0q", output.path, first], currentDirectory: folder)
        }
        guard !entries.isEmpty else { return }
        try await ProcessRunner.run(zip, ["-Xrq9", output.path] + entries.sorted(), currentDirectory: folder)
    }

    /// Rozbalí ZIP do složky (DOCX, XLSX, EPUB jsou ZIP).
    public static func extract(_ archive: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ProcessRunner.run(unzip, ["-qq", "-o", archive.path, "-d", folder.path])
    }

    /// Jeden soubor ze ZIPu do paměti, `nil` když v archivu není.
    public static func read(_ entry: String, from archive: URL) async throws -> Data? {
        do {
            let output = try await ProcessRunner.run(unzip, ["-p", archive.path, entry])
            return output.stdout
        } catch ConvertError.toolFailed(_, let status, _) where status == 11 {
            return nil // položka neexistuje
        }
    }
}
