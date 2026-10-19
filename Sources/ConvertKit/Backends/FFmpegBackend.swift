import Foundation

/// Video a zvuk přes ffmpeg (volitelný, `brew install ffmpeg`). H.264 kóduje hardwarově (VideoToolbox).
public enum FFmpegBackend {
    public static let videoInputs: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts", "ogv",
    ]
    public static let audioInputs: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus", "wma", "amr",
    ]

    /// Libovolný vstup → `job.target`.
    public static let convert: Converter = { job in
        try await transcode(job.source, to: job.file, arguments: arguments(for: job.target), job: job)
        return job.file
    }

    /// Parametry kodérů pro cílový formát. Vyvážené na kvalitu (ne nejmenší soubor).
    static func arguments(for target: Format) -> [String] {
        let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
        switch target.id {
        case "mp4": return h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov": return h264 + ["-c:a", "aac", "-b:a", "192k"]
        // MKV unese cokoli – bez překódování (rychlé a bezeztrátové).
        case "mkv": return ["-map", "0:v?", "-map", "0:a?", "-c", "copy"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                             "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": return ["-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif": return ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                            "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "6"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "wma": return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default: return []
        }
    }

    /// Spustí ffmpeg s průběhem podle délky vstupu (ffprobe) a výstupem `-progress`.
    public static func transcode(_ input: URL, to output: URL, arguments: [String], inputArguments: [String] = [],
                                 extraInputs: [URL] = [], job: ConversionJob, duration: Double? = nil) async throws {
        try await transcode(input, to: output, arguments: arguments, inputArguments: inputArguments, extraInputs: extraInputs,
                            tools: job.tools, progress: job.progress, duration: duration)
    }

    /// Totéž bez `ConversionJob` (nástroje). `duration` je délka **výstupu** pro výpočet průběhu.
    public static func transcode(_ input: URL, to output: URL, arguments: [String], inputArguments: [String] = [],
                                 extraInputs: [URL] = [], tools: ToolLocator, progress: @escaping @Sendable (Double) -> Void,
                                 duration: Double? = nil) async throws {
        let ffmpeg = try tools.require(.ffmpeg)
        let total: Double?
        if let duration { total = duration } else { total = await probeDuration(input, tools: tools) }
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + inputArguments + ["-i", input.path]
        for extra in extraInputs { args += ["-i", extra.path] }
        args += arguments + ["-progress", "pipe:1", "-nostats", output.path]
        do {
            try await run(ffmpeg, args, total: total, progress: progress)
        } catch ConvertError.toolFailed(_, _, let detail) where detail.contains("does not contain any stream") {
            // Např. MP3 z videa bez zvuku.
            throw ConvertError.noAudio(input.lastPathComponent)
        }
        progress(1)
    }

    private static func run(_ ffmpeg: URL, _ args: [String], total: Double?,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ProcessRunner.run(ffmpeg, args) { line in
            // „out_time_us=1234567“ – mikrosekundy zpracovaného výstupu.
            guard let total, total > 0, line.hasPrefix("out_time_us="),
                  let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(micros / 1_000_000 / total, 0.99))
        }
    }

    /// Délka v sekundách (ffprobe); `nil`, když ffprobe chybí nebo délku nezná.
    public static func probeDuration(_ url: URL, tools: ToolLocator) async -> Double? {
        guard let ffprobe = tools.url(for: .ffprobe) else { return nil }
        let output = try? await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ])
        return output.flatMap { Double(String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// WebP a AVIF přes cwebp / avifenc (ImageIO je zapsat neumí na každém systému).
public enum ImageEncoders {
    public static let webp: Converter = { job in
        let cwebp = try job.tools.require(.cwebp)
        let png = try intermediatePNG(job)
        let quality = Int(((job.options.quality ?? 0.85) * 100).rounded())
        try await ProcessRunner.run(cwebp, ["-quiet", "-q", String(quality), "-alpha_q", "100", "-metadata", "icc,exif",
                                            png.path, "-o", job.file.path])
        job.progress(1)
        return job.file
    }

    public static let avif: Converter = { job in
        let avifenc = try job.tools.require(.avifenc)
        let png = try intermediatePNG(job)
        let quality = Int(((job.options.quality ?? 0.7) * 100).rounded())
        try await ProcessRunner.run(avifenc, ["-q", String(quality), "-s", "6", "-j", "all", png.path, job.file.path])
        job.progress(1)
        return job.file
    }

    /// Bezeztrátový mezikrok (HEIC, RAW, SVG… cwebp/avifenc samy nepřečtou); orientace se aplikuje.
    private static func intermediatePNG(_ job: ConversionJob) throws -> URL {
        let png = job.temporary("vstup.png")
        let image = try ImageBackend.image(at: job.source)
        try ImageBackend.write(image, to: png, format: .png)
        job.progress(0.4)
        return png
    }
}
