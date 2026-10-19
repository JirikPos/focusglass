import CoreGraphics
import Foundation

extension Selection {
    var allVideos: Bool { !isEmpty && kinds.allSatisfy { $0 == .video } }
    var allAudio: Bool { !isEmpty && kinds.allSatisfy { $0 == .audio } }
}

/// Společné pomůcky nástrojů pro video a zvuk (vše přes ffmpeg).
enum MediaTools {
    static let ffmpeg: [Requirement] = [.tool(.ffmpeg), .tool(.ffprobe)]

    /// Kodér a jeho parametry podle toho, co ffmpeg umí. `crf` je pro x264; x265 dostane o 4 víc (stejná kvalita).
    static func videoArguments(codec: String, crf: Int, bitrate: Int? = nil, encoders: Set<String>) -> [String] {
        let hevc = codec == "hevc"
        let software = hevc ? "libx265" : "libx264"
        var arguments: [String]
        if encoders.contains(software) {
            arguments = ["-c:v", software, "-preset", "medium", "-pix_fmt", "yuv420p"]
            if let bitrate {
                arguments += ["-b:v", String(bitrate), "-maxrate", String(Int(Double(bitrate) * 1.5)), "-bufsize", String(bitrate * 2)]
            } else {
                arguments += ["-crf", String(hevc ? crf + 4 : crf)]
            }
        } else {
            // Bez softwarového kodéru zbývá hardware (VideoToolbox): kvalita 0–100.
            arguments = ["-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox", "-pix_fmt", "yuv420p", "-allow_sw", "1"]
            if let bitrate { arguments += ["-b:v", String(bitrate)] } else { arguments += ["-q:v", String(max(20, min(90, 110 - crf * 2)))] }
        }
        if hevc { arguments += ["-tag:v", "hvc1"] }
        return arguments
    }

    /// Řetěz filtru `atempo` (každý umí jen 0,5…2×).
    static func atempoChain(_ factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 + 1e-9 { parts.append("atempo=2.0"); remaining /= 2 }
        while remaining < 0.5 - 1e-9 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append(String(format: "atempo=%.4f", remaining))
        return parts.joined(separator: ",")
    }

    /// Čas v sekundách pro `-ss`.
    static func seconds(_ value: Double) -> String { String(format: "%.3f", max(value, 0)) }

    /// Popis „1920×1080 → 1280×720“.
    static func sizeCaption(_ from: MediaInfo, to: CGSize) -> String {
        "\(from.width)×\(from.height) → \(Int(to.width))×\(Int(to.height))"
    }

    /// Čtení času z voleb: 0 u `end` = do konce.
    static func range(from context: OperationContext, duration: Double) -> (start: Double, end: Double) {
        let start = min(max(context.double("start") ?? 0, 0), max(duration - 0.05, 0))
        var end = context.double("end") ?? 0
        if end <= 0 || end > duration { end = duration }
        return (start, max(end, start + 0.05))
    }

    /// Náhled: snímek v daném bodě s volitelným filtrem a popiskem.
    static func framePreview(_ request: PreviewRequest, fraction: Double = 0.1, filter: String? = nil,
                             caption: String?) async throws -> PreviewResult {
        let image: CGImage
        if let filter {
            image = try await MediaFrames.ffmpegFrame(of: request.source, fraction: fraction, filter: filter, maxPixel: request.maxPixel)
        } else {
            image = try await MediaFrames.frame(of: request.source, fraction: fraction, maxPixel: request.maxPixel)
        }
        return PreviewResult(image: image, caption: caption)
    }

    static func tools(_ context: OperationContext) -> ToolLocator { context.tools }
}

// MARK: - Komprese

