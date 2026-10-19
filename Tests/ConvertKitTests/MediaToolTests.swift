import AVFoundation
import Foundation
import Testing
@testable import ConvertKit

private let hasFFmpeg = ToolLocator.shared.isAvailable(.ffmpeg) && ToolLocator.shared.isAvailable(.ffprobe)

extension Fixtures {
    /// Vygeneruje video přes ffmpeg: testovací obraz + sinus. `silent` bez zvuku.
    static func video(in dir: URL, name: String = "klip.mp4", seconds: Int = 4, size: String = "320x240", silent: Bool = false,
                      extra: [String] = []) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=\(size):rate=15"]
        if !silent { arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] + (silent ? [] : ["-c:a", "aac"]) + extra + [url.path]
        try await ProcessRunner.run(ToolLocator.shared.url(for: .ffmpeg)!, arguments)
        return url
    }

    /// Zvuk: tóny 440 Hz oddělené tichem (pro dělení podle ticha).
    static func tones(in dir: URL, name: String = "tony.wav", beeps: Int = 3) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var parts: [String] = []
        var labels = ""
        for i in 0..<beeps {
            parts.append("sine=frequency=\(440 + i * 110):duration=1.5[t\(i)]")
            parts.append("anullsrc=r=44100:cl=mono,atrim=duration=1.5[s\(i)]")
            labels += "[t\(i)][s\(i)]"
        }
        let graph = parts.joined(separator: ";") + ";" + labels + "concat=n=\(beeps * 2):v=0:a=1[out]"
        try await ProcessRunner.run(ToolLocator.shared.url(for: .ffmpeg)!, [
            "-hide_banner", "-loglevel", "error", "-y", "-filter_complex", graph, "-map", "[out]", "-ar", "44100", url.path,
        ])
        return url
    }
}

@Suite(.serialized) struct MediaToolTests {
    let registry = Catalog.makeRegistry()

    @discardableResult
    private func run(_ id: String, on sources: [URL], options: [String: OptionValue] = [:]) async throws -> [URL] {
        let tool = try #require(registry.operation(id: id) as? Tool, "chybí \(id)")
        let selection = Selection(urls: sources)
        #expect(tool.accepts(selection), "\(id) nepřijme výběr")
        return try await tool.run(OperationContext(selection: selection, options: options))
    }

    private func probe(_ url: URL) async throws -> MediaInfo { try await MediaProbe.info(url) }

    // MARK: Čisté funkce

    @Test func atempoChainStaysInRange() {
        #expect(MediaTools.atempoChain(2) == "atempo=2.0000")
        #expect(MediaTools.atempoChain(4) == "atempo=2.0,atempo=2.0000")
        #expect(MediaTools.atempoChain(0.25) == "atempo=0.5,atempo=0.5000")
        #expect(MediaTools.atempoChain(3).contains("atempo=2.0,atempo=1.5"))
        #expect(MediaTools.atempoChain(8) == "atempo=2.0,atempo=2.0,atempo=2.0000")
    }

    @Test func silenceSegmentsCutInTheMiddleOfSilence() {
        let log = """
        [silencedetect @ 0x1] silence_start: 1.5
        [silencedetect @ 0x1] silence_end: 3.5 | silence_duration: 2
        [silencedetect @ 0x1] silence_start: 5
        [silencedetect @ 0x1] silence_end: 6 | silence_duration: 1
        """
        let parts = AudioSplit.segments(silenceLog: log, duration: 9)
        #expect(parts.count == 3)
        #expect(abs(parts[0].end - 2.5) < 1e-9 && abs(parts[1].start - 2.5) < 1e-9 && abs(parts[1].end - 5.5) < 1e-9)
        #expect(parts.last?.end == 9)
        #expect(AudioSplit.segments(silenceLog: "", duration: 5).count == 1)
        // Ticho na začátku nebo na konci nevytvoří prázdný úsek.
        #expect(AudioSplit.segments(silenceLog: "silence_start: 0\nsilence_end: 0.4 | d", duration: 5).count == 1)
        #expect(AudioSplit.segments(silenceLog: "silence_start: 4.2\nsilence_end: 5 | d", duration: 5).count == 1)
        #expect(AudioSplit.segments(silenceLog: "silence_start: 4.2", duration: 5).count == 1, "ticho do konce souboru bez silence_end")
    }

    @Test func fixedSegments() {
        let parts = AudioSplit.fixed(length: 60, duration: 150)
        #expect(parts.map(\.start) == [0, 60, 120] && parts.last?.end == 150)
        #expect(AudioSplit.fixed(length: 0, duration: 10).isEmpty)
    }

