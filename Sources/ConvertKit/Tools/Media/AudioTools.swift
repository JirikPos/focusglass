import AVFoundation
import CoreGraphics
import Foundation

/// Vlna zvuku: špičky po úsecích a obrázek pro náhledy.
public enum Waveform {
    /// Špičky (0…1) v `buckets` úsecích. AVAudioFile čte běžné formáty; ostatní se dekódují ffmpegem.
    public static func peaks(of url: URL, buckets: Int, tools: ToolLocator = .shared) async throws -> [Float] {
        guard buckets > 0 else { return [] }
        if let native = try? nativePeaks(url, buckets: buckets) { return native }
        return try await ffmpegPeaks(url, buckets: buckets, tools: tools)
    }

    private static func nativePeaks(_ url: URL, buckets: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        var position: AVAudioFramePosition = 0
        while position < total {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)
            for frame in 0..<count {
                var value: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) { value = max(value, abs(channels[channel][frame])) }
                let bucket = min(Int((Double(position) + Double(frame)) / Double(total) * Double(buckets)), buckets - 1)
                peaks[bucket] = max(peaks[bucket], value)
            }
            position += AVAudioFramePosition(count)
        }
        return peaks
    }

    private static func ffmpegPeaks(_ url: URL, buckets: Int, tools: ToolLocator) async throws -> [Float] {
        let ffmpeg = try tools.require(.ffmpeg)
        // Mono 2 kHz float – i hodina zvuku je ~29 MB.
        let output = try await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "2000", "-f", "f32le", "-",
        ])
        let samples = output.stdout.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: buckets) }
        var peaks = [Float](repeating: 0, count: buckets)
        for (index, sample) in samples.enumerated() {
            let bucket = min(index * buckets / samples.count, buckets - 1)
            peaks[bucket] = max(peaks[bucket], abs(sample))
        }
        return peaks
    }

    /// Vlna jako obrázek (bílé sloupce na tmavém pozadí) – pro náhledy nástrojů.
    public static func image(peaks: [Float], width: Int, height: Int, color: RGBA = RGBA(1, 1, 1, 0.9)) throws -> CGImage {
        let context = try ImageBackend.makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color.cgColor)
        let maximum = max(peaks.max() ?? 1, 0.001)
        let barWidth = max(CGFloat(width) / CGFloat(max(peaks.count, 1)), 1)
        for (index, peak) in peaks.enumerated() {
            // Mírná kompresní křivka, ať tiché pasáže nezmizí.
            let level = CGFloat(pow(peak / maximum, 0.7))
            let barHeight = max(level * CGFloat(height) * 0.9, 1.5)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: (CGFloat(height) - barHeight) / 2,
                                width: max(barWidth - 0.5, 0.75), height: barHeight))
        }
        guard let image = context.makeImage() else { throw ConvertError.writeFailed("vlna") }
        return image
    }

    public static func image(of url: URL, width: Int, height: Int, tools: ToolLocator = .shared) async throws -> CGImage {
        try image(peaks: try await peaks(of: url, buckets: max(width / 3, 1), tools: tools), width: width, height: height)
    }
}

/// Kodéry zvuku podle přípony výsledku.
enum AudioCodec {
    static func arguments(ext: String, bitrate: Int = 192, mono: Bool = false) -> [String] {
        var arguments: [String]
        switch ext {
        case "mp3": arguments = ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case "m4a", "aac": arguments = ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case "ogg", "oga": arguments = ["-c:a", "libvorbis", "-b:a", "\(bitrate)k"]
        case "opus": arguments = ["-c:a", "libopus", "-b:a", "\(bitrate)k"]
        case "flac": arguments = ["-c:a", "flac"]
        case "aif", "aiff": arguments = ["-c:a", "pcm_s16be"]
        default: arguments = ["-c:a", "pcm_s16le"]
        }
        if mono { arguments += ["-ac", "1"] }
        return arguments
    }

