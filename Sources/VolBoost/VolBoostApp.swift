import AppKit
import ServiceManagement
import SwiftUI
import VolBoostDSP

@main
struct VolBoostApp: App {
    // Not @State: the App value lives for the whole process, and @State is a
    // macro the Command Line Tools ship no plugin for.
    private let model = BoostModel()

    init() {
        // `VolBoost --snapshot <dir>` renders README screenshots and exits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            BoostView().environment(model)
        } label: {
            Image(systemName: model.enabled ? "speaker.wave.3.fill" : "speaker.wave.1")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class BoostModel {
    @ObservationIgnored private let engine = BoostEngine()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var isPreview = false

    var error: String?
    private(set) var outputName = ""
    private(set) var latencyMs = 0.0
    /// dBFS of the boosted output, and dB the limiter is pulling down (<= 0).
    private(set) var levelDb: Double = -90
    private(set) var limitingDb: Double = 0
    private(set) var launchAtLoginNote: String?

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled"); apply() }
    }
    /// 100...200, same range as VLC's slider.
    var percent: Double {
        didSet { defaults.set(percent, forKey: "percent"); engine.setBoost(Float(percent / 100)) }
    }
    /// dB per Equalizer.bands entry.
    var eqGains: [Double] {
        didSet { defaults.set(eqGains, forKey: "eqGains"); engine.setEQ(eqGains) }
    }
    var launchAtLogin: Bool {
        didSet { if launchAtLogin != oldValue { updateLoginItem() } }
    }

    var preset: EQPreset? { EQPreset.allCases.first { $0.gains == eqGains } }
    /// VLC's cubic curve in dB: 150% = +10.6 dB, 200% = +18.1 dB.
    var boostDb: Double { 60 * log10(percent / 100) }

    init() {
        let savedEQ = defaults.array(forKey: "eqGains") as? [Double]
        eqGains = savedEQ?.count == Equalizer.bands.count ? savedEQ! : EQPreset.flat.gains
        enabled = defaults.bool(forKey: "enabled")
        let saved = defaults.double(forKey: "percent")
        percent = saved >= 100 ? saved : 150
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine.setBoost(Float(percent / 100))
        engine.setEQ(eqGains)
        engine.onNeedsRestart = { [weak self] in self?.scheduleRestart() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [engine] _ in
            MainActor.assumeIsolated { engine.stop() }
        }
        apply()
    }

    /// Static state for screenshots; never touches the engine or settings.
    init(previewPercent: Double, eq: [Double], levelDb: Double, limitingDb: Double) {
        isPreview = true
        enabled = true
        percent = previewPercent
        eqGains = eq
        launchAtLogin = true
        outputName = "Mac mini Speakers"
        latencyMs = 16
        self.levelDb = levelDb
        self.limitingDb = limitingDb
    }

    /// Device changes arrive as bursts of notifications; restart once they settle.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func apply() {
        guard enabled else {
            engine.stop()
            error = nil
            outputName = ""
            return
        }
        do {
            try engine.start()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        outputName = engine.outputName
        latencyMs = engine.addedLatencyMs
    }

    // MARK: Meters (only polled while the panel is open)

    func startMeters() {
        guard !isPreview else { return }
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMeters() }
        }
    }

    func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func readMeters() {
        guard engine.isRunning else { levelDb = -90; limitingDb = 0; return }
        let m = engine.io.takeMeters()
        let level = 20 * log10(max(Double(m.outputPeak), 1e-5))
        let limiting = 20 * log10(max(Double(m.limiterGain), 1e-5))
        // Fast attack, ~10 dB/s fall so the bars are readable.
        levelDb = max(level, levelDb - 0.5)
        limitingDb = min(limiting, limitingDb + 0.5)
    }

    // MARK: Login item

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            launchAtLoginNote = "Allow VolBoost in System Settings › General › Login Items."
        } else if status == .enabled || !launchAtLogin {
            launchAtLoginNote = nil
        }
    }
}

struct BoostView: View {
    @Environment(BoostModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VolBoost").font(.headline)
                    Text(model.enabled ? "\(model.outputName) · +\(Int(model.latencyMs.rounded())) ms" : "Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Boost").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(model.percent))%  ")
                        .monospacedDigit()
                    + Text(String(format: "+%.1f dB", model.boostDb))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                Slider(value: $model.percent, in: 100...200, step: 5)
                MeterRow(label: "Level", value: (model.levelDb + 48) / 48, tint: .green,
                         text: model.levelDb > -60 ? String(format: "%.0f dB", model.levelDb) : "—")
                // Turns red instead of inserting a hint row, so the panel never changes height.
                MeterRow(label: "Limiting", value: -model.limitingDb / 18, tint: model.limitingDb < -9 ? .red : .orange,
                         text: model.limitingDb < -0.5 ? String(format: "%.1f dB", model.limitingDb) : "—")
                    .help("Red means the limiter is working hard — lower the boost or cut Bass for a cleaner sound.")
            }
            .disabled(!model.enabled)

            Divider()
            EQView()
                .disabled(!model.enabled)

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            Toggle("Open at login", isOn: $model.launchAtLogin)
                .font(.caption)
            if let note = model.launchAtLoginNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Quit VolBoost") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.startMeters() }
        .onDisappear { model.stopMeters() }
    }
}

struct MeterRow: View {
    let label: String
    let value: Double   // 0...1
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.gradient)
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 5)
            Text(text)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct EQView: View {
    @Environment(BoostModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Equalizer").font(.subheadline.weight(.medium))
                Spacer()
                Menu(model.preset?.rawValue ?? "Custom") {
                    ForEach(EQPreset.allCases) { preset in
                        Button(preset.rawValue) { model.eqGains = preset.gains }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .font(.caption)
                .fixedSize()
            }
            ForEach(Equalizer.bands.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(Equalizer.bands[i].name)
                        .font(.caption)
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $model.eqGains[i], in: Equalizer.range, step: 0.5)
                        .controlSize(.small)
                    Text(String(format: "%+.1f", model.eqGains[i]))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .help("\(Int(Equalizer.bands[i].frequency)) Hz — double-click to reset")
                .onTapGesture(count: 2) { model.eqGains[i] = 0 }
            }
        }
    }
}