    @Test func loudnormParsing() throws {
        let log = """
        [Parsed_loudnorm_0 @ 0x1] \n{\n\t"input_i" : "-27.61",\n\t"input_tp" : "-4.47",\n\t"input_lra" : "18.06",\n\t"input_thresh" : "-39.20",\n\t"output_i" : "-16.58",\n\t"target_offset" : "0.58"\n}
        """
        let measured = try #require(AudioNormalize.parse(log))
        #expect(measured == AudioNormalize.Measured(integrated: -27.61, truePeak: -4.47, range: 18.06, threshold: -39.20, offset: 0.58))
        #expect(AudioNormalize.parse("žádný JSON") == nil)
        #expect(AudioNormalize.parse("{\"input_i\": \"-inf\", \"input_tp\": \"-inf\", \"input_lra\": \"0\", \"input_thresh\": \"-70\", \"target_offset\": \"0\"}") == nil, "ticho nelze změřit")
        #expect(AudioNormalize.filter(target: -16, peak: -1.5, measured: measured).contains("measured_I=-27.61"))
    }

    @Test func timecodeParsing() {
        #expect(parseTimecodeForTests("1:05.3") == 65.3)
        #expect(parseTimecodeForTests("65,3") == 65.3)
        #expect(parseTimecodeForTests("1:01:01") == 3661)
        #expect(parseTimecodeForTests("abc") == nil)
        #expect(parseTimecodeForTests("1:2:3:4") == nil)
    }

    private func parseTimecodeForTests(_ text: String) -> Double? {
        // Stejná logika jako v UI (parseTimecode); tady kopie kvůli oddělení cílů.
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts { guard let value = Double(part), value >= 0 else { return nil }; total = total * 60 + value }
        return total
    }

    @Test func mergeGraphFillsMissingAudio() {
        var withAudio = MediaInfo(); withAudio.width = 640; withAudio.height = 360; withAudio.hasVideo = true; withAudio.hasAudio = true; withAudio.duration = 3
        var silent = withAudio; silent.hasAudio = false; silent.duration = 2
        let graph = VideoMerge.graph(infos: [withAudio, silent])
        #expect(graph.silenceCount == 1)
        #expect(graph.inputs.contains("anullsrc=r=48000:cl=stereo"))
        #expect(graph.filter.contains("[2:a:0]") && graph.filter.contains("concat=n=2:v=1:a=1"))
        #expect(graph.filter.contains("scale=640:360"))
        #expect(AudioMerge.graph(count: 3, crossfade: 0).contains("concat=n=3:v=0:a=1[out]"))
        let fade = AudioMerge.graph(count: 3, crossfade: 2)
        #expect(fade.contains("[a0][a1]acrossfade=d=2.0") && fade.contains("[c1][a2]acrossfade") && fade.hasSuffix("[out]"))
    }

    @Test func wheelsForMedia() {
        func ids(_ paths: [String]) -> [String] {
            registry.operations(for: Selection(urls: paths.map { URL(fileURLWithPath: $0) }), wheel: .tools).map(\.id)
        }
        #expect(ids(["/a.mp4"]).first == "video.tool.compress")
        #expect(ids(["/a.mp4"]).contains("video.tool.trim"))
        #expect(!ids(["/a.mp4"]).contains("video.tool.merge") && ids(["/a.mp4", "/b.mov"]).contains("video.tool.merge"))
        #expect(ids(["/a.mp3"]).first == "audio.tool.trim")
        #expect(!ids(["/a.mp3"]).contains { $0.hasPrefix("video") })
    }

    @Test func missingFFmpegGreysToolsOut() {
        let none = ToolLocator(searchPaths: [], environment: ["PATH": ""])
        let tool = registry.operation(id: "video.tool.compress")!
        #expect(tool.availability(for: Selection(urls: [URL(fileURLWithPath: "/a.mp4")]), tools: none) != .available)
    }

    // MARK: Průzkum