    /// Přípona výsledku, který zachová formát zdroje (bezeztrátové zůstává bezeztrátové).
    static func keep(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "ogg", "opus", "flac", "wav", "aiff"].contains(ext) ? ext : (ext == "aac" ? "m4a" : "m4a")
    }

    static func preview(_ request: PreviewRequest, caption: String?) async throws -> PreviewResult {
        PreviewResult(image: try await Waveform.image(of: request.source, width: 1400, height: 360), caption: caption)
    }
}

// MARK: - Střih

public enum AudioTrim {
    static let options: [ToolOption] = [
        .slider("fadeIn", "Náběh", 0...10, default: 0, step: 0.5, unit: " s"),
        .slider("fadeOut", "Dozvuk", 0...10, default: 0, step: 0.5, unit: " s", help: "S náběhem nebo dozvukem se zvuk překóduje; bez nich se jen přeřízne beze ztráty."),
    ]

    public static let tool = Tool(
        id: "audio.tool.trim", title: "Střih", symbol: "scissors", options: options, editor: .trim,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allAudio },
        run: { context in
            let fadeIn = context.double("fadeIn") ?? 0
            let fadeOut = context.double("fadeOut") ?? 0
            return try await EachImage.run(context, tag: "střih", outputExtension: { AudioCodec.keep($0) }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                let range = MediaTools.range(from: context, duration: info.duration)
                let length = range.end - range.start
                var arguments = ["-ss", MediaTools.seconds(range.start), "-t", MediaTools.seconds(length), "-vn"]
                if fadeIn > 0 || fadeOut > 0 {
                    var filters: [String] = []
                    if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(fadeIn)") }
                    if fadeOut > 0 { filters.append("afade=t=out:st=\(max(length - fadeOut, 0)):d=\(fadeOut)") }
                    arguments += ["-af", filters.joined(separator: ",")] + AudioCodec.arguments(ext: output.pathExtension.lowercased())
                } else {
                    arguments += ["-c:a", "copy"]
                }
                try await FFmpegBackend.transcode(source, to: output, arguments: arguments, tools: context.tools, progress: progress, duration: length)
            }
        }
    )
}

// MARK: - Komprese

public enum AudioCompress {
    static let options: [ToolOption] = [
        .choice("format", "Formát", [.init("keep", "Stejný"), .init("mp3", "MP3"), .init("m4a", "M4A (AAC)"), .init("opus", "Opus (nejmenší)")],
                default: "keep"),
        .choice("bitrate", "Kvalita", [.init("64", "64 kb/s (řeč)"), .init("96", "96 kb/s"), .init("128", "128 kb/s"), .init("160", "160 kb/s"),
                                       .init("192", "192 kb/s"), .init("256", "256 kb/s"), .init("320", "320 kb/s")], default: "128"),
        .toggle("mono", "Mono", default: false, help: "Poloviční velikost u nahrávek hlasu."),
    ]

    static func outputExtension(_ context: OperationContext, source: URL) -> String {
        let format = context.string("format") ?? "keep"
        if format != "keep" { return format }
        // Bezeztrátový zdroj by se „stejným“ formátem nezmenšil – převede se na M4A.
        let keep = AudioCodec.keep(source)
        return ["wav", "flac", "aiff"].contains(keep) ? "m4a" : keep
    }

    public static let tool = Tool(
        id: "audio.tool.compress", title: "Komprese", symbol: "arrow.down.right.and.arrow.up.left", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allAudio },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let info = try await MediaProbe.info(request.source)
            let bitrate = Int(context.string("bitrate") ?? "128") ?? 128
            let estimate = Int(Double(bitrate * 1000) / 8 * info.duration) / (context.bool("mono") == true ? 2 : 1)
            return try await AudioCodec.preview(request, caption: "\(ImageCompress.byteString(info.fileSize)) → ≈ \(ImageCompress.byteString(estimate))")
        },
        run: { context in
            let bitrate = Int(context.string("bitrate") ?? "128") ?? 128
            let mono = context.bool("mono") ?? false
            return try await EachImage.run(context, tag: "komprese", outputExtension: { outputExtension(context, source: $0) }) { source, output, progress in
                try await FFmpegBackend.transcode(source, to: output, arguments: ["-vn"] + AudioCodec.arguments(ext: output.pathExtension.lowercased(), bitrate: bitrate, mono: mono),
                                                  tools: context.tools, progress: progress)
            }
        }
    )
}