public enum VideoCompress {
    static let options: [ToolOption] = [
        .choice("mode", "Způsob", [.init("preset", "Kvalita"), .init("target", "Cílová velikost")], default: "preset"),
        .choice("quality", "Kvalita", [.init("small", "Malý soubor"), .init("balanced", "Vyvážená"), .init("high", "Vysoká")],
                default: "balanced", visibleWhen: .init("mode", "preset")),
        .number("targetMB", "Cílová velikost", 1...20_000, default: 25, unit: "MB", visibleWhen: .init("mode", "target"),
                help: "Přibližná – skutečná velikost se může lišit o několik procent."),
        .choice("height", "Největší výška", [.init("0", "Beze změny"), .init("2160", "2160 p (4K)"), .init("1440", "1440 p"),
                                              .init("1080", "1080 p"), .init("720", "720 p"), .init("480", "480 p")], default: "0"),
        .choice("codec", "Kodek", [.init("h264", "H.264 (nejkompatibilnější)"), .init("hevc", "H.265 (menší soubor)")], default: "h264"),
        .toggle("mute", "Odstranit zvuk", default: false),
    ]

    static func arguments(_ context: OperationContext, info: MediaInfo, encoders: Set<String>) -> [String] {
        let codec = context.string("codec") ?? "h264"
        let crf: Int
        switch context.string("quality") {
        case "small": crf = 30
        case "high": crf = 21
        default: crf = 26
        }
        var arguments: [String] = []
        var bitrate: Int?
        if context.string("mode") == "target", info.duration > 0 {
            let totalBits = Double(max(context.int("targetMB") ?? 25, 1)) * 8 * 1_000_000
            let audio = context.bool("mute") == true || !info.hasAudio ? 0 : 128_000
            // 4 % rezerva na kontejner a nepřesnosti řízení přenosové rychlosti.
            bitrate = max(Int(totalBits * 0.96 / info.duration) - audio, 80_000)
        }
        arguments += MediaTools.videoArguments(codec: codec, crf: crf, bitrate: bitrate, encoders: encoders)
        if let height = Int(context.string("height") ?? ""), height > 0, info.height > height {
            arguments += ["-vf", "scale=-2:\(height)"]
        }
        if context.bool("mute") == true || !info.hasAudio { arguments += ["-an"] } else { arguments += ["-c:a", "aac", "-b:a", "128k"] }
        return arguments + ["-movflags", "+faststart"]
    }

    public static let tool = Tool(
        id: "video.tool.compress", title: "Komprese", symbol: "arrow.down.right.and.arrow.up.left", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options, progress: { _ in })
            let info = try await MediaProbe.info(request.source)
            var caption = "\(info.resolution) · \(ImageCompress.byteString(info.fileSize))"
            if let height = Int(context.string("height") ?? ""), height > 0, info.height > height {
                let width = Int((Double(info.width) * Double(height) / Double(info.height) / 2).rounded()) * 2
                caption = "\(info.width)×\(info.height) → \(width)×\(height)"
            }
            if context.string("mode") == "target" {
                caption += " · cíl ≈ \(context.int("targetMB") ?? 25) MB"
            }
            return try await MediaTools.framePreview(request, caption: caption)
        },
        run: { context in
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            return try await EachImage.run(context, tag: "komprese", outputExtension: { _ in "mp4" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments(context, info: info, encoders: encoders),
                                                  tools: context.tools, progress: progress, duration: info.duration)
            }
        }
    )
}

// MARK: - Střih

public enum VideoTrim {
    static let options: [ToolOption] = [
        .choice("precise", "Režim", [.init("true", "Přesně (překóduje)"), .init("false", "Rychle (beze ztráty, na klíčových snímcích)")],
                default: "true", help: "Rychlý režim jen přeřízne tok – okamžitě a bez ztráty kvality, ale začátek se zaokrouhlí na nejbližší klíčový snímek."),
    ]

