// SwiftUI views: the compact strip, the expanded interactive panel, and its tabs.

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Model

enum Tab: String, CaseIterable { case overview = "Overview", apps = "Apps", memory = "Memory", thermal = "Heat" }
enum DisplayMode: String, CaseIterable { case notch = "Around the notch", floating = "Floating (movable)", menuBar = "Menu bar only" }
enum Orientation: String, CaseIterable { case horizontal = "Horizontal", vertical = "Vertical" }
enum NotchSide: String, CaseIterable { case both = "Both sides", left = "Left of notch", right = "Right of notch" }
enum CompactStyle: String, CaseIterable { case orb = "Single orb", rings = "All gauges" }

final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var mode: DisplayMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var orientation: Orientation { didSet { d.set(orientation.rawValue, forKey: "orientation") } }
    @Published var menuBarItem: Bool { didSet { d.set(menuBarItem, forKey: "menuBarItem") } }
    @Published var style: CompactStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var notchSide: NotchSide { didSet { d.set(notchSide.rawValue, forKey: "notchSide") } }

    init(hasNotch: Bool) {
        mode = DisplayMode(rawValue: d.string(forKey: "mode") ?? "") ?? (hasNotch ? .notch : .floating)
        orientation = Orientation(rawValue: d.string(forKey: "orientation") ?? "") ?? .horizontal
        menuBarItem = d.object(forKey: "menuBarItem") as? Bool ?? !hasNotch   // notch Macs already see stats at the notch
        style = CompactStyle(rawValue: d.string(forKey: "style") ?? "") ?? .orb
        notchSide = NotchSide(rawValue: d.string(forKey: "notchSide") ?? "") ?? .both
    }
}

final class Monitor: ObservableObject {
    @Published var snap = Snapshot()
    @Published var cpuHist: [Double] = []
    @Published var gpuHist: [Double] = []
    @Published var tempHist: [Double] = []
    @Published var apps: [AppUsage] = []
    @Published var advice = ThermalAdvice()
    @Published var memAdvice = MemoryAdvice()
    @Published var expanded = false
    @Published var pinned = false
    @Published var tab: Tab = .overview
    @Published var sortByMemory = false
    @Published var blink = false
    private var tempSamples: [(t: Date, temp: Double)] = []
    private let sampler = Sampler()
    private let procs = ProcSampler()
    private let queue = DispatchQueue(label: "sampler")
    private var timer: Timer?
    private var ticks = 0

    init() {
        _ = sampler.sample()
        _ = procs.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.5   // lets macOS batch wake-ups to save energy
        tick()
    }

    private func tick() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.sampler.sample()
            // The per-process scan is the costliest step: run it every tick only while the
            // Apps/Heat list is on screen, otherwise every 4th tick (8 s) to keep advice fresh.
            self.ticks += 1
            let listVisible = self.expanded && self.tab != .overview
            let a: [AppUsage]? = (listVisible || self.ticks % 4 == 1) ? self.procs.sample() : nil
            DispatchQueue.main.async {
                self.snap = s
                if let a { self.apps = a }
                self.cpuHist = Array((self.cpuHist + [s.cpu]).suffix(40))
                self.gpuHist = Array((self.gpuHist + [s.gpu ?? 0]).suffix(40))
                if let t = s.hottest {
                    self.tempHist = Array((self.tempHist + [t]).suffix(40))
                    self.tempSamples = (self.tempSamples + [(Date(), t)]).filter { $0.t > Date().addingTimeInterval(-120) }
                }
                self.advice = Advisor.advise(s, apps: self.apps, history: self.tempSamples)
                self.memAdvice = MemoryAdvisor.advise(s, apps: self.apps)
                AlertEngine.shared.evaluate(self)
                if self.advice.level >= .hot { self.blink.toggle() }
            }
        }
    }

    var sortedApps: [AppUsage] {
        Array(apps.sorted { sortByMemory ? $0.mem > $1.mem : $0.cpu > $1.cpu }.prefix(8))
    }
}

// MARK: - Helpers