// MARK: - Sloučení

public enum AudioMerge {
    static let options: [ToolOption] = [
        .choice("format", "Formát", [.init("m4a", "M4A (AAC)"), .init("mp3", "MP3"), .init("wav", "WAV"), .init("flac", "FLAC")], default: "m4a"),
        .slider("crossfade", "Prolnutí", 0...5, default: 0, step: 0.5, unit: " s"),
    ]

    /// `filter_complex`: sjednotí vzorkování a skládá souvisle, nebo s prolnutím.
    static func graph(count: Int, crossfade: Double) -> String {
        var parts: [String] = (0..<count).map { "[\($0):a:0]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a\($0)]" }
        if crossfade > 0, count > 1 {
            var last = "a0"
            for index in 1..<count {
                let label = index == count - 1 ? "out" : "c\(index)"
                parts.append("[\(last)][a\(index)]acrossfade=d=\(crossfade):c1=tri:c2=tri[\(label)]")
                last = label
            }
        } else {
            parts.append((0..<count).map { "[a\($0)]" }.joined() + "concat=n=\(count):v=0:a=1[out]")
        }
        return parts.joined(separator: ";")
    }

    public static let tool = Tool(
        id: "audio.tool.merge", title: "Sloučit", symbol: "square.on.square", options: options, editor: .order,
        lane: .heavy, requirements: MediaTools.ffmpeg, needsMultiple: true,
        accepts: { $0.allAudio },
        run: { context in
            let urls = ImageCombine.ordered(context.selection, context)
            let ffmpeg = try context.tools.require(.ffmpeg)
            let format = context.string("format") ?? "m4a"
            var total = 0.0
            for url in urls { total += try await MediaProbe.info(url, tools: context.tools).duration }
            let destination = ImageCombine.destination(context, first: urls[0], tag: "Sloučeno", ext: format, count: urls.count)
            let crossfade = context.double("crossfade") ?? 0
            let result = try await OutputPolicy.write(to: destination) { temporary in
                var arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
                for url in urls { arguments += ["-i", url.path] }
                arguments += ["-filter_complex", graph(count: urls.count, crossfade: crossfade), "-map", "[out]"]
                arguments += AudioCodec.arguments(ext: format, bitrate: 256) + ["-progress", "pipe:1", "-nostats", temporary.path]
                let progress = context.progress
                let expected = max(total - crossfade * Double(urls.count - 1), 1)
                try await ProcessRunner.run(ffmpeg, arguments) { line in
                    guard line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                    progress(min(micros / 1_000_000 / expected, 0.99))
                }
            }
            context.progress(1)
            return [result]
        }
    )
}

// MARK: - Rozdělení

public enum AudioSplit {
    static let options: [ToolOption] = [
        .choice("mode", "Rozdělit", [.init("silence", "Podle ticha"), .init("every", "Po pevné délce")], default: "silence"),
        .slider("threshold", "Práh ticha", -60...(-20), default: -35, step: 1, unit: " dB", visibleWhen: .init("mode", "silence"),
                help: "Čím vyšší (blíž nule), tím víc zvuku se bere jako ticho."),
        .slider("minSilence", "Nejkratší ticho", 0.3...5, default: 1, step: 0.1, unit: " s", visibleWhen: .init("mode", "silence")),
        .number("length", "Délka dílu", 1...7200, default: 60, unit: "s", visibleWhen: .init("mode", "every")),
    ]

