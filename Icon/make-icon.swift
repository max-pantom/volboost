// Renders AppIcon.icns. Run via Icon/make-icon.sh.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.09, green: 0.10, blue: 0.24, alpha: 1),
                    NSColor(red: 0.36, green: 0.16, blue: 0.62, alpha: 1),
                    NSColor(red: 0.98, green: 0.36, blue: 0.42, alpha: 1)],
           atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: 55)
// soft top highlight
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: -90)

// Level meter bars across the bottom, rising like the boost slider.
let bars = 9
for i in 0..<bars {
    let t = CGFloat(i) / CGFloat(bars - 1)
    let h = 40 + t * t * 150
    let w: CGFloat = 52, gap: CGFloat = 22
    let x = 512 - (CGFloat(bars) * w + CGFloat(bars - 1) * gap) / 2 + CGFloat(i) * (w + gap)
    let hot = t > 0.6
    (hot ? NSColor(red: 1, green: 0.85, blue: 0.35, alpha: 0.95) : NSColor.white.withAlphaComponent(0.55)).setFill()
    NSBezierPath(roundedRect: CGRect(x: x, y: 170, width: w, height: h), xRadius: 14, yRadius: 14).fill()
}

// Speaker glyph.
let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let glyph = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let gs = glyph.size
    let r = CGRect(x: 512 - gs.width / 2 - 20, y: 610 - gs.height / 2, width: gs.width, height: gs.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    glyph.draw(in: r)
    ctx.restoreGState()
}
ctx.restoreGState()

// thin inner stroke for definition on light backgrounds
NSColor.white.withAlphaComponent(0.12).setStroke()
shape.lineWidth = 3
shape.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
