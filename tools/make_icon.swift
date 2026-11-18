// Draws Thermo's app icon into an .iconset folder.
// Minimal concept: a MacBook (with its notch) whose screen shows a single temperature gauge.
// Two colours only: off-white line art plus one warm accent, on a dark graphite squircle.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let ink = rgb(0.96, 0.95, 0.93)
let accent = rgb(1.0, 0.45, 0.18)

func draw(_ s: CGFloat) {
    // Background squircle.
    let inset = s * 0.09
    let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [rgb(0.17, 0.17, 0.19), rgb(0.09, 0.09, 0.10)])!.draw(in: bg, angle: -90)

    let lw = max(s * 0.032, 1.2)

    // Laptop lid (screen).
    let lidW = r.width * 0.68, lidH = lidW * 0.66
    let lid = NSRect(x: s / 2 - lidW / 2, y: s * 0.35, width: lidW, height: lidH)
    let lidPath = NSBezierPath(roundedRect: lid, xRadius: lidW * 0.06, yRadius: lidW * 0.06)
    lidPath.lineWidth = lw
    ink.setStroke(); lidPath.stroke()

    // The notch.
    let nW = lidW * 0.26, nH = lidH * 0.12
    let notch = NSBezierPath(roundedRect: NSRect(x: s / 2 - nW / 2, y: lid.maxY - nH, width: nW, height: nH + lw / 2),
                             xRadius: nH * 0.5, yRadius: nH * 0.5)
    ink.setFill(); notch.fill()

    // Base / keyboard deck.
    let baseW = lidW * 1.18, baseH = lw * 1.6
    let base = NSBezierPath(roundedRect: NSRect(x: s / 2 - baseW / 2, y: lid.minY - baseH - lw * 0.4, width: baseW, height: baseH),
                            xRadius: baseH / 2, yRadius: baseH / 2)
    ink.setFill(); base.fill()

    // Gauge on the screen: a 180° arc, warm accent filling ~70%, with a needle.
    let c = NSPoint(x: s / 2, y: lid.minY + lidH * 0.30)
    let gr = lidH * 0.40
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: gr, startAngle: 180, endAngle: 0, clockwise: true)
    track.lineWidth = lw * 1.1; track.lineCapStyle = .round
    ink.withAlphaComponent(0.25).setStroke(); track.stroke()

    let fillTo: CGFloat = 180 - 180 * 0.7
    let level = NSBezierPath()
    level.appendArc(withCenter: c, radius: gr, startAngle: 180, endAngle: fillTo, clockwise: true)
    level.lineWidth = lw * 1.1; level.lineCapStyle = .round
    accent.setStroke(); level.stroke()

    let a = fillTo * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: c)
    needle.line(to: NSPoint(x: c.x + gr * 0.72 * cos(a), y: c.y + gr * 0.72 * sin(a)))
    needle.lineWidth = lw; needle.lineCapStyle = .round
    ink.setStroke(); needle.stroke()
    let hub = lw * 1.3
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)).fill()
}

let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                              (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (px, name) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
