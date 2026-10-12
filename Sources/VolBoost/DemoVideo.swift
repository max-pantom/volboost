import AppKit
import AVFoundation
import SwiftUI
import VolBoostDSP

/// Renders a 10 s square promo clip of the real menu panel: the boost slider
/// sweeps 100% → 200% while the meters respond (`VolBoost --demo-video out.mp4`).
/// The meters are driven by a simulated track, since there's no audio here.
@MainActor
enum DemoVideo {
    static let size = 1080
    static let fps: Int32 = 30
    static let duration = 10.0

    static func render(to url: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = BoostModel(previewPercent: 100, eq: EQPreset.flat.gains, levelDb: -90, limitingDb: 0)
        let hosting = NSHostingView(rootView: BoostView().environment(model).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let panelSize = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()

        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var level = -90.0, limiting = 0.0
        let frames = Int(duration * Double(fps))
        for frame in 0..<frames {
            let t = Double(frame) / Double(fps)
            let percent = 100 + 100 * ease((t - 1.5) / 4.5)
            model.percent = percent

            // Simulated track: beats plus a slow swell, peaking around -15 dBFS.
            let trackDb = -17 + 4 * abs(sin(2 * .pi * 1.9 * t)) + 1.5 * sin(2 * .pi * 0.31 * t) + 0.8 * sin(37 * t)
            let boosted = trackDb + 60 * log10(percent / 100)
            // Same ballistics as the app: instant attack, ~10 dB/s release.
            level = max(min(boosted, -1), level - 10 / Double(fps))
            limiting = min(min(0, -1 - boosted), limiting + 10 / Double(fps))
            model.setPreviewMeters(levelDb: level, limitingDb: limiting)

            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            hosting.layoutSubtreeIfNeeded()
            guard let panel = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: panel)

            while !input.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            if let buffer = makeFrame(panel: panel, panelSize: panelSize, t: t, pool: adaptor.pixelBufferPool) {
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            }
        }

        input.markAsFinished()
        // The completion runs on a background queue, so blocking main here is safe.
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        print(writer.status == .completed ? "Wrote \(url.path)" : "Failed: \(String(describing: writer.error))")
    }

    private static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func makeFrame(panel: NSBitmapImageRep, panelSize: CGSize, t: Double, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
        canvas.fill()

        // Panel, scaled up and centred, with the menu's rounded corners.
        let scale: CGFloat = 2.2
        let w = panelSize.width * scale, h = panelSize.height * scale
        let rect = CGRect(x: (CGFloat(size) - w) / 2, y: 112, width: w, height: h)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12 * scale, yRadius: 12 * scale)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        NSColor.black.setFill(); shape.fill()
        cg.restoreGState()
        cg.saveGState()
        shape.addClip()
        panel.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        cg.restoreGState()

        // Caption: swaps once the slider lands at 200%.
        let fade = min(max((t - 6.2) / 0.4, 0), 1)
        drawCaption("Your whole Mac, past 100%.", y: 966, alpha: 1 - fade)
        drawCaption("200%. Still clean.", y: 966, alpha: fade)
        drawCaption("VolBoost — free & open source", y: 40, alpha: 0.55, size: 30, weight: .medium)
        return pb
    }

    private static func drawCaption(_ text: String, y: CGFloat, alpha: CGFloat, size fontSize: CGFloat = 52, weight: NSFont.Weight = .bold) {
        guard alpha > 0 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let w = str.size().width
        str.draw(at: CGPoint(x: (CGFloat(size) - w) / 2, y: y))
    }
}
