// Signal-level checks for VolBoostDSP. Exits non-zero on failure.
//   swift run -c release DSPCheck
import Foundation
import VolBoostDSP

let sampleRate = 48_000.0
var failures = 0

@MainActor func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    if !ok { failures += 1 }
}

func sine(_ frequency: Double, _ amplitude: Float) -> (Int) -> Float {
    { amplitude * sin(Float(2 * .pi * frequency * Double($0) / sampleRate)) }
}

/// Runs a mono signal (duplicated to stereo) through `process`, returns the left channel.
func render(frames: Int = 96_000, _ signal: (Int) -> Float, _ process: (UnsafeMutablePointer<Float>) -> Void) -> [Float] {
    var frame = [Float](repeating: 0, count: Limiter.maxChannels)
    return (0..<frames).map { i in
        frame[0] = signal(i); frame[1] = frame[0]
        frame.withUnsafeMutableBufferPointer { process($0.baseAddress!) }
        return frame[0]
    }
}

/// Magnitude at `frequency` over the last second (single-bin DFT).
func magnitude(_ x: [Float], _ frequency: Double) -> Double {
    var re = 0.0, im = 0.0
    for i in (x.count - Int(sampleRate))..<x.count {
        let p = 2 * Double.pi * frequency * Double(i) / sampleRate
        re += Double(x[i]) * cos(p); im += Double(x[i]) * sin(p)
    }
    return (re * re + im * im).squareRoot()
}

func thdPercent(_ x: [Float]) -> Double {
    let h1 = magnitude(x, 1000), h3 = magnitude(x, 3000), h5 = magnitude(x, 5000)
    return 100 * (h3 * h3 + h5 * h5).squareRoot() / h1
}

func limited(gain: Float, _ signal: @escaping (Int) -> Float) -> [Float] {
    let limiter = Limiter(sampleRate: sampleRate)
    limiter.reset(gain: gain)
    return render(signal) { limiter.process($0, channels: 2) }
}

// MARK: Limiter

let ceiling: Float = 0.8913  // -1 dBFS
do {
    let out = limited(gain: 1, sine(1000, 0.8))
    check("limiter unity", abs(out.map(abs).max()! - 0.8) < 1e-3, "peak \(out.map(abs).max()!)")
}
do {
    let out = limited(gain: 8, sine(1000, 0.8))
    let peak = out.map(abs).max()!
    check("limiter 8x ceiling", peak <= ceiling + 1e-4, "peak \(peak)")
    check("limiter 8x distortion", thdPercent(out) < 0.01, String(format: "THD %.4f%%", thdPercent(out)))
}
do {
    let out = limited(gain: 8, sine(1000, 0.05))
    check("limiter quiet passes at full gain", abs(out.map(abs).max()! - 0.4) < 1e-3, "peak \(out.map(abs).max()!)")
}
do {
    // Loud/quiet bursts every 100 ms: the ceiling must hold on every attack.
    let out = limited(gain: 8) { i in (i / 4800) % 2 == 0 ? sine(1000, 0.9)(i) : sine(1000, 0.02)(i) }
    check("limiter transients", out.map(abs).max()! <= ceiling + 1e-4, "peak \(out.map(abs).max()!)")
}
do {
    let out = limited(gain: 8) { _ in .nan }
    check("limiter rejects NaN", out.allSatisfy(\.isFinite), "all finite")
}

// MARK: Equalizer

func responseDb(_ gains: [Double], at frequency: Double) -> Double {
    let eq = Equalizer(sampleRate: sampleRate, gains: gains)
    // Average-magnitude ratio is robust to how few samples a period has at high frequencies.
    let out = render(frames: 72_000, sine(frequency, 0.1)) { eq.process($0, channels: 2) }
    let reference = render(frames: 72_000, sine(frequency, 0.1)) { _ in }
    return 20 * log10(magnitude(out, frequency) / magnitude(reference, frequency))
}

for (i, band) in Equalizer.bands.enumerated() {
    var gains = [Double](repeating: 0, count: Equalizer.bands.count)
    gains[i] = 12
    // Shelves reach full gain well past the corner; peaks at the centre.
    let probe = band.kind == .lowShelf ? band.frequency / 4 : band.kind == .highShelf ? min(band.frequency * 1.6, 20_000) : band.frequency
    let db = responseDb(gains, at: probe)
    check("eq \(band.name) +12 dB", abs(db - 12) < 0.6, String(format: "%.2f dB at %.0f Hz", db, probe))
}
do {
    let db = responseDb(EQPreset.flat.gains, at: 1000)
    check("eq flat is transparent", abs(db) < 0.01, String(format: "%.3f dB", db))
}
do {
    let db = responseDb([0, 0, 12, 0, 0], at: 8000)
    check("eq mid leaves highs alone", abs(db) < 0.5, String(format: "%.2f dB at 8 kHz", db))
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