    public static let tool = Tool(
        id: "video.tool.trim", title: "Střih", symbol: "scissors", options: options, editor: .trim,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        run: { context in
            let precise = context.string("precise") != "false"
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            let extensionFor: @Sendable (URL) -> String = { url in precise ? "mp4" : url.pathExtension.lowercased() }
            return try await EachImage.run(context, tag: "střih", outputExtension: extensionFor) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                let range = MediaTools.range(from: context, duration: info.duration)
                var arguments = ["-ss", MediaTools.seconds(range.start), "-t", MediaTools.seconds(range.end - range.start)]
                if precise {
                    arguments += MediaTools.videoArguments(codec: "h264", crf: 20, encoders: encoders)
                    arguments += info.hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
                    arguments += ["-movflags", "+faststart"]
                } else {
                    arguments += ["-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"]
                }
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments,
                                                  tools: context.tools, progress: progress, duration: range.end - range.start)
            }
        }
    )
}

// MARK: - Ořez obrazu

public enum VideoCrop {
    /// Filtr `crop` (a `scale` u přesných rozměrů) pro daný film.
    static func filter(_ context: OperationContext, info: MediaInfo) throws -> (filter: String, output: CGSize) {
        let plan = try ImageCrop.plan(for: CGSize(width: info.width, height: info.height), spec: ImageCrop.spec(from: context))
        // YUV 4:2:0 chce sudé rozměry i posuny.
        func even(_ value: CGFloat) -> Int { max(2, Int(value / 2) * 2) }
        let width = even(plan.rect.width), height = even(plan.rect.height)
        var chain = "crop=\(width):\(height):\(Int(plan.rect.minX / 2) * 2):\(Int(plan.rect.minY / 2) * 2)"
        var output = CGSize(width: width, height: height)
        if Int(plan.output.width) != Int(plan.rect.width) || Int(plan.output.height) != Int(plan.rect.height) {
            let outWidth = even(plan.output.width), outHeight = even(plan.output.height)
            chain += ",scale=\(outWidth):\(outHeight):flags=lanczos"
            output = CGSize(width: outWidth, height: outHeight)
        }
        return (chain, output)
    }

    public static let tool = Tool(
        id: "video.tool.crop", title: "Ořez", symbol: "crop", options: ImageCrop.options, editor: .crop,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let info = try await MediaProbe.info(request.source)
            let result = try filter(context, info: info)
            return try await MediaTools.framePreview(request, caption: "Výsledek \(Int(result.output.width))×\(Int(result.output.height)) px")
        },
        run: { context in
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            return try await EachImage.run(context, tag: "ořez", outputExtension: { _ in "mp4" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                let result = try filter(context, info: info)
                var arguments = ["-vf", result.filter] + MediaTools.videoArguments(codec: "h264", crf: 20, encoders: encoders)
                arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments + ["-movflags", "+faststart"],
                                                  tools: context.tools, progress: progress, duration: info.duration)
            }
        }
    )
}

// MARK: - Změna velikosti

public enum VideoResize {
    static let options: [ToolOption] = [
        .choice("height", "Výška", [.init("2160", "2160 p (4K)"), .init("1440", "1440 p"), .init("1080", "1080 p (Full HD)"),
                                    .init("720", "720 p (HD)"), .init("480", "480 p"), .init("360", "360 p")], default: "720"),
        .toggle("shrinkOnly", "Jen zmenšovat", default: true, help: "Menší video se nezvětšuje."),
    ]

    static func size(_ context: OperationContext, info: MediaInfo) -> CGSize {
        let target = Int(context.string("height") ?? "") ?? 720
        guard info.height > 0, !(context.bool("shrinkOnly") ?? true && info.height <= target) else {
            return CGSize(width: info.width, height: info.height)
        }
        return CGSize(width: Int((Double(info.width) * Double(target) / Double(info.height) / 2).rounded()) * 2, height: target)
    }

    public static let tool = Tool(
        id: "video.tool.resize", title: "Velikost", symbol: "arrow.up.left.and.arrow.down.right", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let info = try await MediaProbe.info(request.source)
            return try await MediaTools.framePreview(request, caption: MediaTools.sizeCaption(info, to: size(context, info: info)))
        },
        run: { context in
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            return try await EachImage.run(context, tag: "velikost", outputExtension: { _ in "mp4" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                let target = size(context, info: info)
                var arguments = ["-vf", "scale=\(Int(target.width)):\(Int(target.height)):flags=lanczos"]
                arguments += MediaTools.videoArguments(codec: "h264", crf: 21, encoders: encoders)
                arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments + ["-movflags", "+faststart"],
                                                  tools: context.tools, progress: progress, duration: info.duration)
            }
        }
    )
}

