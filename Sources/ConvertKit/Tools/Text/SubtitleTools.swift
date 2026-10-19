import Foundation

extension Selection {
    var allSubtitles: Bool { !isEmpty && kinds.allSatisfy { $0 == .subtitle } }
}

public enum SubtitleTools {
    // MARK: Úpravy časů

    /// Posune všechny titulky; co skončí před nulou, zmizí, co začíná před nulou, se ořízne na 0.
    public static func shifted(_ cues: [Subtitles.Cue], by offset: Double) -> [Subtitles.Cue] {
        cues.compactMap { cue in
            var shifted = cue
            shifted.start = cue.start + offset
            shifted.end = cue.end + offset
            guard shifted.end > 0 else { return nil }
            shifted.start = max(shifted.start, 0)
            return shifted
        }
    }

    /// Časy se násobí `factor` (např. titulky pro 23,976 fps k videu s 25 fps: 23,976 / 25).
    public static func scaled(_ cues: [Subtitles.Cue], by factor: Double) -> [Subtitles.Cue] {
        cues.map { cue in
            var scaled = cue
            scaled.start = cue.start * factor
            scaled.end = cue.end * factor
            return scaled
        }
    }

    /// Dva a víc souborů za sebou (druhý začíná po konci prvního) nebo přes sebe (dvojjazyčné titulky).
    public static func merged(_ tracks: [[Subtitles.Cue]], appending: Bool) -> [Subtitles.Cue] {
        var result: [Subtitles.Cue] = []
        var offset = 0.0
        for track in tracks {
            result += appending ? shifted(track, by: offset) : track
            if appending { offset = (result.map(\.end).max() ?? offset) + 0.1 }
        }
        return result.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func render(_ cues: [Subtitles.Cue], ext: String) -> String {
        ext == "vtt" ? Subtitles.vtt(cues) : Subtitles.srt(cues)
    }

    static func load(_ url: URL) throws -> [Subtitles.Cue] {
        let cues = Subtitles.parse(try TextBackend.readText(url))
        guard !cues.isEmpty else { throw ConvertError.unreadable(url.lastPathComponent) }
        return cues
    }

    @Sendable static func sameExtension(_ url: URL) -> String { url.pathExtension.lowercased() == "vtt" ? "vtt" : "srt" }

    // MARK: Nástroje

    public static let shift = Tool(
        id: "subtitle.tool.shift", title: "Posun", symbol: "arrow.left.and.right",
        options: [.slider("offset", "Posun", -60...60, default: 0, step: 0.1, unit: " s",
                          help: "Kladné číslo zpozdí titulky, záporné je předsune.")],
        accepts: { $0.allSubtitles },
        run: { context in
            let offset = context.double("offset") ?? 0
            guard offset != 0 else { throw ConvertError.unsupportedInput("nastav posun jinak než 0") }
            return try await EachImage.run(context, tag: "posun", outputExtension: sameExtension) { source, output, progress in
                let ext = output.pathExtension.lowercased()
                try render(shifted(try load(source), by: offset), ext: ext).write(to: output, atomically: false, encoding: .utf8)
                progress(1)
            }
        }
    )

    static let fpsChoices: [ToolOption.Choice] = ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"].map { .init($0, "\($0) fps") }

    public static let retime = Tool(
        id: "subtitle.tool.fps", title: "FPS", symbol: "speedometer",
        options: [
            .choice("from", "Titulky jsou pro", fpsChoices, default: "23.976"),
            .choice("to", "Video má", fpsChoices, default: "25"),
        ],
        accepts: { $0.allSubtitles },
        run: { context in
            let from = Double(context.string("from") ?? "") ?? 23.976
            let to = Double(context.string("to") ?? "") ?? 25
            guard from != to else { throw ConvertError.unsupportedInput("snímkování je stejné – není co měnit") }
            return try await EachImage.run(context, tag: "\(context.string("to") ?? "25") fps", outputExtension: sameExtension) { source, output, progress in
                try render(scaled(try load(source), by: from / to), ext: output.pathExtension.lowercased())
                    .write(to: output, atomically: false, encoding: .utf8)
                progress(1)
            }
        }
    )

    public static let merge = Tool(
        id: "subtitle.tool.merge", title: "Sloučit", symbol: "square.on.square",
        options: [.choice("mode", "Jak", [.init("overlay", "Přes sebe (dvojjazyčné)"), .init("append", "Za sebou")], default: "overlay")],
        editor: .order, needsMultiple: true,
        accepts: { $0.allSubtitles },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            let tracks = try urls.map(load)
            let ext = sameExtension(urls[0])
            let merged = merged(tracks, appending: context.string("mode") == "append")
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: ext, count: urls.count)
            let result = try await OutputPolicy.write(to: destination) { temporary in
                try render(merged, ext: ext).write(to: temporary, atomically: false, encoding: .utf8)
            }
            return [result]
        }
    )

    // MARK: Vypálení do videa

    /// Video + titulky vybrané společně.
    static func pair(_ selection: Selection) -> (video: URL, subtitle: URL)? {
        guard selection.count == 2, let video = zip(selection.urls, selection.kinds).first(where: { $0.1 == .video })?.0,
              let subtitle = zip(selection.urls, selection.kinds).first(where: { $0.1 == .subtitle })?.0 else { return nil }
        return (video, subtitle)
    }

    public static let burn = Tool(
        id: "subtitle.tool.burn", title: "Vypálit", symbol: "captions.bubble",
        options: [
            .slider("size", "Velikost písma", 12...60, default: 24, step: 1),
            .choice("position", "Poloha", [.init("bottom", "Dole"), .init("top", "Nahoře")], default: "bottom"),
            .slider("outline", "Obrys", 0...5, default: 2, step: 0.5),
        ],
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { pair($0) != nil },
        run: { context in
            guard let files = pair(context.selection) else { throw ConvertError.unsupportedInput("vyber jedno video a jeden soubor titulků") }
            let ffmpeg = try context.tools.require(.ffmpeg)
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            let info = try await MediaProbe.info(files.video, tools: context.tools)
            let destination = context.output.destination(for: files.video, tag: "titulky", extension: "mp4")
            let result = try await OutputPolicy.write(to: destination) { temporary in
                try await OutputPolicy.withScratch(near: temporary.deletingLastPathComponent()) { scratch in
                    // Titulky se zkopírují pod jednoduchým jménem a ffmpeg se spustí v té složce –
                    // cesta ve filtru `subtitles` by se jinak musela složitě escapovat.
                    let local = scratch.appendingPathComponent("titulky.\(sameExtension(files.subtitle))")
                    try FileManager.default.copyItem(at: files.subtitle, to: local)
                    let style = "FontSize=\(Int(context.double("size") ?? 24)),Outline=\(context.double("outline") ?? 2),Alignment=\(context.string("position") == "top" ? 6 : 2),MarginV=24"
                    var arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", files.video.path,
                                     "-vf", "subtitles=\(local.lastPathComponent):force_style='\(style)'"]
                    arguments += MediaTools.videoArguments(codec: "h264", crf: 21, encoders: encoders)
                    arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
                    arguments += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", temporary.path]
                    let progress = context.progress
                    try await ProcessRunner.run(ffmpeg, arguments, currentDirectory: scratch) { line in
                        guard info.duration > 0, line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                        progress(min(micros / 1_000_000 / info.duration, 0.99))
                    }
                }
            }
            context.progress(1)
            return [result]
        }
    )
}