    /// Úseky mezi tichy: řez uprostřed každého ticha; příliš krátké úseky (< 0,5 s) se připojí k sousedovi.
    static func segments(silenceLog: String, duration: Double) -> [(start: Double, end: Double)] {
        var cuts: [Double] = []
        var pendingStart: Double?
        for line in silenceLog.split(separator: "\n") {
            if let range = line.range(of: "silence_start: ") {
                pendingStart = Double(line[range.upperBound...].split(separator: " ").first ?? "")
            } else if let range = line.range(of: "silence_end: ") {
                if let end = Double(line[range.upperBound...].split(separator: " ").first ?? "") {
                    let start = pendingStart ?? end
                    // Ticho na začátku nebo na konci souboru nic nedělí.
                    if start > 0.3, end < duration - 0.3 { cuts.append((start + end) / 2) }
                }
                pendingStart = nil
            }
        }
        var boundaries = [0.0] + cuts.filter { $0 > 0.5 && $0 < duration - 0.5 } + [duration]
        var index = 1
        while index < boundaries.count - 1 {
            if boundaries[index] - boundaries[index - 1] < 0.5 { boundaries.remove(at: index) } else { index += 1 }
        }
        return zip(boundaries, boundaries.dropFirst()).map { ($0, $1) }
    }

    static func fixed(length: Double, duration: Double) -> [(start: Double, end: Double)] {
        guard length > 0, duration > 0 else { return [] }
        return stride(from: 0.0, to: duration, by: length).map { ($0, min($0 + length, duration)) }
    }

    public static let tool = Tool(
        id: "audio.tool.split", title: "Rozdělit", symbol: "rectangle.split.3x1", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allAudio },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let info = try await MediaProbe.info(request.source)
            let parts = try await split(request.source, context: context, info: info)
            return try await AudioCodec.preview(request, caption: "\(Czech.count(parts.count, "díl", "díly", "dílů"))")
        },
        run: { context in
            var results: [URL] = []
            for source in context.selection.urls {
                try Task.checkCancellation()
                let info = try await MediaProbe.info(source, tools: context.tools)
                let parts = try await split(source, context: context, info: info)
                guard parts.count > 1 else { throw ConvertError.unsupportedInput("\(source.lastPathComponent) – nenašlo se kudy dělit") }
                let base = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension.lowercased()
                let digits = String(parts.count).count
                let folder = OutputPolicy.unique(context.output.directory(for: source).appendingPathComponent("\(base) (rozděleno)", isDirectory: true))
                results.append(try await OutputPolicy.write(to: folder) { temporary in
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    for (index, part) in parts.enumerated() {
                        try Task.checkCancellation()
                        let name = "\(base) \(String(format: "%0\(digits)d", index + 1)).\(ext)"
                        try await FFmpegBackend.transcode(
                            source, to: temporary.appendingPathComponent(name),
                            arguments: ["-ss", MediaTools.seconds(part.start), "-t", MediaTools.seconds(part.end - part.start), "-vn", "-c:a", "copy"],
                            tools: context.tools, progress: { _ in }, duration: part.end - part.start)
                        context.progress(Double(index + 1) / Double(parts.count))
                    }
                })
            }
            return results
        }
    )

    static func split(_ source: URL, context: OperationContext, info: MediaInfo) async throws -> [(start: Double, end: Double)] {
        if context.string("mode") == "every" { return fixed(length: Double(context.int("length") ?? 60), duration: info.duration) }
        let ffmpeg = try context.tools.require(.ffmpeg)
        let threshold = Int(context.double("threshold") ?? -35)
        let minimum = context.double("minSilence") ?? 1
        let output = try await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "info", "-i", source.path, "-vn",
            "-af", "silencedetect=noise=\(threshold)dB:d=\(minimum)", "-f", "null", "-",
        ])
        return segments(silenceLog: output.stderr, duration: info.duration)
    }
}

// MARK: - Normalizace hlasitosti

public enum AudioNormalize {
    public struct Measured: Sendable, Equatable {
        public let integrated: Double
        public let truePeak: Double
        public let range: Double
        public let threshold: Double
        public let offset: Double
    }

