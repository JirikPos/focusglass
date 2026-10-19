import Foundation

extension Selection {
    var allArchives: Bool { !isEmpty && kinds.allSatisfy { $0 == .archive } }
}

public enum ArchiveTools {
    /// Symbolické odkazy, které míří mimo rozbalenou složku (útok přes škodlivý archiv), se smažou.
    /// Vrací počet odstraněných odkazů.
    @discardableResult
    static func removeEscapingLinks(in root: URL) -> Int {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var removed = 0
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return 0 }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
            let resolved = target.standardizedFileURL.path
            if resolved != base, !resolved.hasPrefix(base + "/") {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    /// Rozbalí do `folder`; ZIP s heslem přes `unzip -P`.
    static func extract(_ archive: URL, into folder: URL, password: String?) async throws {
        let isZip = archive.pathExtension.lowercased() == "zip"
        if isZip, let password, !password.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try await ProcessRunner.run(Zip.unzip, ["-qq", "-o", "-P", password, archive.path, "-d", folder.path, "-x", "__MACOSX/*"])
            } catch ConvertError.toolFailed(_, let status, _) where status == 82 || status == 1 {
                throw ConvertError.wrongPassword(archive.lastPathComponent)
            }
            return
        }
        do {
            try await ArchiveBackend.extract(archive, into: folder)
        } catch ConvertError.toolFailed(_, _, let detail) where detail.lowercased().contains("passphrase") || detail.lowercased().contains("encrypted") {
            throw ConvertError.passwordRequired(archive.lastPathComponent)
        }
    }

    public static let extractTool = Tool(
        id: "archive.tool.extract", title: "Rozbalit", symbol: "archivebox",
        options: [.secret("password", "Heslo", help: "Jen pro ZIP chráněný heslem; jinak nech prázdné.")],
        accepts: { $0.allArchives },
        run: { context in
            var results: [URL] = []
            for (index, source) in context.selection.urls.enumerated() {
                try Task.checkCancellation()
                let base = OutputPolicy.fileName(for: source, tag: nil, extension: "")
                let destination = OutputPolicy.unique(context.output.directory(for: source).appendingPathComponent(base, isDirectory: true))
                results.append(try await OutputPolicy.write(to: destination) { temporary in
                    try await OutputPolicy.withScratch(near: temporary.deletingLastPathComponent()) { scratch in
                        let work = scratch.appendingPathComponent("obsah", isDirectory: true)
                        try await extract(source, into: work, password: context.string("password"))
                        removeEscapingLinks(in: work)
                        // Jediná složka v archivu se nezdvojuje („x/x/…“): její obsah je výsledek.
                        let items = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
                        let root = items.count == 1 && FileKind.of(work.appendingPathComponent(items[0])) == .folder
                            ? work.appendingPathComponent(items[0]) : work
                        try FileManager.default.moveItem(at: root, to: temporary)
                    }
                })
                context.progress(Double(index + 1) / Double(context.selection.count))
            }
            return results
        }
    )

    public static let listTool = Tool(
        id: "archive.tool.list", title: "Obsah", symbol: "list.bullet",
        accepts: { $0.allArchives },
        run: { context in
            try await EachImage.run(context, tag: "obsah", outputExtension: { _ in "txt" }) { source, output, progress in
                let listing = try await ProcessRunner.run(ArchiveBackend.tar, ["-tvf", source.path])
                let text = String(decoding: listing.stdout, as: UTF8.self)
                    .split(separator: "\n").filter { !$0.contains("__MACOSX") }.joined(separator: "\n")
                try (text + "\n").write(to: output, atomically: false, encoding: .utf8)
                progress(1)
            }
        }
    )
}