func load(_ p: Double) -> Color { p < 60 ? .green : p < 85 ? .orange : .red }
func heat(_ t: Double) -> Color { t < 70 ? .green : t < 85 ? .orange : .red }
func levelColor(_ l: HeatLevel) -> Color { [Color.green, .yellow, .orange, .red][l.rawValue] }
func gb(_ b: Double) -> String { b >= 1_073_741_824 ? String(format: "%.1f GB", b / 1_073_741_824) : String(format: "%.0f MB", b / 1_048_576) }
func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

struct Spark: View {
    let values: [Double]
    let color: Color
    var lo = 0.0, hi = 100.0
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                let step = g.size.width / 39
                let off = CGFloat(40 - values.count)
                for (i, v) in values.enumerated() {
                    let y = g.size.height * (1 - min(max((v - lo) / (hi - lo), 0), 1))
                    let pt = CGPoint(x: (CGFloat(i) + off) * step, y: y)
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

struct Bar: View {
    let value: Double
    var color: Color? = nil
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(color ?? load(value)).frame(width: g.size.width * min(value, 100) / 100)
            }
        }.frame(height: 5)
    }
}

struct HoverCard<Content: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @StateObject private var h = HoverBox()
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(h.on && action != nil ? 0.14 : 0.07)))
            .scaleEffect(h.on && action != nil ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: h.on)
            .contentShape(Rectangle())
            .onHover { h.on = $0 }
            .onTapGesture { action?() }
    }
}

// MARK: - Compact strip

struct Pill: View {
    let label: String, value: String, color: Color
    var body: some View {
        HStack(spacing: 3) {
            if !label.isEmpty { Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).fixedSize()
        }
    }
}

