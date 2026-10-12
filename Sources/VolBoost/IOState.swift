import os

/// Everything the main thread and the HAL IO thread both touch.
///
/// The IO thread must never block, so it only ever *tries* the lock, once per
/// buffer: on success it picks up the latest settings and hands over the
/// meter readings it has accumulated; on the rare miss it reuses the settings
/// it already has and keeps accumulating. The main thread holds the lock for a
/// few loads and stores at a time.
final class IOState: @unchecked Sendable {  // synchronised by `lock`
    struct Meters: Sendable {
        var inputPeak: Float = 0      // linear, before EQ/boost
        var outputPeak: Float = 0     // linear, after the limiter
        var limiterGain: Float = 1    // < 1 while limiting
        var underruns = 0
        var buffersWithSignal = 0

        mutating func merge(_ other: Meters) {
            inputPeak = max(inputPeak, other.inputPeak)
            outputPeak = max(outputPeak, other.outputPeak)
            limiterGain = min(limiterGain, other.limiterGain)
            underruns &+= other.underruns
            buffersWithSignal &+= other.buffersWithSignal
        }
    }

    struct Settings {
        var ready = false
        var targetGain: Float = 1
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    // Guarded by `lock`.
    private var shared = Settings()
    private var published = Meters()
    private var totals = Meters()
    // IO thread only.
    private var ioSettings = Settings()
    private var ioCarry = Meters()

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Main thread

    func update(_ change: (inout Settings) -> Void) {
        os_unfair_lock_lock(lock)
        change(&shared)
        os_unfair_lock_unlock(lock)
    }

    /// Peaks since the last call (then reset), plus running counters.
    func takeMeters() -> Meters {
        os_unfair_lock_lock(lock)
        defer {
            published = Meters()
            os_unfair_lock_unlock(lock)
        }
        var m = published
        m.underruns = totals.underruns
        m.buffersWithSignal = totals.buffersWithSignal
        return m
    }

    /// Counters only, without resetting the peaks the UI reads.
    func totalCounts() -> (underruns: Int, buffersWithSignal: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (totals.underruns, totals.buffersWithSignal)
    }

    // MARK: IO thread

    /// Call once at the start of each buffer: publishes the previous buffers'
    /// meters and returns the settings to render with.
    @inline(__always)
    func beginBuffer() -> Settings {
        guard os_unfair_lock_trylock(lock) else { return ioSettings }
        ioSettings = shared
        published.merge(ioCarry)
        totals.underruns &+= ioCarry.underruns
        totals.buffersWithSignal &+= ioCarry.buffersWithSignal
        os_unfair_lock_unlock(lock)
        ioCarry = Meters()
        return ioSettings
    }

    /// Call at the end of each buffer with what it measured.
    @inline(__always)
    func record(_ m: Meters) {
        ioCarry.merge(m)
    }
}
