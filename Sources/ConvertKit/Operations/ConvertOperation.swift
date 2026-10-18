import Foundation

/// Jeden převod jednoho souboru – co dostane převodník.
public struct ConversionJob: Sendable {
    public let source: URL
    /// Prázdná dočasná složka na stejném svazku jako cíl.
    public let scratch: URL
    /// Jméno výsledku bez přípony („foto (PNG)“).
    public let baseName: String
    public let target: Format
    public let tools: ToolLocator
    public let options: [String: OptionValue]
    public let progress: @Sendable (Double) -> Void

    /// Výsledný soubor ve scratch složce (s příponou cíle).
    public var file: URL { scratch.appendingPathComponent("\(baseName).\(target.ext)") }

    /// Výsledná složka (víc souborů, např. stránky PDF jako PNG) – vytvoří ji.
    public func folder() throws -> URL {
        let url = scratch.appendingPathComponent(baseName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pomocný soubor ve scratch složce, který se nepřesune do cíle.
    public func temporary(_ name: String) -> URL {
        scratch.appendingPathComponent(".work-\(UUID().uuidString)-\(name)")
    }
}

/// Převodník vrací URL hotového výsledku uvnitř `job.scratch` (soubor nebo složku).
public typealias Converter = @Sendable (ConversionJob) async throws -> URL

/// Převod souborů z daných přípon do jednoho formátu. Víc souborů = každý zvlášť.
public struct ConvertOperation: FileOperation {
    public let id: String
    public let target: Format
    public let inputs: Set<String>
    public let acceptsFolders: Bool
    public let lane: Lane
    public let requirements: [Requirement]
    public let isApproximate: Bool
    let converter: Converter

    public var title: String { target.label }
    public var wheel: Wheel { .convert }

    public init(
        _ group: String,
        to target: Format,
        from inputs: Set<String>,
        acceptsFolders: Bool = false,
        lane: Lane = .light,
        requires requirements: [Requirement] = [],
        approximate: Bool = false,
        converter: @escaping Converter
    ) {
        self.id = "\(group).convert.\(target.id)"
        self.target = target
        self.inputs = inputs
        self.acceptsFolders = acceptsFolders
        self.lane = lane
        self.requirements = requirements
        self.isApproximate = approximate
        self.converter = converter
    }

    public func accepts(_ selection: Selection) -> Bool {
        guard !selection.isEmpty else { return false }
        var anyDifferent = false
        for (url, kind) in zip(selection.urls, selection.kinds) {
            if kind == .folder {
                guard acceptsFolders else { return false }
                anyDifferent = true
                continue
            }
            let ext = Self.extensionOf(url)
            guard inputs.contains(ext) else { return false }
            if !target.matches(ext) { anyDifferent = true }
        }
        // PNG → PNG nenabízet.
        return anyDifferent
    }

    public func run(_ context: OperationContext) async throws -> [URL] {
        let urls = context.selection.urls.filter { url in
            FileKind.of(url) == .folder || !target.matches(Self.extensionOf(url))
        }
        var results: [URL] = []
        for (index, source) in urls.enumerated() {
            try Task.checkCancellation()
            let directory = context.output.directory(for: source)
            let baseName = OutputPolicy.fileName(for: source, tag: target.label, extension: "")
            let share = 1.0 / Double(urls.count)
            let result = try await OutputPolicy.withScratch(near: directory) { scratch in
                let job = ConversionJob(
                    source: source, scratch: scratch, baseName: baseName, target: target,
                    tools: context.tools, options: context.options,
                    progress: { value in context.progress((Double(index) + min(max(value, 0), 1)) * share) }
                )
                let produced = try await converter(job)
                let name = produced.lastPathComponent
                return try OutputPolicy.place(produced, as: directory.appendingPathComponent(name))
            }
            results.append(result)
            context.progress(Double(index + 1) * share)
        }
        return results
    }

    /// Přípona v malých písmenech; „x.tar.gz“ → „tar.gz“.
    static func extensionOf(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tar.gz" }
        return url.pathExtension.lowercased()
    }
}