struct TempPill: View {
    @ObservedObject var m: Monitor
    var body: some View {
        if let t = m.snap.hottest {
            let alert = m.advice.level >= .hot
            HStack(spacing: 2) {
                if alert { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
                Text(String(format: "%.0f°", t)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(heat(t))
            .opacity(alert && m.blink ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.7), value: m.blink)
            .fixedSize()
        }
    }
}

struct CompactStrip: View {
    @ObservedObject var m: Monitor
    let vertical: Bool
    var orb = false
    var body: some View {
        let s = m.snap
        if orb { Orb(m: m, size: 34).padding(6) } else {
        let items = Group {
            Ring(metric: .cpu, value: s.cpu, size: 26, showLabel: true)
            Ring(metric: .ram, value: s.ramPct, size: 26, showLabel: true)
            Ring(metric: .gpu, value: s.gpu, size: 26, showLabel: true)
            TempBadge(m: m)
        }
        if vertical {
            VStack(spacing: 8) { items }.padding(.horizontal, 8).padding(.vertical, 10)
        } else {
            HStack(spacing: 10) { items }.padding(.horizontal, 12).padding(.vertical, 7)
        }
        }
    }
}

// MARK: - Expanded panel

struct ExpandedPanel: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings: Settings
    @ObservedObject var up = Updater.shared
    var showPin = false
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { withAnimation(.easeOut(duration: 0.2)) { m.tab = t } } label: {
                        HStack(spacing: 4) {
                            Text(t.rawValue)
                            if t == .thermal && m.advice.level >= .warm {
                                Circle().fill(levelColor(m.advice.level)).frame(width: 6, height: 6)
                            }
                            if t == .memory && (m.memAdvice.pressure > .normal || m.memAdvice.swapping) {
                                Circle().fill(m.memAdvice.pressure.color).frame(width: 6, height: 6)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(m.tab == t ? .white.opacity(0.18) : .clear))
                        .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let r = up.available {
                    Button { up.promptInstall() } label: {
                        Label("Update \(r.version)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.9)))
                    }.buttonStyle(.plain).help("A new version of Thermo is available")
                }
                if showPin {
                    iconButton(m.pinned ? "pin.fill" : "pin", help: m.pinned ? "Unpin" : "Keep open") { m.pinned.toggle() }
                }
                SettingsMenu(settings: settings)
                if let onCollapse { iconButton("chevron.up", help: "Collapse", action: onCollapse) }
            }
            Group {
                switch m.tab {
                case .overview: OverviewTab(m: m)
                case .apps: AppsTab(m: m)
                case .thermal: ThermalTab(m: m)
                case .memory: MemoryTab(m: m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let st = up.status {
                Text(st).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 440, height: 210)
        .foregroundStyle(.white)
    }

    func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }.buttonStyle(.plain).help(help)
    }
}

private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

/// Set by tools/demo.swift: ImageRenderer can't draw menus or scroll views, so plain stand-ins are used.
enum Offscreen { static var rendering = false }

/// A ScrollView in the app; a plain stack when rendering the README demo offscreen.
struct MaybeScroll<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        if Offscreen.rendering { VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else { ScrollView { content } }
    }
}

struct SettingsMenu: View {
    @ObservedObject var settings: Settings
    var body: some View {
        if Offscreen.rendering {
            Image(systemName: "gearshape.fill").font(.system(size: 11))
                .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.1)))
        } else { realMenu }
    }
    var realMenu: some View {
        Menu {
            Picker("Show", selection: $settings.mode) {
                ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Compact style", selection: $settings.style) {
                ForEach(CompactStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if settings.mode == .notch {
                Picker("Notch side", selection: $settings.notchSide) {
                    ForEach(NotchSide.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            Picker("Floating layout", selection: $settings.orientation) {
                ForEach(Orientation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if settings.mode == .floating {
                Menu("Move to") {
                    ForEach(Corner.allCases, id: \.self) { c in
                        Button(c.rawValue) { NotificationCenter.default.post(name: .moveToCorner, object: c) }
                    }
                }
            }
            Toggle("Also show in menu bar", isOn: $settings.menuBarItem)
                .disabled(settings.mode == .menuBar)
            Toggle("Smart alerts (heat, memory, stuck apps)", isOn: Binding(
                get: { AlertEngine.shared.enabled },
                set: { AlertEngine.shared.enabled = $0; settings.objectWillChange.send() }))
            Toggle("Open at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in setOpenAtLogin(on); settings.objectWillChange.send() }))
            Divider()
            Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { Updater.shared.autoCheck }, set: { Updater.shared.autoCheck = $0 }))
            Button("Send Feedback…") { sendFeedback() }
            Menu("About Thermo") {
                Text("Thermo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") — by Simarpreet Singh")
                Button("Portfolio: simarpreetsingh-019.github.io") { open("https://simarpreetsingh-019.github.io") }
                Button("X / Twitter: @simarpreet_019") { open("https://x.com/simarpreet_019") }
                Button("Send feedback") { sendFeedback() }
                Divider()
                Button("⭐ Star Thermo on GitHub") { open("https://github.com/simarpreetsingh-019/Thermo") }
                Button("Report an issue or idea") { open("https://github.com/simarpreetsingh-019/Thermo/issues/new") }
            }
            Button("Open Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .background(Circle().fill(.white.opacity(0.1)))
    }
}

struct OverviewTab: View {
    @ObservedObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tiles
            let h = healthSummary(m)
            HStack(spacing: 6) {
                Circle().fill([Color.green, .orange, .red][h.level]).frame(width: 7, height: 7)
                Text(h.text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
    }

    var tiles: some View {
        let s = m.snap
        return HStack(spacing: 8) {
            HoverCard(action: { m.sortByMemory = false; m.tab = .apps }) {
                tile("CPU", pct(s.cpu), bar: s.cpu, sub: "\(ProcessInfo.processInfo.activeProcessorCount) cores · tap for apps") {
                    Spark(values: m.cpuHist, color: .cyan).frame(height: 30)
                }
            }
            HoverCard(action: { m.tab = .memory }) {
                tile("MEMORY", gb(s.ramUsed), bar: s.ramPct, barColor: s.memPressure.color, sub: "of \(gb(s.ramTotal))\nswap \(gb(s.swap))") {
                    HStack(spacing: 4) {
                        Circle().fill(s.memPressure.color).frame(width: 6, height: 6)
                        Text("Pressure: \(s.memPressure.title)").font(.system(size: 9, weight: .semibold))
                    }
                }
            }
            HoverCard(action: nil) {
                tile("GPU", s.gpu.map(pct) ?? "N/A", bar: s.gpu, sub: "utilization") {
                    Spark(values: m.gpuHist, color: .purple).frame(height: 30)
                }
            }
            HoverCard(action: { m.tab = .thermal }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TEMP").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    row("CPU", s.cpuTemp); row("GPU", s.gpuTemp); row("SSD", s.ssdTemp); row("Batt", s.batteryTemp)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Circle().fill(levelColor(m.advice.level)).frame(width: 6, height: 6)
                        Text(m.advice.level.title).font(.system(size: 9, weight: .semibold))
                    }
                }
            }
        }
    }

    func tile<V: View>(_ title: String, _ value: String, bar: Double?, barColor: Color? = nil, sub: String, @ViewBuilder extra: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let bar { Bar(value: bar, color: barColor) }
            extra()
            Spacer(minLength: 0)
            Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func row(_ label: String, _ t: Double?) -> some View {
        if let t {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f°", t)).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(heat(t)).monospacedDigit()
            }
        }
    }
}

struct AppRow: View {
    let a: AppUsage
    var highlightMemory = false
    @StateObject private var h = HoverBox()
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = a.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let p = a.project { Text("📁 \(p)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(pct(a.cpu)).font(.system(size: 11, weight: highlightMemory ? .regular : .bold, design: .rounded))
                .foregroundStyle(highlightMemory ? .secondary : load(min(a.cpu, 100))).monospacedDigit().frame(width: 48, alignment: .trailing)
            Text(gb(a.mem)).font(.system(size: 11, weight: highlightMemory ? .bold : .regular, design: .rounded))
                .foregroundStyle(highlightMemory ? .white : .secondary).monospacedDigit().frame(width: 58, alignment: .trailing)
            Button { stopApp(a) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    .foregroundStyle(h.on ? .red : .white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!a.canQuit)
            .opacity(a.canQuit ? 1 : 0)
            .help(a.isApp ? "Quit \(a.name)" : "Stop this process")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(h.on ? 0.08 : 0)))
        .onHover { h.on = $0 }
    }
}

struct AppsTab: View {
    @ObservedObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top apps & processes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if Offscreen.rendering {
                    HStack(spacing: 0) {
                        ForEach([("CPU", false), ("Memory", true)], id: \.0) { label, mem in
                            Text(label).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(m.sortByMemory == mem ? 0.22 : 0)))
                        }
                    }.padding(2).background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08))).frame(width: 130)
                } else {
                    Picker("", selection: $m.sortByMemory) {
                        Text("CPU").tag(false); Text("Memory").tag(true)
                    }.pickerStyle(.segmented).frame(width: 130).labelsHidden()
                }
            }
            MaybeScroll {
                VStack(spacing: 1) {
                    ForEach(m.sortedApps) { AppRow(a: $0, highlightMemory: m.sortByMemory) }
                }
            }
        }
    }
}

