import AVFoundation
import AppKit
import ConvertKit
import Observation

/// Stav střihu: délka, vybraný úsek, přehrávání, miniatury / vlna pro časovou osu.
@MainActor
@Observable
final class TrimState {
    let url: URL
    let isVideo: Bool
    private(set) var duration = 0.0
    var start = 0.0 { didSet { if start != oldValue { onChange?() } } }
    var end = 0.0 { didSet { if end != oldValue { onChange?() } } }
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    /// Po doběhnutí vybraného úseku se přehrává znovu od začátku.
    var loop = true
    private(set) var thumbnails: [NSImage] = []
    private(set) var waveform: [Float] = []
    /// AVFoundation formát otevře (MKV, WebM, AVI ne) – jinak jen střih podle čísel.
    private(set) var canPlay = false
    private(set) var isLoading = true

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
        loadTask = Task { [weak self] in await self?.load() }
    }

    deinit {
        loadTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }

    var length: Double { max(end - start, 0) }

    private func load() async {
        let asset = AVURLAsset(url: url)
        var seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let readable = (try? await asset.load(.isPlayable)) ?? false
        if !seconds.isFinite || seconds <= 0 {
            seconds = (await FFmpegBackend.probeDuration(url, tools: .shared)) ?? 0
        }
        guard !Task.isCancelled else { return }
        duration = seconds
        end = seconds
        canPlay = readable
        if readable { attachPlayer(asset) }

        // Časová osa: miniatury (video) nebo vlna (zvuk).
        if isVideo { thumbnails = await Self.makeThumbnails(asset, duration: seconds, readable: readable, url: url) }
        else { waveform = (try? await Waveform.peaks(of: url, buckets: 600)) ?? [] }
        isLoading = false
    }

    private func attachPlayer(_ asset: AVURLAsset) {
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        playhead = time
        guard isPlaying, end > start, time >= end - 0.03 else { return }
        if loop { seek(to: start) } else { pause(); seek(to: end) }
    }

    // MARK: Ovládání

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard canPlay else { return }
        // Z konce nebo mimo vybraný úsek se začíná od začátku úseku.
        if playhead < start || playhead >= end - 0.05 { seek(to: start) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        playhead = clamped
        guard canPlay else { return }
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStartHere() { start = min(playhead, max(end - 0.1, 0)) }
    func setEndHere() { end = max(playhead, start + 0.1) }

    // MARK: Miniatury

    private static func makeThumbnails(_ asset: AVURLAsset, duration: Double, readable: Bool, url: URL) async -> [NSImage] {
        let count = 14
        guard duration > 0 else { return [] }
        if readable {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: duration / Double(count * 2), preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
            var images: [NSImage] = []
            for index in 0..<count {
                let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
            }
            return images
        }
        // MKV, WebM…: několik snímků přes ffmpeg.
        var images: [NSImage] = []
        for index in 0..<8 {
            if let image = try? await MediaFrames.ffmpegFrame(of: url, fraction: (Double(index) + 0.5) / 8, filter: nil, maxPixel: 240) {
                images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
        }
        return images
    }
}

/// „1:05.3“ nebo „0:07“ → sekundy; také holá čísla („42,5“).
func parseTimecode(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard !cleaned.isEmpty else { return nil }
    let parts = cleaned.split(separator: ":").map(String.init)
    guard (1...3).contains(parts.count) else { return nil }
    var total = 0.0
    for part in parts {
        guard let value = Double(part), value >= 0 else { return nil }
        total = total * 60 + value
    }
    return total
}

func formatTimecode(_ seconds: Double) -> String {
    let total = max(seconds, 0)
    let hours = Int(total) / 3600
    let minutes = Int(total) / 60 % 60
    let secs = total - Double(Int(total) / 60 * 60)
    return hours > 0 ? String(format: "%d:%02d:%04.1f", hours, minutes, secs) : String(format: "%d:%04.1f", minutes, secs)
}
