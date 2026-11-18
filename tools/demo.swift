// Renders docs/demo.gif from Thermo's real SwiftUI views (no screen recording needed).
// Build & run:  ./tools/make_demo.sh
// Data is scripted so the GIF shows every state: idle → busy → expanded tabs → overheating.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let W: CGFloat = 720, H: CGFloat = 340, notchW: CGFloat = 185, notchH: CGFloat = 37

Offscreen.rendering = true
let m = Monitor()
let settings = Settings(hasNotch: true)
settings.mode = .notch
settings.notchSide = .both

func icon(_ path: String) -> NSImage? { FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil }

func fakeApps(hot: Bool) -> [AppUsage] {
    [
        AppUsage(id: "a", name: "Safari", project: nil, pids: [1], mainPID: 1, cpu: hot ? 38 : 12, mem: 1.9e9, isApp: true, canQuit: true, icon: icon("/Applications/Safari.app")),
        AppUsage(id: "b", name: "node", project: "my-portfolio", pids: [2], mainPID: 2, cpu: hot ? 164 : 22, mem: 6.1e8, isApp: false, canQuit: true, icon: nil),
        AppUsage(id: "c", name: "Music", project: nil, pids: [3], mainPID: 3, cpu: 4, mem: 3.4e8, isApp: true, canQuit: true, icon: icon("/System/Applications/Music.app")),
        AppUsage(id: "d", name: "Terminal", project: nil, pids: [4], mainPID: 4, cpu: 2, mem: 1.2e8, isApp: true, canQuit: true, icon: icon("/System/Applications/Utilities/Terminal.app")),
        AppUsage(id: "e", name: "cargo", project: "thermo-rs", pids: [5], mainPID: 5, cpu: hot ? 88 : 0, mem: 4.2e8, isApp: false, canQuit: true, icon: nil),
    ]
}

var history: [(t: Date, temp: Double)] = []
func setState(cpu: Double, gpu: Double, ram: Double, temp: Double, hot: Bool = false, t: Double) {
    var s = Snapshot()
    s.cpu = cpu; s.gpu = gpu; s.ramTotal = 16 * 1_073_741_824; s.ramUsed = s.ramTotal * ram / 100; s.swap = 0
    s.cpuTemp = temp; s.gpuTemp = temp - 4; s.ssdTemp = 36; s.batteryTemp = hot ? 36 : 30
    s.thermalState = hot ? .serious : .nominal
    m.snap = s
    m.cpuHist = Array((m.cpuHist + [cpu]).suffix(40))
    m.gpuHist = Array((m.gpuHist + [gpu]).suffix(40))
    m.tempHist = Array((m.tempHist + [temp]).suffix(40))
    m.apps = fakeApps(hot: hot)
    history.append((Date().addingTimeInterval(t), temp))
    m.advice = Advisor.advise(s, apps: m.apps, history: history)
}

struct Scene: View {
    var caption: String
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.62, green: 0.48, blue: 0.62), Color(red: 0.95, green: 0.68, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar
            HStack(spacing: 16) {
                Image(systemName: "applelogo").font(.system(size: 13, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 13)) }
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75")
                Text("Wed 9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).frame(height: notchH)
            .background(Color.black.opacity(0.18))
            // Physical notch
            NotchShape(radius: 10).fill(.black).frame(width: notchW, height: notchH)
            // Thermo
            NotchRoot(m: m, settings: settings, notchWidth: notchW, notchHeight: notchH)
                .frame(width: W, height: H)
            // Caption
            VStack { Spacer()
                Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.bottom, 12)
            }
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .dark)
    }
}

var frames: [(CGImage, Double)] = []
func shot(_ caption: String, _ delay: Double = 0.12) {
    let img: CGImage? = MainActor.assumeIsolated {   // top-level code runs on the main thread
        let r = ImageRenderer(content: Scene(caption: caption))
        r.scale = 1.5
        return r.cgImage
    }
    if let img { frames.append((img, delay)) }
}

// 1. Idle, single orb.
settings.style = .orb; m.expanded = false; m.tab = .overview
for i in 0..<10 { setState(cpu: 8 + Double(i % 3) * 3, gpu: 6, ram: 52, temp: 48, t: Double(i)); shot("One glanceable orb beside the notch") }
// 2. All gauges, load ramps up.
settings.style = .rings
for i in 0..<14 { let k = Double(i); setState(cpu: 10 + k * 4, gpu: 8 + k * 3, ram: 55 + k, temp: 50 + k * 0.8, t: 10 + k); shot("…or every gauge at once") }
// 3. Hover → overview.
m.expanded = true
for i in 0..<14 { let k = Double(i); setState(cpu: 62 + sin(k) * 6, gpu: 48 + cos(k) * 5, ram: 68, temp: 62 + k * 0.5, t: 24 + k); shot("Hover to expand: live CPU, memory, GPU, temps") }
// 4. Apps tab.
m.tab = .apps; m.sortByMemory = false
for i in 0..<12 { setState(cpu: 70 + Double(i % 4), gpu: 52, ram: 70, temp: 70 + Double(i) * 0.4, t: 38 + Double(i)); shot("See which apps and projects are busy, and quit them") }
// 5. Heat tab, overheating.
m.tab = .thermal
for i in 0..<18 { setState(cpu: 92, gpu: 78, ram: 74, temp: 86 + Double(i) * 0.3, hot: true, t: 50 + Double(i)); m.blink = i % 2 == 0; shot("Heat advisor: what's slowing down, why, and how to cool off") }
// 6. Collapse while hot: flame pulses.
m.expanded = false
for i in 0..<12 { setState(cpu: 90, gpu: 76, ram: 74, temp: 91, hot: true, t: 68 + Double(i)); m.blink = i % 2 == 0; shot("Pulses when your Mac runs hot", 0.25) }

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/demo.gif")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (img, d) in frames {
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("Wrote \(frames.count) frames to \(out.path)")
