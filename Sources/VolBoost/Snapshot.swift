import AppKit
import SwiftUI
import VolBoostDSP

/// Renders the menu panel to PNGs for the README (`VolBoost --snapshot <dir>`).
@MainActor
enum Snapshot {
    static func render(to directory: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("menu-light", NSAppearance.Name.aqua), ("menu-dark", .darkAqua)] {
            let model = BoostModel(previewPercent: 160, eq: EQPreset.smallSpeakers.gains, levelDb: -3, limitingDb: -5.5)
            let view = BoostView()
                .environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: appearance)
            let size = hosting.fittingSize
            let window = KeyWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                                   styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            hosting.layoutSubtreeIfNeeded()

            let scale: CGFloat = 2
            guard let panel = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            panel.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: panel)
            window.orderOut(nil)
            write(framed(panel, size: hosting.bounds.size, scale: scale), to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// Rounded corners and a soft shadow, like the real menu bar panel.
    private static func framed(_ panel: NSBitmapImageRep, size: CGSize, scale: CGFloat) -> NSBitmapImageRep {
        let margin: CGFloat = 40
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let rect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        NSColor.black.setFill(); shape.fill()
        ctx.restoreGState()
        shape.addClip()
        panel.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path)")
    }
}

/// Borderless windows can't become key by default, which greys out controls.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
