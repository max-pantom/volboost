import AudioToolbox
import CoreAudio
import Foundation
import os
import VolBoostDSP

private let log = Logger(subsystem: "local.volboost", category: "engine")

/// System-wide volume boost.
///
/// VLC (3.0.24, modules/audio_output/auhal) boosts by setting
/// kHALOutputParam_Volume on its own AUHAL unit to `volume^3`, unclamped, so
/// 200% = 8x linear gain. That only works for audio VLC itself renders, so for
/// the whole system we do the equivalent ourselves:
///
///   process tap on the default output device (mutes the originals)
///   -> private aggregate device
///   -> IOProc runs a 5-band EQ (Equalizer.swift), then `percent^3` gain
///      through a lookahead limiter (Limiter.swift)
///   -> default output device
///
/// The engine itself lives on the main actor; only `render` and the IOProc
/// block run on the HAL's realtime thread, and they share state with the main
/// thread solely through `IOState` and the EQ's own try-lock.
@MainActor
final class BoostEngine {
    enum Failure: Error, CustomStringConvertible {
        case status(String, OSStatus)
        case noOwnProcessObject
        var description: String {
            switch self {
            case let .status(what, st): return "\(what) failed (\(st))"
            case .noOwnProcessObject: return "Couldn't exclude VolBoost from its own tap"
            }
        }
    }

    private(set) var isRunning = false
    private(set) var outputName = ""
    /// Extra delay we add on top of the device's own, in ms.
    private(set) var addedLatencyMs = 0.0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var limiterLookahead = 0
    private var equalizer: Equalizer?
    private var eqGains = EQPreset.flat.gains
    private var healthLog: Timer?
    private var lastHealth = (underruns: 0, buffersWithSignal: 0)
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    let io = IOState()

    /// Called on the main queue when the output device or its format changes
    /// and the engine should be restarted.
    var onNeedsRestart: (@MainActor () -> Void)?

    private static let preferredBufferFrames: UInt32 = 256

