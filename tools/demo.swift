// Renders Thermo's launch video (docs/launch.mp4, 1080p) and README GIF (docs/demo.gif)
// from the app's real SwiftUI views, with a scripted cursor and data. No screen recording needed.
// Run:  ./tools/make_demo.sh

import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

Offscreen.rendering = true
let W: CGFloat = 960, H: CGFloat = 540, notchW: CGFloat = 185, notchH: CGFloat = 37
let FPS = 30.0, DURATION = 32.0

let m = Monitor()
let settings = Settings(hasNotch: true)
settings.mode = .notch; settings.notchSide = .both; settings.orientation = .horizontal
let ctl = FloatController()
let iconImage = NSImage(contentsOfFile: "docs/icon.png")

// MARK: - Data

func icon(_ path: String) -> NSImage? { FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil }
func fakeApps(hot: Bool) -> [AppUsage] {[
    AppUsage(id: "a", name: "Safari", project: nil, pids: [1], mainPID: 1, cpu: hot ? 38 : 12, mem: 1.9e9, isApp: true, canQuit: true, icon: icon("/Applications/Safari.app")),
    AppUsage(id: "b", name: "node", project: "my-portfolio", pids: [2], mainPID: 2, cpu: hot ? 164 : 22, mem: 6.1e8, isApp: false, canQuit: true, icon: nil),
    AppUsage(id: "c", name: "Music", project: nil, pids: [3], mainPID: 3, cpu: 4, mem: 3.4e8, isApp: true, canQuit: true, icon: icon("/System/Applications/Music.app")),
    AppUsage(id: "d", name: "Terminal", project: nil, pids: [4], mainPID: 4, cpu: 2, mem: 1.2e8, isApp: true, canQuit: true, icon: icon("/System/Applications/Utilities/Terminal.app")),
    AppUsage(id: "e", name: "cargo", project: "thermo-rs", pids: [5], mainPID: 5, cpu: hot ? 88 : 0, mem: 4.2e8, isApp: false, canQuit: true, icon: nil),
]}

var history: [(t: Date, temp: Double)] = []
var lastTick = -1
/// Live-looking data: values change every 0.5 s; `heat` 0…1 ramps from calm to overheating.
func updateData(_ t: Double, heat: Double) {
    let tick = Int(t * 2)
    guard tick != lastTick else { return }
    lastTick = tick
    let n = sin(Double(tick) * 1.7) * 0.5 + 0.5
    var s = Snapshot()
    s.cpu = 9 + heat * 80 + n * 7
    s.gpu = 7 + heat * 68 + (1 - n) * 6
    s.ramTotal = 16 * 1_073_741_824; s.ramUsed = s.ramTotal * (0.48 + heat * 0.26)
    let temp = 47 + heat * 43 + n * 1.5
    s.cpuTemp = temp; s.gpuTemp = temp - 4; s.ssdTemp = 34 + heat * 4; s.batteryTemp = 29 + heat * 7
    s.thermalState = heat > 0.85 ? .serious : .nominal
    m.snap = s
    m.cpuHist = Array((m.cpuHist + [s.cpu]).suffix(40))
    m.gpuHist = Array((m.gpuHist + [s.gpu ?? 0]).suffix(40))
    m.tempHist = Array((m.tempHist + [temp]).suffix(40))
    m.apps = fakeApps(hot: heat > 0.85)
    history.append((Date().addingTimeInterval(t), temp))
    m.advice = Advisor.advise(s, apps: m.apps, history: history)
    m.blink = tick % 2 == 0
}

// MARK: - Scene state

struct Card { var big: Bool; var opacity: Double }
struct SceneState {
    var notch = false
    var expand = 0.0                // 0 collapsed … 1 fully expanded (notch)
    var floatPos: CGPoint? = nil    // centre of floating widget
    var floatOpacity = 1.0
    var status = 0.0                // menu-bar item opacity
    var popover = 0.0
    var cursor: CGPoint? = nil
    var clickAge: Double? = nil     // seconds since last click
    var caption: String? = nil
    var card: Card? = nil
}

func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, k), y: mix(a.y, b.y, k)) }
func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
/// Cursor path through keyframes (time, point).
func path(_ t: Double, _ keys: [(Double, CGPoint)]) -> CGPoint {
    if t <= keys[0].0 { return keys[0].1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        return mix(keys[i - 1].1, keys[i].1, seg(t, keys[i - 1].0, keys[i].0))
    }
    return keys.last!.1
}