struct ThermalTab: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let a = m.advice
        MaybeScroll {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: a.level >= .hot ? "flame.fill" : a.level == .warm ? "thermometer.medium" : "snowflake")
                        .font(.system(size: 20)).foregroundStyle(levelColor(a.level))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.headline).font(.system(size: 13, weight: .bold))
                        Text(a.eta).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(m.snap.hottest.map { String(format: "%.0f°C", $0) } ?? "–")
                            .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(heat(m.snap.hottest ?? 0))
                        Spark(values: m.tempHist, color: heat(m.snap.hottest ?? 0), lo: 30, hi: 100).frame(width: 70, height: 16)
                    }
                }
                if !a.affected.isEmpty {
                    section("WHAT'S AFFECTED")
                    ForEach(a.affected, id: \.self) { bullet($0) }
                }
                section(a.culprits.isEmpty ? "HEAT SOURCES" : "WHAT'S CAUSING IT")
                if a.culprits.isEmpty {
                    Text("Nothing is using much CPU right now.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(a.culprits) { AppRow(a: $0) }
                }
                if !a.tips.isEmpty {
                    section("WHAT YOU CAN DO")
                    ForEach(a.tips, id: \.self) { bullet($0) }
                }
            }
        }
    }
    func section(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).padding(.top, 2)
    }
    func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(t).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

final class HoverBox: ObservableObject { @Published var on = false }

// MARK: - Ring gauges (compact, game-HUD style)

