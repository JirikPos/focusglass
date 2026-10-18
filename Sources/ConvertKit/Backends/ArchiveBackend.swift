import Foundation

/// Archivy přes systémové nástroje: bsdtar (`/usr/bin/tar` rozbalí ZIP, TAR, GZIP, RAR, 7z) a ditto.
/// bsdtar ve výchozím stavu odmítá absolutní cesty a „..“ (ochrana proti zip-slip).
public enum ArchiveBackend {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    public static let readable: Set<String> = ["zip", "tar", "gz", "tgz", "tar.gz", "bz2", "xz", "rar", "7z"]

    /// Archiv nebo složka → ZIP / TAR / TAR.GZ.
    public static let convert: Converter = { job in
        let isFolder = FileKind.of(job.source) == .folder
        let content: URL
        if isFolder {
            content = job.source
        } else {
            content = try await extract(job.source, into: job.temporary("obsah"))
        }
        job.progress(0.5)
        try await create(job.target, from: content, to: job.file)
        job.progress(1)
        return job.file
    }

    /// Rozbalí archiv do složky a vrátí, co zabalit: jedinou složku uvnitř, nebo celý obsah.
    @discardableResult
    public static func extract(_ archive: URL, into folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".gz"), !name.hasSuffix(".tar.gz") {
            // Samostatný .gz (ne tar) – jen dekomprese jednoho souboru.
            let output = try await ProcessRunner.run(gzip, ["-dc", archive.path])
            let target = folder.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
            try output.stdout.write(to: target)
            return folder
        }
        try await ProcessRunner.run(tar, ["-xf", archive.path, "-C", folder.path])
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
        if items.count == 1 {
            let only = folder.appendingPathComponent(items[0])
            if FileKind.of(only) == .folder { return only }
        }
        return folder
    }

    /// Zabalí složku (se jménem složky uvnitř archivu) nebo soubor.
    public static func create(_ format: Format, from source: URL, to output: URL) async throws {
        let parent = source.deletingLastPathComponent()
        switch format.id {
        case "zip":
            // ditto zachová oprávnění a symlinky; bez resource forků a __MACOSX, ať je ZIP čistý i pro Windows.
            try await ProcessRunner.run(Zip.ditto, ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", source.path, output.path])
        case "tar":
            try await ProcessRunner.run(tar, ["-cf", output.path, "-C", parent.path, source.lastPathComponent])
        default:
            try await ProcessRunner.run(tar, ["-czf", output.path, "-C", parent.path, source.lastPathComponent])
        }
    }
}
