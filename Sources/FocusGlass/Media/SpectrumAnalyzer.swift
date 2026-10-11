import Accelerate
import os

/// FFT analýza zvuku → úrovně frekvenčních pásem (0…1) pro vizualizér.
///
/// Vzorky přicházejí na frontě audio tapu, `levels()` čte UI. Sdílený stav chrání zámek.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 22

    private let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private let window: [Float]

    private var samples: [Float]
    private var filled = 0
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    /// Hranice pásem (indexy FFT binů), logaritmicky od ~40 Hz po ~16 kHz.
    private let edges: [Int]

    private let state = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: bandCount))
    /// Síla aktuálního úderu (0…1), rychle doznívá.
    private let pulse = OSAllocatedUnfairLock(initialState: Float(0))
    /// Klouzavý průměr energie basů – úder = prudký skok nad něj.
    private var bassAverage: Float = 0

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: fftSize, isHalfWindow: false)
        samples = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        edges = (0...Self.bandCount).map { band in
            Int(2 * pow(190, Double(band) / Double(Self.bandCount)))
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Aktuální úrovně pásem (0 = basy … konec = výšky).
    func levels() -> [Float] { state.withLock { $0 } }

    /// Síla posledního úderu (kopák / basový beat), 0…1.
    func beat() -> Float { pulse.withLock { $0 } }

    func reset() {
        state.withLock { $0 = [Float](repeating: 0, count: Self.bandCount) }
        pulse.withLock { $0 = 0 }
        bassAverage = 0
        filled = 0
    }

    /// Přidá vzorky (mono). Každých 512 vzorků (překryv 50 %) spočítá nové spektrum.
    func append(_ mono: UnsafeBufferPointer<Float>) {
        for sample in mono {
            samples[filled] = sample
            filled += 1
            if filled == fftSize {
                analyze()
                // Posun o polovinu okna (překryv) – plynulejší reakce.
                samples.withUnsafeMutableBufferPointer { buffer in
                    let half = fftSize / 2
                    buffer.baseAddress!.update(from: buffer.baseAddress! + half, count: half)
                }
                filled = fftSize / 2
            }
        }
    }

    private func analyze() {
        vDSP.multiply(samples, window, result: &windowed)
        let half = fftSize / 2

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var next = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let low = edges[band]
            let high = max(low + 1, edges[band + 1])
            var sum: Float = 0
            for bin in low..<min(high, half) { sum += magnitudes[bin] }
            let average = sum / Float(high - low)
            // Amplituda → dB; výšky mají v hudbě přirozeně méně energie, proto mírné zvýraznění.
            let decibels = 20 * log10(average * 2 / Float(fftSize) + 1e-9)
                + 12 * Float(band) / Float(Self.bandCount)
            // Mapování s mírně zvýrazněným kontrastem (−56…−12 dB).
            let linear = min(1, max(0, (decibels + 56) / 44))
            next[band] = pow(linear, 1.3)
        }

        // Detekce úderu: energie basů (~40–200 Hz) prudce nad svým průměrem.
        let bass = (0..<4).reduce(Float(0)) { $0 + next[$1] } / 4
        let isBeat = bass > 0.3 && bass > bassAverage * 1.4
        bassAverage = bassAverage * 0.9 + bass * 0.1
        let beat = pulse.withLock { value -> Float in
            value = isBeat ? 1 : value * 0.72
            return value
        }

        let computed = next
        state.withLock { levels in
            for band in 0..<Self.bandCount {
                // Na úder se celé spektrum vytáhne (basy nejvíc), mezi údery rychle spadne.
                let boost = 1 + beat * (0.25 - 0.15 * Float(band) / Float(Self.bandCount))
                let target = min(1, computed[band] * boost)
                levels[band] = max(target, levels[band] * 0.76)
            }
        }
    }
}