let tabY: CGFloat = notchH + 26
let tabX: [Tab: CGFloat] = [.overview: W / 2 - 170, .apps: W / 2 - 97, .thermal: W / 2 - 40]
let corners = (tl: CGPoint(x: 112, y: 75), br: CGPoint(x: W - 112, y: H - 52), bl: CGPoint(x: 112, y: H - 52))
let statusX: CGFloat = W - 300

func state(at t: Double) -> SceneState {
    var s = SceneState()
    let clicks: [Double] = [7.6, 9.2, 11.9, 13.2, 20.3, 23.0, 25.2]
    if let c = clicks.last(where: { $0 <= t }), t - c < 0.45 { s.clickAge = t - c }

    switch t {
    case ..<2.4:                                    // Title card
        s.card = Card(big: true, opacity: t < 1.9 ? ease(t / 0.6) : 1 - seg(t, 1.9, 2.4))
        s.notch = true; settings.style = .orb; updateData(t, heat: 0)
    case ..<5.0:                                    // Idle orb, cursor approaches
        s.notch = true; settings.style = .orb; m.tab = .overview; updateData(t, heat: 0.05)
        s.cursor = path(t, [(2.4, CGPoint(x: W * 0.78, y: H * 0.8)), (4.6, CGPoint(x: W / 2 - 120, y: 18))])
        s.caption = "Lives quietly beside your notch"
        s.expand = seg(t, 4.6, 5.0)
    case ..<7.9:                                    // Expanded overview → click Apps
        s.notch = true; s.expand = 1; m.tab = t < 7.65 ? .overview : .apps; updateData(t, heat: 0.25)
        s.cursor = path(t, [(5.0, CGPoint(x: W / 2 - 120, y: 18)), (6.4, CGPoint(x: W / 2 + 60, y: 170)), (7.5, CGPoint(x: tabX[.apps]!, y: tabY))])
        s.caption = "Hover to see everything — live"
    case ..<9.5:                                    // Apps → click Heat
        s.notch = true; s.expand = 1; m.tab = t < 9.25 ? .apps : .thermal; updateData(t, heat: 0.45)
        s.cursor = path(t, [(7.9, CGPoint(x: tabX[.apps]!, y: tabY)), (8.6, CGPoint(x: W / 2 + 40, y: 150)), (9.1, CGPoint(x: tabX[.thermal]!, y: tabY))])
        s.caption = "Which apps and projects are busy"
    case ..<12.2:                                   // Heat advisor, then click outside
        s.notch = true; m.tab = .thermal; updateData(t, heat: min(1, 0.6 + (t - 9.5) * 0.3))
        s.expand = 1 - seg(t, 11.95, 12.2)
        s.cursor = path(t, [(9.5, CGPoint(x: tabX[.thermal]!, y: tabY)), (11.0, CGPoint(x: W / 2 + 120, y: 230)), (11.85, CGPoint(x: W * 0.8, y: H * 0.62))])
        s.caption = t < 11.6 ? "Heat advisor: what's slowing down, why, how to cool off" : "Click anywhere to tuck it away"
    case ..<13.4:                                   // Gauges style, grab the notch
        s.notch = true; settings.style = .rings; m.tab = .overview; updateData(t, heat: 0.35)
        s.cursor = path(t, [(12.2, CGPoint(x: W * 0.8, y: H * 0.62)), (13.15, CGPoint(x: W / 2 - 150, y: 18))])
        s.caption = "Single orb, or every gauge"
    case ..<15.6:                                   // Drag out of the notch
        settings.style = .rings; updateData(t, heat: 0.3)
        let cur = path(t, [(13.4, CGPoint(x: W / 2 - 150, y: 18)), (14.0, CGPoint(x: W / 2 - 120, y: 120)), (15.4, CGPoint(x: W * 0.72, y: H * 0.62))])
        s.cursor = cur
        if t < 13.75 { s.notch = true } else { s.floatPos = CGPoint(x: cur.x + 50, y: cur.y + 8) }
        s.caption = "Pull it out of the notch…"
    case ..<18.6:                                   // Drop, snap to corner, hop around corners
        settings.style = .rings; updateData(t, heat: 0.3)
        let drop = CGPoint(x: W * 0.72 + 50, y: H * 0.62 + 8)
        if t < 16.2 { s.floatPos = mix(drop, corners.br, seg(t, 15.6, 16.1)) }
        else if t < 17.4 { s.floatPos = mix(corners.br, corners.tl, seg(t, 16.6, 17.2)) }
        else { s.floatPos = mix(corners.tl, corners.bl, seg(t, 17.8, 18.4)) }
        s.cursor = path(t, [(15.6, CGPoint(x: W * 0.72, y: H * 0.62)), (16.3, CGPoint(x: W * 0.55, y: H * 0.7))])
        s.caption = "…drop it anywhere — it snaps to corners"
    case ..<20.0:                                   // Vertical layout
        settings.style = .rings; settings.orientation = .vertical; updateData(t, heat: 0.3)
        s.floatPos = CGPoint(x: 52, y: H - 130)
        s.cursor = path(t, [(18.6, CGPoint(x: W * 0.55, y: H * 0.7)), (19.9, CGPoint(x: 62, y: H - 150))])
        s.caption = "Horizontal or vertical"
    case ..<21.9:                                   // Click floating widget → expands on screen
        settings.style = .rings; settings.orientation = .vertical; updateData(t, heat: 0.35)
        m.tab = .overview
        s.floatPos = CGPoint(x: 52, y: H - 130)
        if t >= 20.35 { s.floatPos = CGPoint(x: 26 + 470 / 2, y: H - 20 - 232 / 2); m.expanded = true }
        s.floatOpacity = 1 - seg(t, 21.5, 21.9)
        s.cursor = path(t, [(20.0, CGPoint(x: 62, y: H - 150)), (21.5, CGPoint(x: 280, y: 330))])
        s.caption = "Click to expand — always on screen"
    case ..<27.6:                                   // Menu bar mode + popover, heat rises
        updateData(t, heat: t < 24.5 ? 0.35 : min(1, 0.4 + (t - 24.5) * 0.35))
        s.status = seg(t, 21.9, 22.4)
        s.cursor = path(t, [(21.9, CGPoint(x: 280, y: 330)), (22.9, CGPoint(x: statusX + 20, y: 18))])
        s.popover = seg(t, 23.0, 23.3)
        m.tab = t < 25.25 ? .overview : .thermal
        if t > 23.3 { s.cursor = path(t, [(23.3, CGPoint(x: statusX + 20, y: 18)), (24.6, CGPoint(x: statusX + 20, y: 140)), (25.1, CGPoint(x: statusX - 80, y: 66))]) }
        s.caption = t < 25.0 ? "Or keep it in the menu bar" : "Warns you when your Mac runs hot"
        s.notch = false
    default:                                        // End card
        updateData(t, heat: 1); s.status = 1; s.popover = 1 - seg(t, 27.6, 28.0)
        s.card = Card(big: false, opacity: seg(t, 27.6, 28.3))
    }
    if !(20.35..<21.9).contains(t) && s.floatPos != nil { m.expanded = false }
    if s.notch { m.expanded = s.expand > 0 }
    if t < 18.6 { settings.orientation = .horizontal }
    return s
}