// MARK: - Sloučení

public enum VideoMerge {
    /// Argumenty `filter_complex`: všechna videa se sjednotí na rozměr a snímkování prvního,
    /// chybějící zvuk se doplní tichem.
    static func graph(infos: [MediaInfo]) -> (inputs: [String], filter: String, silenceCount: Int) {
        let width = max(infos.first?.width ?? 1280, 2) / 2 * 2
        let height = max(infos.first?.height ?? 720, 2) / 2 * 2
        var inputs: [String] = []
        var parts: [String] = []
        var labels = ""
        var silence = 0
        for (index, info) in infos.enumerated() {
            parts.append("[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)]")
            if info.hasAudio {
                parts.append("[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            } else {
                // Ticho stejné délky jako video: samostatný vstup `anullsrc` za všemi soubory.
                let silenceInput = infos.count + silence
                inputs += ["-f", "lavfi", "-t", MediaTools.seconds(info.duration), "-i", "anullsrc=r=48000:cl=stereo"]
                parts.append("[\(silenceInput):a:0]aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
                silence += 1
            }
            labels += "[v\(index)][a\(index)]"
        }
        parts.append("\(labels)concat=n=\(infos.count):v=1:a=1[v][a]")
        return (inputs, parts.joined(separator: ";"), silence)
    }

    public static let tool = Tool(
        id: "video.tool.merge", title: "Sloučit", symbol: "square.on.square", editor: .order,
        lane: .heavy, requirements: MediaTools.ffmpeg, needsMultiple: true,
        accepts: { $0.allVideos },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            let ffmpeg = try context.tools.require(.ffmpeg)
            var infos: [MediaInfo] = []
            for url in urls { infos.append(try await MediaProbe.info(url, tools: context.tools)) }
            let total = infos.reduce(0) { $0 + $1.duration }
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            let graph = graph(infos: infos)
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: "mp4", count: urls.count)
                .deletingPathExtension().appendingPathExtension("mp4")

            let result = try await OutputPolicy.write(to: destination) { temporary in
                var arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
                for url in urls { arguments += ["-i", url.path] }
                arguments += graph.inputs
                arguments += ["-filter_complex", graph.filter, "-map", "[v]", "-map", "[a]"]
                arguments += MediaTools.videoArguments(codec: "h264", crf: 21, encoders: encoders)
                arguments += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", temporary.path]
                let progress = context.progress
                try await ProcessRunner.run(ffmpeg, arguments) { line in
                    guard total > 0, line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                    progress(min(micros / 1_000_000 / total, 0.99))
                }
            }
            context.progress(1)
            return [result]
        }
    )
}

// MARK: - Bez zvuku, zvuk, rychlost, otočení, snímky, GIF

public enum VideoMute {
    public static let tool = Tool(
        id: "video.tool.mute", title: "Bez zvuku", symbol: "speaker.slash",
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        run: { context in
            try await EachImage.run(context, tag: "bez zvuku", outputExtension: { $0.pathExtension.lowercased() }) { source, output, progress in
                // Obraz se jen zkopíruje – okamžité a beze ztráty.
                try await FFmpegBackend.transcode(source, to: output, arguments: ["-map", "0:v", "-c:v", "copy", "-an"],
                                                  tools: context.tools, progress: progress)
            }
        }
    )
}

public enum VideoExtractAudio {
    static let options: [ToolOption] = [
        .choice("format", "Formát", [.init("m4a", "M4A (AAC)"), .init("mp3", "MP3"), .init("wav", "WAV (bez ztráty)"),
                                     .init("flac", "FLAC (bez ztráty)"), .init("opus", "Opus")], default: "m4a"),
        .choice("bitrate", "Kvalita", [.init("128", "128 kb/s"), .init("192", "192 kb/s"), .init("256", "256 kb/s"), .init("320", "320 kb/s")],
                default: "192", visibleWhen: .init("format", "m4a", "mp3", "opus")),
    ]

