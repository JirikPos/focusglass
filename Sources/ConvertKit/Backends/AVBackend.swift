import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Video a zvuk přes AVFoundation (hardwarové kodéry, žádné závislosti).
public enum AVBackend {
    /// Video, které AVFoundation přečte.
    public static let readableVideo: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    /// Zvuk, který AVAudioFile přečte.
    public static let readableAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]

    // MARK: Video

    /// Video → MP4 / MOV (H.264/HEVC podle zdroje) nebo jen zvuk → M4A.
    public static let export: Converter = { job in
        let asset = AVURLAsset(url: job.source)
        let (preset, fileType): (String, AVFileType) = switch job.target.id {
        case "m4a": (AVAssetExportPresetAppleM4A, .m4a)
        case "mov": (AVAssetExportPresetHighestQuality, .mov)
        default: (AVAssetExportPresetHighestQuality, .mp4)
        }
        try await run(asset: asset, preset: preset, fileType: fileType, to: job.file, progress: job.progress)
        return job.file
    }

    /// Spustí export s průběhem a zrušením.
    static func run(asset: AVAsset, preset: String, fileType: AVFileType, to output: URL,
                    timeRange: CMTimeRange? = nil, videoComposition: AVVideoComposition? = nil,
                    audioMix: AVAudioMix? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unsupportedInput(output.lastPathComponent)
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let audioMix { session.audioMix = audioMix }

        let box = SessionBox(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler {
            await box.session.export()
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default:
            throw ConvertError.toolFailed(
                tool: "AVFoundation", status: Int32((session.error as NSError?)?.code ?? -1),
                detail: session.error?.localizedDescription ?? "export selhal"
            )
        }
    }

    /// Video → animovaný GIF (max. 640 px, 12 snímků/s).
    public static let gif: Converter = { job in
        try await writeGIF(from: job.source, to: job.file, maxWidth: 640, fps: 12, progress: job.progress)
        return job.file
    }

    static func writeGIF(from input: URL, to output: URL, maxWidth: CGFloat, fps: Double,
                         range: CMTimeRange? = nil, progress: @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: duration)
        let seconds = max(span.duration.seconds, 0.1)
        let frames = max(1, min(Int(seconds * fps), 1800))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, frames, nil
        ) else { throw ConvertError.writeFailed(output.lastPathComponent) }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]]

        for index in 0..<frames {
            try Task.checkCancellation()
            let time = span.start + CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            progress(Double(index + 1) / Double(frames))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.writeFailed(output.lastPathComponent) }
    }

    // MARK: Zvuk

    /// Zvuk → M4A (AAC 256 kb/s), WAV / AIFF (16 bit), FLAC (bezztrátově).
    public static let audio: Converter = { job in
        try transcodeAudio(job.source, to: job.file, format: job.target, progress: job.progress)
        return job.file
    }

    static func transcodeAudio(_ input: URL, to output: URL, format: Format, bitrate: Int = 256_000,
                               progress: (Double) -> Void) throws {
        let source: AVAudioFile
        do { source = try AVAudioFile(forReading: input) } catch {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let processing = source.processingFormat
        var settings: [String: Any] = [
            AVSampleRateKey: processing.sampleRate,
            AVNumberOfChannelsKey: processing.channelCount,
        ]
        switch format.id {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = min(bitrate, 320_000)
            // AAC neumí libovolné vzorkování – 44,1/48 kHz.
            settings[AVSampleRateKey] = processing.sampleRate > 48_000 ? 48_000 : max(processing.sampleRate, 8_000)
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
        case "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsFloatKey] = false
        default: // wav
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsFloatKey] = false
        }
        let destination: AVAudioFile
        do {
            destination = try AVAudioFile(forWriting: output, settings: settings,
                                          commonFormat: processing.commonFormat, interleaved: processing.isInterleaved)
        } catch {
            throw ConvertError.toolFailed(tool: "AVFoundation", status: Int32((error as NSError).code),
                                          detail: error.localizedDescription)
        }
        let capacity: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: capacity) else {
            throw ConvertError.unreadable(input.lastPathComponent)
        }
        let total = max(Double(source.length), 1)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: capacity)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
            progress(Double(source.framePosition) / total)
        }
    }
}

/// AVAssetExportSession není Sendable; přistupuje se k němu jen z exportu a ze zrušení.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