// MARK: - Views

struct Cursor: View {
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 20)); p.addLine(to: CGPoint(x: 10, y: 19)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }
        .fill(.black).overlay(Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 20)); p.addLine(to: CGPoint(x: 10, y: 19)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }.stroke(.white, lineWidth: 1.4))
        .frame(width: 14, height: 21).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

struct Stage: View {
    let s: SceneState
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.58), Color(red: 0.58, green: 0.44, blue: 0.62), Color(red: 0.95, green: 0.66, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar
            HStack(spacing: 16) {
                Image(systemName: "applelogo").font(.system(size: 13, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0).font(.system(size: 13)) }
                Spacer()
                Text("CPU \(Int(m.snap.cpu))%  RAM \(Int(m.snap.ramPct))%  GPU \(Int(m.snap.gpu ?? 0))%  " + (m.advice.level >= .hot ? "⚠︎ " : "") + "\(Int(m.snap.hottest ?? 0))°")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(s.popover > 0 ? 0.25 : 0)))
                    .opacity(s.status)
                Image(systemName: "wifi"); Image(systemName: "battery.75")
                Text("Wed 9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).frame(width: W, height: notchH)
            .background(Color.black.opacity(0.18))

            // Physical notch
            NotchShape(radius: 10).fill(.black).frame(width: notchW, height: notchH).offset(x: (W - notchW) / 2)

            // Thermo in the notch (expansion revealed with a growing mask)
            if s.notch {
                NotchRoot(m: m, settings: settings, notchWidth: notchW, notchHeight: notchH)
                    .frame(width: W, height: H)
                    .mask(alignment: .top) {
                        RoundedRectangle(cornerRadius: 22)
                            .frame(width: m.expanded ? 470 : W, height: m.expanded ? mix(notchH, notchH + 240, s.expand) : H)
                    }
            }

            // Floating widget
            if let p = s.floatPos {
                FloatingRoot(m: m, settings: settings, ctl: ctl)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .position(p).opacity(s.floatOpacity)
            }

            // Menu-bar popover
            if s.popover > 0 {
                ExpandedPanel(m: m, settings: settings)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92)))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                    .scaleEffect(mix(0.92, 1, s.popover), anchor: .top)
                    .opacity(s.popover)
                    .position(x: statusX - 40, y: notchH + 8 + 105)
            }

            if let c = s.caption, s.card == nil {
                Text(c).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .position(x: W / 2, y: H - 26)
            }

            if let cur = s.cursor {
                if let age = s.clickAge {
                    Circle().stroke(.white.opacity(1 - age / 0.45), lineWidth: 2)
                        .frame(width: 10 + age * 70, height: 10 + age * 70).position(cur)
                }
                Cursor().scaleEffect(s.clickAge.map { $0 < 0.12 ? 0.85 : 1 } ?? 1, anchor: .topLeading)
                    .position(x: cur.x + 7, y: cur.y + 10)
            }

            if let card = s.card { TitleCard(big: card.big).opacity(card.opacity) }
        }
        .frame(width: W, height: H)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