    static func arguments(format: String, bitrate: String) -> [String] {
        switch format {
        case "mp3": ["-vn", "-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case "wav": ["-vn", "-c:a", "pcm_s16le"]
        case "flac": ["-vn", "-c:a", "flac"]
        case "opus": ["-vn", "-c:a", "libopus", "-b:a", "\(bitrate)k"]
        default: ["-vn", "-c:a", "aac", "-b:a", "\(bitrate)k"]
        }
    }

    public static let tool = Tool(
        id: "video.tool.audio", title: "Zvuk", symbol: "waveform", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        run: { context in
            let format = context.string("format") ?? "m4a"
            return try await EachImage.run(context, tag: "zvuk", outputExtension: { _ in format }) { source, output, progress in
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments(format: format, bitrate: context.string("bitrate") ?? "192"),
                                                  tools: context.tools, progress: progress)
            }
        }
    )
}

public enum VideoSpeed {
    static let options: [ToolOption] = [
        .choice("factor", "Rychlost", [.init("0.25", "0,25× (čtvrtinová)"), .init("0.5", "0,5× (zpomalit)"), .init("0.75", "0,75×"),
                                       .init("1.5", "1,5×"), .init("2", "2× (zrychlit)"), .init("3", "3×"), .init("4", "4×"), .init("8", "8×")],
                default: "2"),
        .toggle("mute", "Odstranit zvuk", default: false),
    ]

    public static let tool = Tool(
        id: "video.tool.speed", title: "Rychlost", symbol: "speedometer", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        run: { context in
            let factor = Double(context.string("factor") ?? "") ?? 2
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            return try await EachImage.run(context, tag: "rychlost", outputExtension: { _ in "mp4" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                var arguments = ["-filter:v", "setpts=PTS/\(factor)"]
                arguments += MediaTools.videoArguments(codec: "h264", crf: 21, encoders: encoders)
                if info.hasAudio, context.bool("mute") != true {
                    arguments += ["-filter:a", MediaTools.atempoChain(factor), "-c:a", "aac", "-b:a", "192k"]
                } else {
                    arguments += ["-an"]
                }
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments + ["-movflags", "+faststart"],
                                                  tools: context.tools, progress: progress, duration: info.duration / factor)
            }
        }
    )
}

public enum VideoRotate {
    static let options: [ToolOption] = [
        .choice("turn", "Otočit", [.init("cw", "90° doprava"), .init("ccw", "90° doleva"), .init("180", "180°"),
                                   .init("flipH", "Převrátit vodorovně"), .init("flipV", "Převrátit svisle")], default: "cw"),
    ]

    static func filter(_ turn: String?) -> String {
        switch turn {
        case "ccw": "transpose=2"
        case "180": "transpose=1,transpose=1"
        case "flipH": "hflip"
        case "flipV": "vflip"
        default: "transpose=1"
        }
    }

    public static let tool = Tool(
        id: "video.tool.rotate", title: "Otočit", symbol: "rotate.right", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            return try await MediaTools.framePreview(request, filter: filter(context.string("turn")), caption: nil)
        },
        run: { context in
            let filter = filter(context.string("turn"))
            let encoders = await FFmpegCapabilities.encoders(tools: context.tools)
            return try await EachImage.run(context, tag: "otočeno", outputExtension: { _ in "mp4" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                var arguments = ["-vf", filter] + MediaTools.videoArguments(codec: "h264", crf: 20, encoders: encoders)
                arguments += info.hasAudio ? ["-c:a", "copy"] : ["-an"]
                // Metadata o otočení se nepřenášejí – jinak by přehrávač otočil podruhé.
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments + ["-metadata:s:v", "rotate=0", "-movflags", "+faststart"],
                                                  tools: context.tools, progress: progress, duration: info.duration)
            }
        }
    )
}

