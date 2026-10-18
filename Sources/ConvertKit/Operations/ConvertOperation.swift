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

    public init(source: URL, scratch: URL, baseName: String, target: Format, tools: ToolLocator = .shared,
                options: [String: OptionValue] = [:], progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.source = source
        self.scratch = scratch
        self.baseName = baseName
        self.target = target
        self.tools = tools
        self.options = options
        self.progress = progress
    }

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

    /// Mezikrok: stejný job s jiným zdrojem / cílem a průběhem v daném úseku (např. 0…0,5).
    public func step(source: URL? = nil, target: Format? = nil, progressRange: ClosedRange<Double> = 0...1) -> ConversionJob {
        let parent = progress
        let span = progressRange.upperBound - progressRange.lowerBound
        let isIntermediate = target != nil && target != self.target
        return ConversionJob(
            source: source ?? self.source,
            scratch: scratch,
            baseName: isIntermediate ? ".step-\(UUID().uuidString)" : baseName,
            target: target ?? self.target,
            tools: tools, options: options,
            progress: { parent(progressRange.lowerBound + span * min(max($0, 0), 1)) }
        )
    }
}

/// Převodník vrací URL hotového výsledku uvnitř `job.scratch` (soubor nebo složku).
public typealias Converter = @Sendable (ConversionJob) async throws -> URL

/// Převodníky za sebou: `first` vyrobí mezivýsledek ve formátu `via`, `then` z něj cíl.
public func chain(_ first: @escaping Converter, via: Format, then second: @escaping Converter) -> Converter {
    { job in
        let middle = try await first(job.step(target: via, progressRange: 0...0.5))
        return try await second(job.step(source: middle, progressRange: 0.5...1))
    }
}

/// Jedna cesta převodu: pro které vstupy, co potřebuje a čím se převádí.
public struct ConvertRoute: Sendable {
    public let inputs: Set<String>
    public let requirements: [Requirement]
    public let approximate: Bool
    public let converter: Converter

    public init(_ inputs: Set<String>, requires requirements: [Requirement] = [], approximate: Bool = false,
                converter: @escaping Converter) {
        self.inputs = inputs
        self.requirements = requirements
        self.approximate = approximate
        self.converter = converter
    }

    func isAvailable(_ tools: ToolLocator) -> Bool {
        requirements.allSatisfy { Requirement.isMet($0, tools: tools) }
    }
}

/// Převod souborů do jednoho formátu. Pro každý soubor se vybere první cesta, která ho umí
/// a má k dispozici nástroje (nativní cesty jsou v seznamu dřív než ffmpeg / aplikace).
public struct ConvertOperation: FileOperation {
    public let id: String
    public let target: Format
    public let routes: [ConvertRoute]
    public let acceptsFolders: Bool
    public let lane: Lane

    public var title: String { target.label }
    public var wheel: Wheel { .convert }
    public var requirements: [Requirement] { routes.first?.requirements ?? [] }
    public var isApproximate: Bool { routes.contains { $0.approximate } }

    public init(_ group: String, to target: Format, routes: [ConvertRoute], acceptsFolders: Bool = false,
                lane: Lane = .light) {
        self.id = "\(group).convert.\(target.id)"
        self.target = target
        self.routes = routes
        self.acceptsFolders = acceptsFolders
        self.lane = lane
    }

    /// Jedna cesta (zkratka).
    public init(_ group: String, to target: Format, from inputs: Set<String>, acceptsFolders: Bool = false,
                lane: Lane = .light, requires requirements: [Requirement] = [], approximate: Bool = false,
                converter: @escaping Converter) {
        self.init(group, to: target,
                  routes: [ConvertRoute(inputs, requires: requirements, approximate: approximate, converter: converter)],
                  acceptsFolders: acceptsFolders, lane: lane)
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
            guard routes.contains(where: { $0.inputs.contains(ext) }) else { return false }
            if !target.matches(ext) { anyDifferent = true }
        }
        // PNG → PNG nenabízet.
        return anyDifferent
    }

    /// Cesta pro soubor: první dostupná, jinak první vůbec (kvůli nápovědě, co doinstalovat).
    func route(for url: URL, tools: ToolLocator) -> ConvertRoute? {
        let ext = FileKind.of(url) == .folder ? "" : Self.extensionOf(url)
        let matching = routes.filter { ext.isEmpty ? acceptsFolders : $0.inputs.contains(ext) }
        return matching.first { $0.isAvailable(tools) } ?? matching.first
    }

    public func availability(for selection: Selection, tools: ToolLocator) -> Availability {
        for url in selection.urls {
            guard let route = route(for: url, tools: tools) else { continue }
            for requirement in route.requirements where !Requirement.isMet(requirement, tools: tools) {
                return .missing(hint: requirement.hint)
            }
        }
        return .available
    }

    public func isApproximate(for selection: Selection) -> Bool {
        selection.urls.contains { route(for: $0, tools: .shared)?.approximate == true }
    }

    public func run(_ context: OperationContext) async throws -> [URL] {
        let urls = context.selection.urls.filter { url in
            FileKind.of(url) == .folder || !target.matches(Self.extensionOf(url))
        }
        var results: [URL] = []
        for (index, source) in urls.enumerated() {
            try Task.checkCancellation()
            guard let route = route(for: source, tools: context.tools) else {
                throw ConvertError.unsupportedInput(source.lastPathComponent)
            }
            for requirement in route.requirements where !Requirement.isMet(requirement, tools: context.tools) {
                throw requirement.missingError
            }
            let directory = context.output.directory(for: source)
            let baseName = OutputPolicy.fileName(for: source, tag: target.label, extension: "")
            let share = 1.0 / Double(urls.count)
            let result = try await OutputPolicy.withScratch(near: directory) { scratch in
                let job = ConversionJob(
                    source: source, scratch: scratch, baseName: baseName, target: target,
                    tools: context.tools, options: context.options,
                    progress: { value in context.progress((Double(index) + min(max(value, 0), 1)) * share) }
                )
                let produced = try await route.converter(job)
                return try OutputPolicy.place(produced, as: directory.appendingPathComponent(produced.lastPathComponent))
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