    @Test(.enabled(if: hasFFmpeg)) func probeReadsStreams() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, size: "320x240")
        let media = try await probe(clip)
        #expect(abs(media.duration - 4) < 0.3 && media.width == 320 && media.height == 240 && media.hasVideo && media.hasAudio)
        #expect(abs(media.fps - 15) < 0.5 && media.videoCodec == "h264")
        let silent = try await probe(try await Fixtures.video(in: dir.url, name: "nem.mp4", silent: true))
        #expect(silent.hasVideo && !silent.hasAudio)
        let audio = try await probe(try Fixtures.wav(in: dir.url))
        #expect(!audio.hasVideo && audio.hasAudio)
    }

    @Test(.enabled(if: hasFFmpeg)) func probeAppliesRotationMetadata() async throws {
        let dir = try TempDir()
        // Video 320×240 s příznakem „otočit o 90°“ se divákovi ukáže jako 240×320.
        let clip = try await Fixtures.video(in: dir.url, extra: ["-metadata:s:v", "rotate=90"])
        let size = try await probe(clip)
        #expect(size.width == 240 && size.height == 320 || size.width == 320 && size.height == 240, "\(size.resolution)")
    }

    // MARK: Video

    @Test(.enabled(if: hasFFmpeg)) func videoCompressTargetsSizeAndResizes() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, seconds: 6, size: "1280x720")
        let result = try await run("video.tool.compress", on: [clip], options: [
            "mode": .string("preset"), "quality": .string("small"), "height": .string("360")])[0]
        let compressed = try await probe(result)
        #expect(compressed.height == 360 && compressed.width == 640 && compressed.hasAudio)
        #expect(result.lastPathComponent == "klip (komprese).mp4")

        let target = try await run("video.tool.compress", on: [clip], options: ["mode": .string("target"), "targetMB": .int(1), "mute": .bool(true)])[0]
        let targeted = try await probe(target)
        #expect(!targeted.hasAudio)
        #expect(targeted.fileSize < 1_300_000, "cíl 1 MB, vyšlo \(targeted.fileSize)")
    }

    @Test(.enabled(if: hasFFmpeg)) func videoTrimPreciseAndFast() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, seconds: 6, extra: ["-g", "15"])
        let precise = try await run("video.tool.trim", on: [clip], options: ["start": .double(1), "end": .double(3.5)])[0]
        let duration = try await probe(precise).duration
        #expect(abs(duration - 2.5) < 0.25, "délka \(duration)")
        let fast = try await run("video.tool.trim", on: [clip], options: ["start": .double(2), "end": .double(0), "precise": .string("false")])[0]
        #expect(fast.pathExtension == "mp4")
        let fastDuration = try await probe(fast).duration
        #expect(abs(fastDuration - 4) < 0.6)
    }

    @Test(.enabled(if: hasFFmpeg)) func videoCropResizeRotate() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, size: "320x240")
        let cropped = try await run("video.tool.crop", on: [clip], options: ["mode": .string("aspect"), "ratio": .string("square")])[0]
        let croppedInfo = try await probe(cropped)
        #expect(croppedInfo.width == croppedInfo.height && croppedInfo.width == 240)

        let rect = try JSONEncoder().encode(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let free = try await run("video.tool.crop", on: [clip], options: ["mode": .string("free"), "rect": .data(rect)])[0]
        let freeInfo = try await probe(free)
        #expect(freeInfo.width == 160 && freeInfo.height == 120)

        let small = try await run("video.tool.resize", on: [clip], options: ["height": .string("120")])[0]
        let smallInfo = try await probe(small)
        #expect(smallInfo.height == 120)
        // Menší video se nezvětšuje.
        let untouched = try await run("video.tool.resize", on: [clip], options: ["height": .string("720")])[0]
        let untouchedInfo = try await probe(untouched)
        #expect(untouchedInfo.height == 240)

        let rotated = try await run("video.tool.rotate", on: [clip], options: ["turn": .string("cw")])[0]
        let rotatedInfo = try await probe(rotated)
        #expect(rotatedInfo.width == 240 && rotatedInfo.height == 320, "\(rotatedInfo.resolution)")
    }

    @Test(.enabled(if: hasFFmpeg)) func videoSpeedChangesDuration() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, seconds: 4)
        let fast = try await run("video.tool.speed", on: [clip], options: ["factor": .string("2")])[0]
        let fastInfo = try await probe(fast)
        #expect(abs(fastInfo.duration - 2) < 0.3 && fastInfo.hasAudio)
        let slow = try await run("video.tool.speed", on: [clip], options: ["factor": .string("0.5"), "mute": .bool(true)])[0]
        let slowInfo = try await probe(slow)
        #expect(abs(slowInfo.duration - 8) < 0.5 && !slowInfo.hasAudio)
    }

    @Test(.enabled(if: hasFFmpeg)) func videoMuteAndAudioExtraction() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url)
        let muted = try await run("video.tool.mute", on: [clip])[0]
        let mutedInfo = try await probe(muted)
        #expect(!mutedInfo.hasAudio && mutedInfo.hasVideo)
        #expect(muted.lastPathComponent == "klip (bez zvuku).mp4")
        for format in ["m4a", "mp3", "wav", "flac", "opus"] {
            let audio = try await run("video.tool.audio", on: [clip], options: ["format": .string(format)])[0]
            let result = try await probe(audio)
            #expect(result.hasAudio && !result.hasVideo && abs(result.duration - 4) < 0.4, "\(format)")
        }
        // Video bez zvuku → srozumitelná chyba.
        let silent = try await Fixtures.video(in: dir.url, name: "nem.mp4", silent: true)
        await #expect(throws: ConvertError.noAudio("nem.mp4")) { try await run("video.tool.audio", on: [silent]) }
    }

    @Test(.enabled(if: hasFFmpeg)) func videoFramesAndGIF() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, seconds: 4)
        let frame = try await run("video.tool.frames", on: [clip], options: ["position": .double(50), "format": .string("jpg")])[0]
        #expect(frame.lastPathComponent == "klip (snímek).jpg")
        #expect(ImageBackend.pixelSize(of: frame) == CGSize(width: 320, height: 240))
        let folder = try await run("video.tool.frames", on: [clip], options: ["mode": .string("every"), "interval": .int(1)])[0]
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.count == 4 && files.first == "klip 0001.png", Comment(rawValue: "\(files)"))

        let gif = try await run("video.tool.gif", on: [clip], options: ["width": .string("160"), "fps": .double(8), "length": .int(2)])[0]
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) >= 14 && CGImageSourceGetCount(source) <= 18)
        #expect(ImageBackend.pixelSize(of: gif)?.width == 160)
    }

    @Test(.enabled(if: hasFFmpeg)) func videoMergeNormalizesAndKeepsAudioGaps() async throws {
        let dir = try TempDir()
        let a = try await Fixtures.video(in: dir.url, name: "a.mp4", seconds: 2, size: "320x240")
        let b = try await Fixtures.video(in: dir.url, name: "b.mp4", seconds: 2, size: "640x360", silent: true)
        let merged = try await run("video.tool.merge", on: [a, b])[0]
        let mergedInfo = try await probe(merged)
        #expect(mergedInfo.width == 320 && mergedInfo.height == 240, "velikost prvního: \(mergedInfo.resolution)")
        #expect(abs(mergedInfo.duration - 4) < 0.5 && mergedInfo.hasAudio)
        let order = try JSONEncoder().encode([b.path, a.path])
        let swapped = try await run("video.tool.merge", on: [a, b], options: ["order": .data(order)])[0]
        let swappedInfo = try await probe(swapped)
        #expect(swappedInfo.width == 640)
    }

    @Test(.enabled(if: hasFFmpeg)) func videoPreviewsShowFrames() async throws {
        let dir = try TempDir()
        let clip = try await Fixtures.video(in: dir.url, size: "640x360")
        for id in ["video.tool.compress", "video.tool.rotate", "video.tool.resize", "video.tool.frames", "video.tool.crop"] {
            let tool = try #require(registry.operation(id: id) as? Tool)
            let preview = try #require(try await tool.preview(PreviewRequest(source: clip, options: [:], maxPixel: 400, selection: Selection(urls: [clip]))), Comment(rawValue: id))
            #expect(preview.image.width > 100 && preview.image.width <= 400, Comment(rawValue: id))
        }
        let rotated = try #require(try await (registry.operation(id: "video.tool.rotate") as? Tool)?.preview(
            PreviewRequest(source: clip, options: ["turn": .string("cw")], maxPixel: 400, selection: Selection(urls: [clip]))))
        #expect(rotated.image.height > rotated.image.width, "náhled otočení je na výšku")
    }

    // MARK: Zvuk

    @Test(.enabled(if: hasFFmpeg)) func audioTrimLosslessAndWithFades() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url, beeps: 3) // 9 s
        let cut = try await run("audio.tool.trim", on: [source], options: ["start": .double(1), "end": .double(4)])[0]
        #expect(cut.pathExtension == "wav")
        let cutInfo = try await probe(cut)
        #expect(abs(cutInfo.duration - 3) < 0.12)
        let faded = try await run("audio.tool.trim", on: [source], options: ["start": .double(0), "end": .double(2), "fadeIn": .double(1), "fadeOut": .double(1)])[0]
        let fadedInfo = try await probe(faded)
        #expect(abs(fadedInfo.duration - 2) < 0.1)
        // Náběh: první vzorky jsou skoro ticho.
        let file = try AVAudioFile(forReading: faded)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 441)!
        try file.read(into: buffer)
        #expect((0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max()! < 0.05)
    }

    @Test(.enabled(if: hasFFmpeg)) func audioCompressChoosesSmallerFormat() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url)
        let result = try await run("audio.tool.compress", on: [source], options: ["bitrate": .string("64"), "mono": .bool(true)])[0]
        #expect(result.pathExtension == "m4a", "WAV se „stejným“ formátem nezmenší")
        #expect(ImageBackend.fileSize(result) < ImageBackend.fileSize(source) / 8)
        let mp3 = try await run("audio.tool.compress", on: [source], options: ["format": .string("mp3"), "bitrate": .string("96")])[0]
        let mp3Info = try await probe(mp3)
        #expect(mp3.pathExtension == "mp3" && abs(mp3Info.duration - 9) < 0.3)
    }

    @Test(.enabled(if: hasFFmpeg)) func audioSplitBySilenceAndLength() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url, beeps: 3)
        let bySilence = try await run("audio.tool.split", on: [source], options: ["mode": .string("silence"), "threshold": .double(-40), "minSilence": .double(1)])[0]
        let files = try FileManager.default.contentsOfDirectory(atPath: bySilence.path).sorted()
        #expect(files.count == 3, "\(files)")
        #expect(files.first == "tony 1.wav")
        for file in files {
            let part = try await probe(bySilence.appendingPathComponent(file))
            #expect(part.duration > 2)
        }

        let fixed = try await run("audio.tool.split", on: [source], options: ["mode": .string("every"), "length": .int(4)])[0]
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixed.path).count == 3) // 4 + 4 + 1 s
        await #expect(throws: ConvertError.self) {
            try await run("audio.tool.split", on: [source], options: ["mode": .string("every"), "length": .int(60)])
        }
    }

    @Test(.enabled(if: hasFFmpeg)) func audioNormalizeReachesTarget() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url, beeps: 2)
        let quiet = try await run("audio.tool.gain", on: [source], options: ["gain": .double(-18)])[0]
        let result = try await run("audio.tool.normalize", on: [quiet], options: ["target": .string("-16")])[0]
        // Změřit výsledek stejným způsobem.
        let log = try await ProcessRunner.run(ToolLocator.shared.url(for: .ffmpeg)!, [
            "-hide_banner", "-nostats", "-loglevel", "info", "-i", result.path, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"])
        let measured = try #require(AudioNormalize.parse(log.stderr))
        #expect(abs(measured.integrated - -16) < 1.5, "naměřeno \(measured.integrated) LUFS")
    }

    @Test(.enabled(if: hasFFmpeg)) func audioGainAndMerge() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url, beeps: 1) // 3 s
        await #expect(throws: ConvertError.self) { try await run("audio.tool.gain", on: [source]) }
        let louder = try await run("audio.tool.gain", on: [source], options: ["gain": .double(6)])[0]
        #expect(louder.lastPathComponent == "tony (úroveň).wav")

        let other = try await Fixtures.tones(in: dir.url, name: "druhy.wav", beeps: 1)
        let merged = try await run("audio.tool.merge", on: [source, other], options: ["format": .string("wav")])[0]
        let mergedAudio = try await probe(merged)
        #expect(abs(mergedAudio.duration - 6) < 0.1)
        let crossfaded = try await run("audio.tool.merge", on: [source, other], options: ["format": .string("wav"), "crossfade": .double(1)])[0]
        let fadedMerge = try await probe(crossfaded)
        #expect(abs(fadedMerge.duration - 5) < 0.15)
    }

    @Test(.enabled(if: hasFFmpeg)) func waveformPeaks() async throws {
        let dir = try TempDir()
        let source = try await Fixtures.tones(in: dir.url, beeps: 2) // tón, ticho, tón, ticho
        let peaks = try await Waveform.peaks(of: source, buckets: 40)
        #expect(peaks.count == 40)
        #expect(peaks[2] > 0.1 && peaks[10] < 0.01, "tón vs ticho")
        let ffmpegOnly = try await Waveform.peaks(of: try await Fixtures.video(in: dir.url, name: "w.mkv", extra: []), buckets: 20)
        #expect(ffmpegOnly.count == 20 && (ffmpegOnly.max() ?? 0) > 0.1)
        let image = try Waveform.image(peaks: peaks, width: 400, height: 100)
        #expect(image.width == 400)
    }
}