    init() {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            log.notice("restart: default output changed")
            self?.onNeedsRestart?()
        }
    }

    deinit {
        // The engine is owned by the app model for the process lifetime, so this
        // runs on the main thread at exit if at all; assert rather than hop.
        MainActor.assumeIsolated { stop() }
    }

    /// `percent` is 1.0...2.0 like VLC's slider; gain follows VLC's cubic curve.
    func setBoost(_ percent: Float) {
        let gain = percent * percent * percent
        io.update { $0.targetGain = gain }
    }

    func setEQ(_ gains: [Double]) {
        eqGains = gains
        equalizer?.setGains(gains)
    }

    func start() throws {
        stop()
        do {
            try startUnchecked()
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked() throws {
        outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.string(outputID, kAudioDevicePropertyDeviceUID)
        outputName = (try? Self.string(outputID, kAudioObjectPropertyName)) ?? "Output"

        let desc = Self.tapDescription(outputUID: outputUID, outputID: outputID, exclude: Self.ownProcessObject().map { [$0] } ?? [])
        tapDescription = desc
        try check("Create process tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolBoost",
            kAudioAggregateDeviceUIDKey: "local.volboost.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check("Create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // Smaller IO buffer = less delay between video and boosted sound.
        // Best effort: the device may refuse or clamp it.
        var frames = Self.preferredBufferFrames
        var addr = Self.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let rate = Self.sampleRate(aggregateID) ?? 48_000
        let equalizer = Equalizer(sampleRate: rate, gains: eqGains)
        self.equalizer = equalizer
        var gain: Float = 1
        io.update { gain = $0.targetGain; $0.ready = false }
        // The limiter is owned by the IO block from here on.
        let ioBlock = Self.makeIOBlock(io: io, equalizer: equalizer, sampleRate: rate, gain: gain, lookahead: &limiterLookahead)
        let bufferFrames = Self.uint32(aggregateID, kAudioDevicePropertyBufferFrameSize) ?? 512
        addedLatencyMs = (Double(bufferFrames) * 2 + Double(limiterLookahead)) / rate * 1000
        Self.logFormats(tap: tapID, aggregate: aggregateID, output: outputID, bufferFrames: bufferFrames, addedMs: addedLatencyMs)

        // nil queue = called directly on the HAL's realtime IO thread. Hopping
        // to a dispatch queue adds scheduling jitter, which is audible as crackle.
        try check("Create IOProc", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, ioBlock))
        try check("Start device", AudioDeviceStart(aggregateID, ioProcID))
        isRunning = true

        try excludeSelfIfNeeded()
        io.update { $0.ready = true }
        listenForDeviceChanges()

        // Every 5 s, log underruns and whether audio is flowing (when changed).
        healthLog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.logHealth() }
        }
    }

    private func logHealth() {
        let now = io.totalCounts()
        guard now != lastHealth else { return }
        log.notice("health: underruns \(now.underruns, privacy: .public), buffers with signal \(now.buffersWithSignal, privacy: .public)")
        lastHealth = now
    }

    /// Built outside the main actor on purpose: a closure formed in a
    /// main-actor method would be main-actor isolated, and Swift 6 traps when
    /// the HAL calls it on its IO thread.
    nonisolated private static func makeIOBlock(io: IOState, equalizer: Equalizer, sampleRate: Double, gain: Float,
                                                lookahead: inout Int) -> AudioDeviceIOBlock {
        let limiter = Limiter(sampleRate: sampleRate)
        limiter.reset(gain: gain)
        lookahead = limiter.lookaheadFrames
        return { _, input, _, output, _ in
            let outList = UnsafeMutableAudioBufferListPointer(output)
            let settings = io.beginBuffer()
            guard settings.ready else { return silence(outList) }
            limiter.targetGain = settings.targetGain
            io.record(render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), outList, equalizer, limiter))
        }
    }

    /// Prefer a tap of just what's playing to the output device, in its own
    /// channel layout, so apps routed to other devices are left alone. Fall back
    /// to a stereo mix of everything for devices with more channels than we process.
    private static func tapDescription(outputUID: String, outputID: AudioObjectID, exclude: [AudioObjectID]) -> CATapDescription {
        let channels = outputChannels(outputID)
        // `defaults write local.volboost tapMode global` forces the stereo
        // global tap if a device tap misbehaves on some hardware.
        let forceGlobal = UserDefaults.standard.string(forKey: "tapMode") == "global"
        let desc = !forceGlobal && channels > 0 && channels <= Limiter.maxChannels
            ? CATapDescription(excludingProcesses: exclude, deviceUID: outputUID, stream: 0)
            : CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        log.notice("tap: \(desc.deviceUID == nil ? "global stereo" : "device stream 0", privacy: .public)")
        desc.name = "VolBoost"
        desc.isPrivate = true
        // Originals are silenced only while we're actually reading the tap, so
        // if we die, normal audio comes back.
        desc.muteBehavior = .mutedWhenTapped
        return desc
    }

    /// Our process only gets a HAL process object once it's a HAL client, which
    /// may be after the tap was created. Without the exclusion the tap would
    /// capture our own boosted output and feed back, so output stays silent
    /// until this succeeds.
    private func excludeSelfIfNeeded() throws {
        guard let desc = tapDescription, desc.processes.isEmpty else { return }
        for _ in 0..<50 {
            if let me = Self.ownProcessObject() {
                desc.processes = [me]
                var addr = Self.address(kAudioTapPropertyDescription)
                var ref = Unmanaged.passUnretained(desc).toOpaque()
                try check("Update tap", AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref))
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw Failure.noOwnProcessObject
    }

    /// Restart if the output device goes away or anything changes its format.
    private func listenForDeviceChanges() {
        let watch: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (outputID, kAudioDevicePropertyDeviceIsAlive),
            (outputID, kAudioDevicePropertyNominalSampleRate),
            (outputID, kAudioDevicePropertyStreamConfiguration),
            (aggregateID, kAudioDevicePropertyNominalSampleRate),
        ]
        for (object, selector) in watch {
            var addr = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                log.notice("restart: \(Self.fourCC(selector), privacy: .public) changed on \(object == self?.aggregateID ? "aggregate" : "output", privacy: .public)")
                self?.onNeedsRestart?()
            }
            if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr {
                deviceListeners.append((object, addr, block))
            }
        }
    }

    func stop() {
        io.update { $0.ready = false }
        healthLog?.invalidate()
        healthLog = nil
        for (object, addr, block) in deviceListeners {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        }
        deviceListeners.removeAll()
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
        equalizer = nil
        isRunning = false
    }

    // MARK: - IO

    /// The tap is the last input buffer (any input streams of the output device
    /// itself, e.g. a headset mic, come first). Output may be interleaved or
    /// split across buffers; channels are counted across all of them and
    /// anything past the tap's channels repeats its last channel.
    nonisolated private static func render(_ input: UnsafeMutableAudioBufferListPointer, _ output: UnsafeMutableAudioBufferListPointer,
                                           _ equalizer: Equalizer, _ limiter: Limiter) -> IOState.Meters {
        var meters = IOState.Meters()
        guard let src = input.last, let srcSamples = src.mData?.assumingMemoryBound(to: Float.self), src.mNumberChannels > 0,
              let first = output.first, first.mNumberChannels > 0 else {
            silence(output)
            return meters
        }
        let inChannels = min(Int(src.mNumberChannels), Limiter.maxChannels)
        let srcStride = Int(src.mNumberChannels)
        let inFrames = Int(src.mDataByteSize) / (MemoryLayout<Float>.size * srcStride)
        let outFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        if inFrames < outFrames { meters.underruns = 1 }
        equalizer.beginBuffer()

        var inPeak: Float = 0, outPeak: Float = 0
        withUnsafeTemporaryAllocation(of: Float.self, capacity: Limiter.maxChannels) { scratch in
            let frame = scratch.baseAddress!
            for f in 0..<outFrames {
                if f < inFrames {
                    for c in 0..<inChannels {
                        let s = srcSamples[f * srcStride + c]
                        frame[c] = s
                        inPeak = max(inPeak, abs(s))
                    }
                } else {
                    for c in 0..<inChannels { frame[c] = 0 }
                }
                equalizer.process(frame, channels: inChannels)
                limiter.process(frame, channels: inChannels)
                for c in 0..<inChannels { outPeak = max(outPeak, abs(frame[c])) }

                var channelBase = 0
                for buffer in output {
                    let outChannels = Int(buffer.mNumberChannels)
                    guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self), outChannels > 0 else { continue }
                    if f < Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels) {
                        for c in 0..<outChannels {
                            dst[f * outChannels + c] = frame[min(channelBase + c, inChannels - 1)]
                        }
                    }
                    channelBase += outChannels
                }
            }
        }
        if inPeak > 1e-4 { meters.buffersWithSignal = 1 }
        meters.inputPeak = inPeak
        meters.outputPeak = outPeak
        meters.limiterGain = limiter.currentReduction
        return meters
    }

    nonisolated private static func silence(_ output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }

    // MARK: - HAL helpers

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check("Get default output", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id))
        return id
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check("Get device string", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value))
        guard let value else { throw Failure.status("Get device string", kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func sampleRate(_ device: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let st = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return st == noErr && rate > 0 ? rate : nil
    }

    private static func streamChannels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    /// Channels in the device's first output stream (what a stream-0 tap delivers).
    private static func outputChannels(_ device: AudioObjectID) -> Int {
        streamChannels(device, kAudioObjectPropertyScopeOutput).first ?? 0
    }

    private static func logFormats(tap: AudioObjectID, aggregate: AudioObjectID, output: AudioObjectID, bufferFrames: UInt32, addedMs: Double) {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        let agg = "\(sampleRate(aggregate) ?? 0) Hz in=\(streamChannels(aggregate, kAudioObjectPropertyScopeInput)) out=\(streamChannels(aggregate, kAudioObjectPropertyScopeOutput)) buffer=\(bufferFrames)"
        log.notice("tap \(asbd.mSampleRate, privacy: .public) Hz \(asbd.mChannelsPerFrame, privacy: .public)ch flags=\(asbd.mFormatFlags, privacy: .public); aggregate \(agg, privacy: .public); output \(sampleRate(output) ?? 0, privacy: .public) Hz; added latency \(addedMs, privacy: .public) ms")
    }

    private static func fourCC(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)"
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}

private func check(_ what: String, _ status: OSStatus) throws {
    if status != noErr { throw BoostEngine.Failure.status(what, status) }
}
