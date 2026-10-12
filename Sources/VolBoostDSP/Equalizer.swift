import Foundation
import os

/// Small 5-band EQ (RBJ cookbook biquads, transposed direct form II), run on
/// the HAL IO thread before the limiter so EQ boosts are limited too.
///
/// Coefficients are computed on the main thread into a pending set; the IO
/// thread picks them up with a try-lock at the start of each buffer, so it
/// never blocks.
public final class Equalizer {
    public enum Kind { case lowShelf, peak, highShelf }
    public struct Band {
        public let name: String
        public let kind: Kind
        public let frequency: Double
        public let q: Double
    }

    public static let bands: [Band] = [
        Band(name: "Bass", kind: .lowShelf, frequency: 60, q: 0.707),
        Band(name: "Low-mid", kind: .peak, frequency: 250, q: 1),
        Band(name: "Mid", kind: .peak, frequency: 1000, q: 1),
        Band(name: "Presence", kind: .peak, frequency: 4000, q: 1),
        Band(name: "Treble", kind: .highShelf, frequency: 12000, q: 0.707),
    ]
    public static let range: ClosedRange<Double> = -12...12

    private static let stride = 5  // b0 b1 b2 a1 a2
    private let sampleRate: Double
    private let count = Equalizer.bands.count

    private let coeffs: UnsafeMutablePointer<Double>    // used by the IO thread
    private let pending: UnsafeMutablePointer<Double>   // written by the main thread
    private let state: UnsafeMutablePointer<Double>     // band * maxChannels * 2
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var pendingFlat = true, pendingFresh = false
    private var flat = true

    public init(sampleRate: Double, gains: [Double]) {
        self.sampleRate = sampleRate
        coeffs = .allocate(capacity: count * Self.stride)
        pending = .allocate(capacity: count * Self.stride)
        state = .allocate(capacity: count * Limiter.maxChannels * 2)
        state.initialize(repeating: 0, count: count * Limiter.maxChannels * 2)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        setGains(gains)
        coeffs.update(from: pending, count: count * Self.stride)
        flat = pendingFlat
        pendingFresh = false
    }

    deinit {
        coeffs.deallocate(); pending.deallocate(); state.deallocate()
        lock.deinitialize(count: 1); lock.deallocate()
    }

    /// Main thread. `gains` are dB, one per band.
    public func setGains(_ gains: [Double]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for (i, band) in Self.bands.enumerated() {
            let g = i < gains.count ? gains[i] : 0
            Self.design(band, gain: g, sampleRate: sampleRate, into: pending + i * Self.stride)
        }
        pendingFlat = gains.allSatisfy { $0 == 0 }
        pendingFresh = true
    }

    /// IO thread, once per buffer.
    @inline(__always)
    public func beginBuffer() {
        guard os_unfair_lock_trylock(lock) else { return }
        if pendingFresh {
            coeffs.update(from: pending, count: count * Self.stride)
            if pendingFlat && !flat {
                state.update(repeating: 0, count: count * Limiter.maxChannels * 2)
            }
            flat = pendingFlat
            pendingFresh = false
        }
        os_unfair_lock_unlock(lock)
    }

    /// IO thread. One interleaved frame, in place.
    @inline(__always)
    public func process(_ frame: UnsafeMutablePointer<Float>, channels: Int) {
        if flat { return }
        for b in 0..<count {
            let k = coeffs + b * Self.stride
            let b0 = k[0], b1 = k[1], b2 = k[2], a1 = k[3], a2 = k[4]
            for c in 0..<channels {
                let z = state + (b * Limiter.maxChannels + c) * 2
                let x = Double(frame[c])
                let y = b0 * x + z[0]
                z[0] = b1 * x - a1 * y + z[1]
                z[1] = b2 * x - a2 * y
                frame[c] = Float(y)
            }
        }
    }

    private static func design(_ band: Band, gain: Double, sampleRate: Double, into k: UnsafeMutablePointer<Double>) {
        let A = pow(10, gain / 40)
        let w0 = 2 * Double.pi * min(band.frequency, sampleRate * 0.45) / sampleRate
        let cs = cos(w0), alpha = sin(w0) / (2 * band.q)
        let b0, b1, b2, a0, a1, a2: Double
        switch band.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cs + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cs)
            b2 = A * ((A + 1) - (A - 1) * cs - s)
            a0 = (A + 1) + (A - 1) * cs + s
            a1 = -2 * ((A - 1) + (A + 1) * cs)
            a2 = (A + 1) + (A - 1) * cs - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cs + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cs)
            b2 = A * ((A + 1) + (A - 1) * cs - s)
            a0 = (A + 1) - (A - 1) * cs + s
            a1 = 2 * ((A - 1) - (A + 1) * cs)
            a2 = (A + 1) - (A - 1) * cs - s
        }
        k[0] = b0 / a0; k[1] = b1 / a0; k[2] = b2 / a0; k[3] = a1 / a0; k[4] = a2 / a0
    }
}

public enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bass = "Bass boost"
    case clarity = "Vocal clarity"
    case smallSpeakers = "Small speakers"
    case loudness = "Loudness"

    public var id: String { rawValue }

    public var gains: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .bass: return [6, 2, 0, 0, 0]
        case .clarity: return [-2, -2, 1, 3, 2]
        // Tiny speakers can't reproduce deep bass; cutting it frees headroom
        // for the boost and moves loudness where they can play it.
        case .smallSpeakers: return [-6, 1, 0, 2, 1]
        case .loudness: return [4, 0, -1, 1, 3]
        }
    }
}
