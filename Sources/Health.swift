// 1.5.0: memory advisor, one-line Mac health summary, and smart alerts.

import AppKit
import SwiftUI

// MARK: - Memory pressure

enum MemPressure: Int, Comparable {
    case normal = 1, warning = 2, critical = 4
    static func < (a: MemPressure, b: MemPressure) -> Bool { a.rawValue < b.rawValue }
    var title: String { switch self { case .normal: return "Normal"; case .warning: return "Tight"; case .critical: return "Critical" } }
    var color: Color { switch self { case .normal: return .green; case .warning: return .orange; case .critical: return .red } }

    /// macOS's own verdict (same signal as Activity Monitor's pressure graph). No admin rights needed.
    static func read() -> MemPressure {
        var level: Int32 = 1, size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemPressure(rawValue: Int(level)) ?? .normal
    }
}

struct MemoryAdvice {
    var pressure: MemPressure = .normal
    var headline = ""
    var explain = ""
    var swapping = false
    var suggestions: [AppUsage] = []   // biggest quittable memory users
    var freeable: Double = 0           // bytes freed by quitting the suggestions
}

enum MemoryAdvisor {
    static let swapWarn = 1.0 * 1_073_741_824

    static func advise(_ s: Snapshot, apps: [AppUsage]) -> MemoryAdvice {
        var a = MemoryAdvice()
        a.pressure = s.memPressure
        a.swapping = s.swap >= swapWarn
        switch (a.pressure, a.swapping) {
        case (.normal, false):
            a.headline = "Memory is fine"
            a.explain = "\(Int(s.ramPct))% in use is normal: macOS keeps spare RAM busy as cache so apps open fast, and frees it instantly when needed."
        case (.normal, true):
            a.headline = "Memory is OK, but some is on disk"
            a.explain = "\(gb(s.swap)) was moved to disk (swap) earlier. Things may feel slow when you switch back to older apps."
        case (.warning, _):
            a.headline = "Memory is getting tight"
            a.explain = "macOS is compressing memory\(a.swapping ? " and using \(gb(s.swap)) of disk as swap" : ""). Apps may start to lag."
        case (.critical, _):
            a.headline = "Out of memory: your Mac is slowing down"
            a.explain = "macOS is swapping heavily (\(gb(s.swap)) on disk). Closing a big app will help right away."
        }
        let candidates = apps.filter { $0.canQuit && $0.mem >= 300 * 1_048_576 }.sorted { $0.mem > $1.mem }
        a.suggestions = Array(candidates.prefix(a.pressure > .normal || a.swapping ? 3 : 2))
        a.freeable = a.suggestions.reduce(0) { $0 + $1.mem }
        return a
    }
}

// MARK: - One-line health summary

struct HealthSummary { let level: Int; let text: String }   // 0 good, 1 attention, 2 problem

func healthSummary(_ m: Monitor) -> HealthSummary {
    let heat = m.advice.level, mem = m.memAdvice.pressure
    let runaway = m.apps.filter { $0.cpu >= 150 }.max { $0.cpu < $1.cpu }
    func who(_ a: AppUsage?) -> String { a.map { "close \($0.name)\($0.project.map { " (\($0))" } ?? "")" } ?? "" }

    if heat >= .hot && mem >= .warning { return HealthSummary(level: 2, text: "Hot and low on memory: \(who(m.advice.culprits.first ?? m.memAdvice.suggestions.first))") }
    if heat >= .hot { return HealthSummary(level: 2, text: "Running hot\(m.advice.culprits.first.map { ": " + who($0) } ?? "")") }
    if mem == .critical { return HealthSummary(level: 2, text: "Out of memory: \(who(m.memAdvice.suggestions.first))") }
    if let r = runaway { return HealthSummary(level: 1, text: "\(r.name) is very busy (\(Int(r.cpu))% CPU)") }
    if mem == .warning { return HealthSummary(level: 1, text: "Memory is tight: \(who(m.memAdvice.suggestions.first))") }
    if heat == .warm { return HealthSummary(level: 1, text: "Warming up, still at full speed") }
    return HealthSummary(level: 0, text: "All good: cool, plenty of memory")
}

