import Foundation

/// Gain + stereo-linked lookahead peak limiter, safe to call on the HAL IO thread
/// (no allocation, no locks).
///
/// Boosting already-mastered audio by up to 8x pushes most peaks past full
/// scale. Clipping or waveshaping those peaks is what makes boost sound
/// crunchy and muffled, so instead the gain is turned down *just before* each
/// peak arrives and recovers slowly afterwards:
///
///   required gain per frame -> sliding min over the lookahead window
///   -> slow release -> moving average over the same window
///
/// Averaging a min-hold over the lookahead length guarantees the gain has
/// reached the required value by the time the (delayed) peak is output, so
/// the ceiling is never exceeded and no clipping happens at all.
public final class Limiter {
    public static let maxChannels = 8

    private let length: Int            // lookahead in frames
    private let ceiling: Float
    private let releaseCoef: Float
    private let gainCoef: Float

    private let delay: UnsafeMutablePointer<Float>   // length * maxChannels, pre-gained samples
    private let box: UnsafeMutablePointer<Float>     // length, smoothed envelope history
    private let minValues: UnsafeMutablePointer<Float>
    private let minIndices: UnsafeMutablePointer<Int>
    private var minHead = 0, minCount = 0
    private var position = 0           // frames processed
    private var boxSum: Double
    private var envelope: Float = 1
    private var currentGain: Float

    public var lookaheadFrames: Int { length }
    /// Gain the limiter applied to the last frame (1 = not limiting).
    public private(set) var currentReduction: Float = 1

    /// Written from the main thread, read here; a one-buffer-stale value is fine.
    public var targetGain: Float = 1

    public init(sampleRate: Double, lookaheadMs: Double = 5, releaseMs: Double = 200, ceilingDb: Float = -1) {
        length = max(2, Int(sampleRate * lookaheadMs / 1000))
        ceiling = powf(10, ceilingDb / 20)
        releaseCoef = Float(1 - exp(-1 / (sampleRate * releaseMs / 1000)))
        gainCoef = Float(1 - exp(-1 / (sampleRate * 0.03)))  // 30 ms slider smoothing
        delay = .allocate(capacity: length * Self.maxChannels)
        delay.initialize(repeating: 0, count: length * Self.maxChannels)
        box = .allocate(capacity: length)
        box.initialize(repeating: 1, count: length)
        minValues = .allocate(capacity: length)
        minIndices = .allocate(capacity: length)
        boxSum = Double(length)
        currentGain = 1
    }

    deinit {
        delay.deallocate(); box.deallocate()
        minValues.deallocate(); minIndices.deallocate()
    }

    public func reset(gain: Float) {
        delay.update(repeating: 0, count: length * Self.maxChannels)
        box.update(repeating: 1, count: length)
        boxSum = Double(length)
        minHead = 0; minCount = 0; position = 0
        envelope = 1
        currentReduction = 1
        currentGain = gain
        targetGain = gain
    }

    /// Processes one interleaved frame of `channels` samples in place.
    @inline(__always)
    public func process(_ frame: UnsafeMutablePointer<Float>, channels: Int) {
        currentGain += (targetGain - currentGain) * gainCoef
        let slot = position % length
        let line = delay + slot * Self.maxChannels

        // Swap the incoming (gained) frame into the delay line, reading back the
        // frame that went in length-1 frames ago... which is the next slot.
        var peak: Float = 0
        for c in 0..<channels {
            var s = frame[c] * currentGain
            if !s.isFinite { s = 0 }
            line[c] = s
            peak = max(peak, abs(s))
        }
        let required: Float = peak > ceiling ? ceiling / peak : 1

        // Sliding minimum of `required` over the last `length` frames (monotonic deque).
        while minCount > 0, minValues[(minHead + minCount - 1) % length] >= required { minCount -= 1 }
        let tail = (minHead + minCount) % length
        minValues[tail] = required; minIndices[tail] = position; minCount += 1
        if minIndices[minHead] <= position - length { minHead = (minHead + 1) % length; minCount -= 1 }
        let held = minValues[minHead]

        envelope = held < envelope ? held : envelope + (held - envelope) * releaseCoef

        boxSum += Double(envelope - box[slot])
        box[slot] = envelope
        let gain = Float(boxSum / Double(length))
        currentReduction = gain

        let out = delay + ((position + 1) % length) * Self.maxChannels
        for c in 0..<channels { frame[c] = out[c] * gain }
        position &+= 1
    }
}
