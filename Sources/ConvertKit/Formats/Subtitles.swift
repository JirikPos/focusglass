import Foundation

/// Titulky SRT a WebVTT.
public enum Subtitles {
    public struct Cue: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        /// Nastavení pozice z VTT („align:start line:0“) – zachová se při VTT → VTT.
        public var settings: String = ""
    }

    // MARK: Čtení

    public static func parse(_ content: String) -> [Cue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            // Hlavička WEBVTT, číslo nebo identifikátor titulku před časem se zahodí.
            let timing = lines[timingIndex]
            lines = Array(lines[(timingIndex + 1)...])
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]) else { continue }
            let tail = parts[1].trimmingCharacters(in: .whitespaces)
            let endToken = tail.prefix { !$0.isWhitespace }
            guard let end = time(String(endToken)) else { continue }
            let settings = tail.dropFirst(endToken.count).trimmingCharacters(in: .whitespaces)
            cues.append(Cue(start: start, end: end, text: lines.joined(separator: "\n"), settings: settings))
        }
        return cues
    }

    /// „01:02:03,456“, „01:02:03.456“ i „02:03.456“ (VTT bez hodin).
    static func time(_ string: String) -> TimeInterval? {
        let cleaned = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let components = cleaned.components(separatedBy: ":")
        guard (2...3).contains(components.count) else { return nil }
        var total: TimeInterval = 0
        for component in components {
            guard let value = Double(component) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: Zápis

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(strippingVTTTags(cue.text))"
        }.joined(separator: "\n\n") + "\n"
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            let settings = cue.settings.isEmpty ? "" : " " + cue.settings
            return "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\(settings)\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// Jen text (přepis), bez časů a značek.
    public static func plainText(_ cues: [Cue]) -> String {
        cues.map { strippingTags($0.text) }.joined(separator: "\n") + "\n"
    }

    static func stamp(_ time: TimeInterval, separator: String) -> String {
        let millis = Int((max(time, 0) * 1000).rounded())
        let hours = millis / 3_600_000
        let minutes = millis / 60_000 % 60
        let seconds = millis / 1000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, millis % 1000)
    }

    /// SRT zná jen <b>, <i>, <u>, <font> – VTT třídy a hlasy (<c.x>, <v Jan>) pryč.
    static func strippingVTTTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?(c|v|lang|ruby|rt)(\.[^ >]*)?( [^>]*)?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<\d{2}:[\d:.]+>"#, with: "", options: .regularExpression)
    }

    static func strippingTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
    }

    // MARK: Převodník

    public static let convert: Converter = { job in
        let cues = parse(try TextBackend.readText(job.source))
        guard !cues.isEmpty else { throw ConvertError.unreadable(job.source.lastPathComponent) }
        let output: String = switch job.target.id {
        case "srt": srt(cues)
        case "vtt": vtt(cues)
        default: plainText(cues)
        }
        try output.write(to: job.file, atomically: false, encoding: .utf8)
        job.progress(1)
        return job.file
    }
}
