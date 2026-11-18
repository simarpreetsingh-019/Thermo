// Draws Thermo's app icon (gradient squircle + thermometer) into an .iconset folder.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1), NSColor(red: 0.16, green: 0.10, blue: 0.22, alpha: 1)])!.draw(in: path, angle: -90)
    // glowing ring
    let ring = NSBezierPath(); let c = NSPoint(x: s/2, y: s/2), rr = r.width * 0.34
    ring.appendArc(withCenter: c, radius: rr, startAngle: 90, endAngle: -160, clockwise: true)
    ring.lineWidth = s * 0.055; ring.lineCapStyle = .round
    NSColor(red: 1, green: 0.45, blue: 0.2, alpha: 1).setStroke(); ring.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.32, weight: .bold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: c.x - sz.width/2, y: c.y - sz.height/2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
