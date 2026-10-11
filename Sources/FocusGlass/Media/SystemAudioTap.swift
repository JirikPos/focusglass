import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "app.focusglass", category: "audio")

/// Poslouchá zvuk přehrávaný v Macu (Core Audio process tap, macOS 14.2+) a posílá ho do analyzátoru.
///
/// Zvuk se nikam neukládá ani neodesílá – jen se z něj počítá spektrum pro vizualizér.
/// macOS se jednou zeptá na svolení k nahrávání zvuku a během běhu ukazuje indikátor v liště.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private let analyzer: SpectrumAnalyzer
    private let queue = DispatchQueue(label: "app.focusglass.audiotap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        do {
            try setUp()
            isRunning = true
        } catch {
            log.error("audio tap failed: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        analyzer.reset()
    }

    // MARK: - Nastavení

    private struct TapError: Error {
        let step: String
        let status: OSStatus
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }

    private func setUp() throws {
        // Tap na veškerý zvuk systému (hudba z jakékoli aplikace i prohlížeče), jen pro čtení.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "FocusGlass"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FocusGlass Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")

        let format = try tapFormat()
        let channels = Int(max(1, format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let analyzer = analyzer
        var mono = [Float]()

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)

            if interleaved && channels > 1 {
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
                mono.withUnsafeBufferPointer { analyzer.append($0) }
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                analyzer.append(UnsafeBufferPointer(start: samples, count: frames))
            }
        }, "create IO proc")

        try check(AudioDeviceStart(aggregateID, procID), "start")
        log.debug("audio tap running, channels=\(channels) interleaved=\(interleaved)")
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "tap format")
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
                  "default output")

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "output UID")
        guard let uid else { throw TapError(step: "output UID", status: -1) }
        return uid.takeRetainedValue() as String
    }
}