public enum VideoFrames {
    static let options: [ToolOption] = [
        .choice("mode", "Co uložit", [.init("single", "Jeden snímek"), .init("every", "Snímek každých N sekund")], default: "single"),
        .slider("position", "Pozice", 0...100, default: 10, step: 1, unit: " %", visibleWhen: .init("mode", "single")),
        .number("interval", "Každých", 1...3600, default: 5, unit: "s", visibleWhen: .init("mode", "every")),
        .choice("format", "Formát", [.init("png", "PNG (bez ztráty)"), .init("jpg", "JPG")], default: "png"),
    ]

    public static let tool = Tool(
        id: "video.tool.frames", title: "Snímky", symbol: "photo.stack", options: options,
        requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let fraction = (context.double("position") ?? 10) / 100
            return try await MediaTools.framePreview(request, fraction: fraction, caption: nil)
        },
        run: { context in
            let format = context.string("format") ?? "png"
            let every = context.string("mode") == "every"
            var results: [URL] = []
            for source in context.selection.urls {
                try Task.checkCancellation()
                let info = try await MediaProbe.info(source, tools: context.tools)
                let base = source.deletingPathExtension().lastPathComponent
                let directory = context.output.directory(for: source)
                let quality = format == "jpg" ? ["-q:v", "2"] : []
                if every {
                    let folder = OutputPolicy.unique(directory.appendingPathComponent("\(base) (snímky)", isDirectory: true))
                    results.append(try await OutputPolicy.write(to: folder) { temporary in
                        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                        let interval = max(context.int("interval") ?? 5, 1)
                        try await FFmpegBackend.transcode(
                            source, to: temporary.appendingPathComponent("\(base) %04d.\(format)"),
                            arguments: ["-vf", "fps=1/\(interval)"] + quality, tools: context.tools, progress: context.progress, duration: info.duration)
                    })
                } else {
                    let destination = context.output.destination(for: source, tag: "snímek", extension: format)
                    let position = info.duration * (context.double("position") ?? 10) / 100
                    results.append(try await OutputPolicy.write(to: destination) { temporary in
                        try await FFmpegBackend.transcode(
                            source, to: temporary, arguments: ["-frames:v", "1"] + quality, inputArguments: ["-ss", MediaTools.seconds(position)],
                            tools: context.tools, progress: context.progress, duration: 1)
                    })
                }
            }
            return results
        }
    )
}

public enum VideoGIF {
    static let options: [ToolOption] = [
        .choice("width", "Šířka", [.init("320", "320 px"), .init("480", "480 px"), .init("640", "640 px"), .init("800", "800 px")], default: "480"),
        .slider("fps", "Snímků za sekundu", 5...30, default: 12, step: 1),
        .toggle("loop", "Opakovat dokola", default: true),
        .number("start", "Od", 0...86_400, default: 0, unit: "s"),
        .number("length", "Délka (0 = celé)", 0...600, default: 0, unit: "s"),
    ]

    public static let tool = Tool(
        id: "video.tool.gif", title: "GIF", symbol: "livephoto", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allVideos },
        run: { context in
            let fps = Int(context.double("fps") ?? 12)
            let width = context.string("width") ?? "480"
            return try await EachImage.run(context, tag: "GIF", outputExtension: { _ in "gif" }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                let start = Double(context.int("start") ?? 0)
                let length = Double(context.int("length") ?? 0)
                let input: [String] = start > 0 ? ["-ss", MediaTools.seconds(start)] : []
                var arguments: [String] = []
                if length > 0 { arguments += ["-t", MediaTools.seconds(length)] }
                arguments += ["-vf", "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                              "-loop", context.bool("loop") == false ? "-1" : "0"]
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments, inputArguments: input, tools: context.tools,
                                                  progress: progress, duration: length > 0 ? length : max(info.duration - start, 1))
            }
        }
    )
}