struct TitleCard: View {
    let big: Bool
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.19), Color(red: 0.05, green: 0.05, blue: 0.06)],
                           center: .center, startRadius: 10, endRadius: 600)
            VStack(spacing: big ? 14 : 12) {
                if let i = iconImage { Image(nsImage: i).resizable().frame(width: big ? 128 : 96, height: big ? 128 : 96) }
                Text("Thermo").font(.system(size: big ? 54 : 40, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text("Your Mac's vitals, living in the notch.")
                    .font(.system(size: big ? 20 : 17, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                if !big {
                    Text("brew install --cask simarpreetsingh-019/thermo/thermo")
                        .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                        .padding(.top, 6)
                    Text("github.com/simarpreetsingh-019/Thermo").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Text("Created by").foregroundStyle(.white.opacity(0.6))
                        Text("Simarpreet Singh").fontWeight(.bold).foregroundStyle(.white)
                        Text("·  @simarpreet_019").foregroundStyle(Color(red: 1, green: 0.55, blue: 0.25))
                    }.font(.system(size: 17)).padding(.top, 14)
                }
            }
        }
        .frame(width: W, height: H)
    }
}

// MARK: - Render & encode

func render(_ t: Double) -> CGImage? {
    let st = state(at: t)
    return MainActor.assumeIsolated {
        let r = ImageRenderer(content: Stage(s: st))
        r.scale = 2
        return r.cgImage
    }
}

let outMP4 = URL(fileURLWithPath: "docs/launch.mp4"), outGIF = URL(fileURLWithPath: "docs/demo.gif")
try? FileManager.default.removeItem(at: outMP4)
let pw = Int(W * 2), ph = Int(H * 2)
let writer = try! AVAssetWriter(outputURL: outMP4, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pw, AVVideoHeightKey: ph,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: pw, kCVPixelBufferHeightKey as String: ph])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)

let gifW = 640, gifH = 360, gifEvery = 3
let frameCount = Int(DURATION * FPS)
let gif = CGImageDestinationCreateWithURL(outGIF as CFURL, UTType.gif.identifier as CFString, frameCount / gifEvery + 1, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

func draw(_ img: CGImage, w: Int, h: Int, into ctx: CGContext) {
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
}

for i in 0..<frameCount {
    let t = Double(i) / FPS
    guard let img = render(t) else { continue }
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    if let pb {
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: pw, height: ph, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        draw(img, w: pw, h: ph, into: ctx)
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    }
    if i % gifEvery == 0 {
        let ctx = CGContext(data: nil, width: gifW, height: gifH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        draw(img, w: gifW, h: gifH, into: ctx)
        CGImageDestinationAddImage(gif, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(gifEvery) / FPS]] as CFDictionary)
    }
    if i % 90 == 0 { print("frame \(i)/\(frameCount)") }
}
CGImageDestinationFinalize(gif)
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("Wrote \(outMP4.path) and \(outGIF.path)")