// MARK: - Smart alerts

/// Fires a notification card when a problem lasts long enough to matter, at most once per 30 min per kind.
final class AlertEngine {
    static let shared = AlertEngine()
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "smartAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "smartAlerts") }
    }
    private var since: [String: Date] = [:]
    private var lastFired: [String: Date] = [:]

    func evaluate(_ m: Monitor) {
        guard enabled else { return }
        let runaway = m.apps.filter { $0.cpu >= 150 && $0.canQuit }.max { $0.cpu < $1.cpu }
        check("heat", m.advice.level >= .hot, sustain: 60) {
            let c = m.advice.culprits.first
            return ToastContent(icon: "flame.fill", tint: .orange,
                title: "Your Mac is running hot (\(Int(m.snap.hottest ?? 0))°)",
                subtitle: "It has been hot for over a minute, so macOS may be slowing things down.",
                bullets: Array(m.advice.tips.prefix(2)),
                actions: alertActions(m, quit: c, tab: .thermal))
        }
        check("memory", m.memAdvice.pressure >= .warning, sustain: 30) {
            let a = m.memAdvice
            return ToastContent(icon: "memorychip.fill", tint: a.pressure.color,
                title: a.headline,
                subtitle: a.suggestions.isEmpty ? a.explain : "Quitting \(a.suggestions.map(\.name).joined(separator: ", ")) would free about \(gb(a.freeable)).",
                actions: alertActions(m, quit: a.suggestions.first, tab: .memory))
        }
        check("runaway", runaway != nil, sustain: 180) {
            let r = runaway!
            return ToastContent(icon: "exclamationmark.triangle.fill", tint: .yellow,
                title: "\(r.name) has been busy for 3+ minutes",
                subtitle: "It's using \(Int(r.cpu))% CPU\(r.project.map { " in \($0)" } ?? ""). If you didn't expect that, it may be stuck.",
                actions: alertActions(m, quit: r, tab: .apps))
        }
    }

    private func check(_ kind: String, _ active: Bool, sustain: TimeInterval, make: () -> ToastContent) {
        guard active else { since[kind] = nil; return }
        let start = since[kind] ?? Date()
        since[kind] = start
        guard Date().timeIntervalSince(start) >= sustain else { return }
        if let last = lastFired[kind], Date().timeIntervalSince(last) < 30 * 60 { return }
        lastFired[kind] = Date()
        Toasts.shared.show(make())
    }

    private func alertActions(_ m: Monitor, quit: AppUsage?, tab: Tab) -> [ToastAction] {
        var acts = [ToastAction(title: "Details", primary: quit == nil, run: {
            m.tab = tab
            NotificationCenter.default.post(name: .showPanel, object: nil)
        })]
        if let q = quit { acts.append(ToastAction(title: "Quit \(q.name)", primary: true, run: { stopApp(q) })) }
        return acts
    }
}

extension Notification.Name { static let showPanel = Notification.Name("showPanel") }

// MARK: - Memory tab

struct MemoryTab: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let a = m.memAdvice, s = m.snap
        MaybeScroll {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "memorychip.fill").font(.system(size: 20)).foregroundStyle(a.pressure.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.headline).font(.system(size: 13, weight: .bold))
                        Text(a.explain).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(a.pressure.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(a.pressure.color)
                        Text("pressure").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    stat("In use", gb(s.ramUsed), "of \(gb(s.ramTotal))")
                    stat("Swap", gb(s.swap), a.swapping ? "slows your Mac" : "on disk")
                    stat("Could free", gb(a.freeable), "by quitting below")
                }
                Text(a.suggestions.isEmpty ? "NOTHING BIG TO CLOSE" : "BIGGEST MEMORY USERS")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                ForEach(a.suggestions) { AppRow(a: $0, highlightMemory: true) }
                Text("Thermo never \"cleans\" RAM: macOS uses spare memory as cache on purpose. Quitting an app you don't need is the only real fix.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
            Text(sub).font(.system(size: 8)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