    /// Výsledek prvního průchodu `loudnorm` (JSON na konci stderr).
    static func parse(_ log: String) -> Measured? {
        guard let start = log.lastIndex(of: "{"), let end = log.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(log[start...end].utf8)) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { Double(json[key] as? String ?? "") ?? (json[key] as? Double) }
        guard let i = number("input_i"), let tp = number("input_tp"), let lra = number("input_lra"),
              let thresh = number("input_thresh"), let offset = number("target_offset"),
              i.isFinite, tp.isFinite else { return nil }
        return Measured(integrated: i, truePeak: tp, range: lra, threshold: thresh, offset: offset)
    }

    static func filter(target: Double, peak: Double, measured: Measured) -> String {
        String(format: "loudnorm=I=%.1f:TP=%.1f:LRA=11:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true",
               target, peak, measured.integrated, measured.truePeak, measured.range, measured.threshold, measured.offset)
    }

    static let options: [ToolOption] = [
        .choice("target", "Cílová hlasitost", [.init("-14", "−14 LUFS (streamování)"), .init("-16", "−16 LUFS (podcast)"),
                                               .init("-23", "−23 LUFS (rozhlas, EBU R128)")], default: "-16"),
    ]

    public static let tool = Tool(
        id: "audio.tool.normalize", title: "Hlasitost", symbol: "speaker.wave.2", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allAudio },
        run: { context in
            let target = Double(context.string("target") ?? "") ?? -16
            let ffmpeg = try context.tools.require(.ffmpeg)
            return try await EachImage.run(context, tag: "normalizováno", outputExtension: { AudioCodec.keep($0) }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                // 1. průchod: změřit.
                let analysis = try await ProcessRunner.run(ffmpeg, [
                    "-hide_banner", "-nostdin", "-nostats", "-loglevel", "info", "-i", source.path, "-vn",
                    "-af", "loudnorm=I=\(target):TP=-1.5:LRA=11:print_format=json", "-f", "null", "-",
                ])
                guard let measured = parse(analysis.stderr) else { throw ConvertError.unsupportedInput("\(source.lastPathComponent) – hlasitost nejde změřit (ticho?)") }
                progress(0.5)
                // 2. průchod: upravit podle naměřených hodnot (přesnější než jednoprůchodový režim).
                let ext = output.pathExtension.lowercased()
                try await FFmpegBackend.transcode(
                    source, to: output,
                    arguments: ["-vn", "-af", filter(target: target, peak: -1.5, measured: measured), "-ar", "48000"] + AudioCodec.arguments(ext: ext, bitrate: 256),
                    tools: context.tools, progress: { progress(0.5 + $0 * 0.5) }, duration: info.duration)
            }
        }
    )
}

// MARK: - Hlasitost a prolnutí

public enum AudioGain {
    static let options: [ToolOption] = [
        .slider("gain", "Zesílení", -20...20, default: 0, step: 0.5, unit: " dB"),
        .slider("fadeIn", "Náběh", 0...10, default: 0, step: 0.5, unit: " s"),
        .slider("fadeOut", "Dozvuk", 0...10, default: 0, step: 0.5, unit: " s"),
    ]

    public static let tool = Tool(
        id: "audio.tool.gain", title: "Úroveň", symbol: "dial.medium", options: options,
        lane: .heavy, requirements: MediaTools.ffmpeg,
        accepts: { $0.allAudio },
        run: { context in
            let gain = context.double("gain") ?? 0
            let fadeIn = context.double("fadeIn") ?? 0
            let fadeOut = context.double("fadeOut") ?? 0
            guard gain != 0 || fadeIn > 0 || fadeOut > 0 else { throw ConvertError.unsupportedInput("nic k úpravě – posuň některý jezdec") }
            return try await EachImage.run(context, tag: "úroveň", outputExtension: { AudioCodec.keep($0) }) { source, output, progress in
                let info = try await MediaProbe.info(source, tools: context.tools)
                var filters: [String] = []
                if gain != 0 { filters.append(String(format: "volume=%.1fdB", gain)) }
                // Při zesílení hlídá limiter, ať zvuk nepřebuzí.
                if gain > 0 { filters.append("alimiter=limit=0.97") }
                if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(fadeIn)") }
                if fadeOut > 0 { filters.append("afade=t=out:st=\(max(info.duration - fadeOut, 0)):d=\(fadeOut)") }
                try await FFmpegBackend.transcode(
                    source, to: output,
                    arguments: ["-vn", "-af", filters.joined(separator: ",")] + AudioCodec.arguments(ext: output.pathExtension.lowercased(), bitrate: 256),
                    tools: context.tools, progress: progress, duration: info.duration)
            }
        }
    )
}