enum Metric: String { case cpu = "CPU", ram = "RAM", gpu = "GPU"
    var tint: Color { switch self { case .cpu: return .cyan; case .ram: return Color(red: 0.75, green: 0.5, blue: 1); case .gpu: return .mint } }
}

/// Ring fills with the value; base colour identifies the metric and shifts to orange/red under heavy load.
struct Ring: View {
    let metric: Metric
    let value: Double?
    var size: CGFloat = 22
    var showLabel = false
    var body: some View {
        let v = value ?? 0
        let c = v >= 85 ? Color.red : v >= 60 ? Color.orange : metric.tint
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(c.opacity(0.18), lineWidth: 2.6)
                Circle().trim(from: 0, to: min(v, 100) / 100)
                    .stroke(c, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: c.opacity(0.8), radius: v > 5 ? 2.5 : 0)
                    .animation(.easeOut(duration: 0.6), value: v)
                Text(value.map { "\(Int($0))" } ?? "–")
                    .font(.system(size: size * 0.4, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            if showLabel { Text(metric.rawValue).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary) }
        }
        .help("\(metric.rawValue) \(value.map { "\(Int($0))%" } ?? "n/a")")
    }
}

struct TempBadge: View {
    @ObservedObject var m: Monitor
    var big = false
    var body: some View {
        if let t = m.snap.hottest {
            let alert = m.advice.level >= .hot
            HStack(spacing: 2) {
                Image(systemName: alert ? "flame.fill" : "thermometer.medium").font(.system(size: big ? 12 : 11, weight: .bold))
                Text("\(Int(t))°").font(.system(size: big ? 14 : 12, weight: .heavy, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(heat(t))
            .shadow(color: heat(t).opacity(alert ? 0.9 : 0.4), radius: alert ? 4 : 2)
            .opacity(alert && m.blink ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.7), value: m.blink)
            .fixedSize()
            .help("Hottest sensor \(Int(t))°C — \(m.advice.level.title)")
        }
    }
}

// MARK: - Orb: one glanceable indicator showing whatever matters most right now

struct OrbReading { let label: String; let text: String; let fraction: Double; let color: Color }

func headline(_ m: Monitor) -> OrbReading {
    let s = m.snap
    if m.advice.level >= .warm, let t = s.hottest {
        return OrbReading(label: "TEMP", text: "\(Int(t))°", fraction: (t - 30) / 70, color: heat(t))
    }
    if s.memPressure >= .warning { return OrbReading(label: "RAM", text: "\(Int(s.ramPct))", fraction: s.ramPct / 100, color: s.memPressure.color) }
    let gpu = s.gpu ?? 0
    let (label, v, tint) = gpu > s.cpu ? ("GPU", gpu, Metric.gpu.tint) : ("CPU", s.cpu, Metric.cpu.tint)
    return OrbReading(label: label, text: "\(Int(v))", fraction: v / 100, color: v >= 60 ? load(v) : tint)
}

struct Orb: View {
    @ObservedObject var m: Monitor
    var size: CGFloat = 26
    var body: some View {
        let r = headline(m)
        let alert = m.advice.level >= .hot
        ZStack {
            Circle().fill(RadialGradient(colors: [r.color.opacity(0.55), r.color.opacity(0.08)],
                                         center: .center, startRadius: 0, endRadius: size * 0.6))
            Circle().stroke(r.color.opacity(0.2), lineWidth: size * 0.09)
            Circle().trim(from: 0, to: min(max(r.fraction, 0.02), 1))
                .stroke(AngularGradient(colors: [r.color.opacity(0.4), r.color], center: .center),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: r.color, radius: size * 0.12)
                .animation(.easeOut(duration: 0.6), value: r.fraction)
            VStack(spacing: -1) {
                Text(r.text).font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).monospacedDigit()
                if size >= 30 { Text(r.label).font(.system(size: size * 0.17, weight: .bold)).opacity(0.7) }
            }.foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .scaleEffect(alert && m.blink ? 1.08 : 1)
        .animation(.easeInOut(duration: 0.7), value: m.blink)
        .help("\(healthSummary(m).text)\n\(r.label) \(r.text): click for details")
    }
}
