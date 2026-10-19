import AVFoundation
import CoreGraphics
import Foundation

/// Údaje o video / audio souboru z ffprobe.
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double = 0
    /// Rozměry po aplikaci otočení z metadat (jak je uvidí divák).
    public var width = 0
    public var height = 0
    public var fps = 0.0
    public var hasVideo = false
    public var hasAudio = false
    public var videoCodec: String?
    public var audioCodec: String?
    /// Celková přenosová rychlost v bitech za sekundu.
    public var bitrate = 0
    public var audioBitrate = 0
    public var fileSize = 0

    public var resolution: String { hasVideo ? "\(width)×\(height)" : "" }
}

public enum MediaProbe {
    public static func info(_ url: URL, tools: ToolLocator = .shared) async throws -> MediaInfo {
        let ffprobe = try tools.require(.ffprobe)
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        return parse(json, fileSize: ImageBackend.fileSize(url))
    }

    static func parse(_ json: [String: Any], fileSize: Int) -> MediaInfo {
        var info = MediaInfo()
        info.fileSize = fileSize
        let format = json["format"] as? [String: Any]
        info.duration = Double(format?["duration"] as? String ?? "") ?? 0
        info.bitrate = Int(format?["bit_rate"] as? String ?? "") ?? 0

        for stream in json["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "video":
                // Obálky alba (mjpeg/png s jedním snímkem) nejsou video.
                let disposition = stream["disposition"] as? [String: Any]
                guard (disposition?["attached_pic"] as? Int ?? 0) == 0, !info.hasVideo else { continue }
                info.hasVideo = true
                info.videoCodec = stream["codec_name"] as? String
                var width = stream["width"] as? Int ?? 0
                var height = stream["height"] as? Int ?? 0
                if abs(rotation(of: stream)) % 180 == 90 { swap(&width, &height) }
                info.width = width
                info.height = height
                info.fps = frameRate(stream["avg_frame_rate"] as? String) ?? frameRate(stream["r_frame_rate"] as? String) ?? 0
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            case "audio":
                guard !info.hasAudio else { continue }
                info.hasAudio = true
                info.audioCodec = stream["codec_name"] as? String
                info.audioBitrate = Int(stream["bit_rate"] as? String ?? "") ?? 0
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            default:
                break
            }
        }
        return info
    }

    /// Otočení z metadat (iPhone natáčí na šířku a ukládá „otočit o 90°“).
    static func rotation(of stream: [String: Any]) -> Int {
        for entry in stream["side_data_list"] as? [[String: Any]] ?? [] {
            if let value = entry["rotation"] as? Double { return Int(value.rounded()) }
            if let value = entry["rotation"] as? Int { return value }
        }
        if let tags = stream["tags"] as? [String: Any], let text = tags["rotate"] as? String, let value = Int(text) { return value }
        return 0
    }

    static func frameRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.count == 1 ? parts[0] : nil
    }
}

/// Které kodéry má nainstalovaný ffmpeg (liší se podle buildu).
public enum FFmpegCapabilities {
    private actor Store {
        var cache: [String: Set<String>] = [:]
        func get(_ key: String) -> Set<String>? { cache[key] }
        func set(_ key: String, _ value: Set<String>) { cache[key] = value }
    }
    private static let store = Store()

    public static func encoders(tools: ToolLocator = .shared) async -> Set<String> {
        guard let ffmpeg = tools.url(for: .ffmpeg) else { return [] }
        if let cached = await store.get(ffmpeg.path) { return cached }
        let output = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"])
        var names = Set<String>()
        for line in String(decoding: output?.stdout ?? Data(), as: UTF8.self).split(separator: "\n") {
            // „ V....D libx264 …“: první sloupec jsou příznaky, druhý jméno kodéru.
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { names.insert(String(parts[1])) }
        }
        await store.set(ffmpeg.path, names)
        return names
    }

    public static func has(_ encoder: String, tools: ToolLocator = .shared) async -> Bool {
        await encoders(tools: tools).contains(encoder)
    }
}

/// Snímky z videa pro náhledy a editory.
public enum MediaFrames {
    /// Snímek v `fraction` délky (0…1). AVFoundation, jinak ffmpeg (MKV, WebM, AVI…).
    public static func frame(of url: URL, fraction: Double = 0.1, maxPixel: Int, tools: ToolLocator = .shared) async throws -> CGImage {
        if AVBackend.readableVideo.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.seconds > 0 {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                let time = CMTime(seconds: duration.seconds * min(max(fraction, 0), 1), preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image { return image }
            }
        }
        return try await ffmpegFrame(of: url, fraction: fraction, filter: nil, maxPixel: maxPixel, tools: tools)
    }

    /// Snímek přes ffmpeg s volitelným filtrem (náhled otočení, ořezu…).
    public static func ffmpegFrame(of url: URL, fraction: Double, filter: String?, maxPixel: Int,
                                   tools: ToolLocator = .shared) async throws -> CGImage {
        let ffmpeg = try tools.require(.ffmpeg)
        let duration = await FFmpegBackend.probeDuration(url, tools: tools) ?? 0
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fg-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        var chain = filter.map { [$0] } ?? []
        chain.append("scale='min(\(maxPixel),iw)':-2:force_original_aspect_ratio=decrease")
        try await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", String(format: "%.3f", duration * min(max(fraction, 0), 1)),
            "-i", url.path, "-frames:v", "1", "-vf", chain.joined(separator: ","), output.path,
        ])
        return try ImageBackend.load(output)
    }
}
