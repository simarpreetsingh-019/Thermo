// 1.6: history. One averaged point per minute for the last 24 h (≈60 KB on disk), plus one battery-health
// reading per day. Saved to ~/Library/Application Support/Thermo so it survives restarts.

import Foundation
import SwiftUI

struct HistPoint: Codable {
    var t: Int                       // minute since 1970
    var cpu: Float, ram: Float, gpu: Float
    var temp: Float?, battery: Float?
}

struct HealthEntry: Codable { var date: Date; var health: Double; var cycles: Int }

enum HistRange: String, CaseIterable { case hour = "1H", day = "24H" }

final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var points: [HistPoint] = []
    @Published private(set) var healthLog: [HealthEntry] = []
    private var acc: (t: Int, n: Float, cpu: Float, ram: Float, gpu: Float, temp: Float, nt: Float, bat: Float?)?
    private var dirty = 0
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Thermo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private struct Saved: Codable { var points: [HistPoint]; var health: [HealthEntry] }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            points = s.points; healthLog = s.health
        }
    }

    /// Used by tools/demo.swift to show a full day of sample data.
    func showDemo(_ p: [HistPoint]) { points = p }

    /// Re-read the file (used by the command line and MCP server, which don't record history themselves).
    func reload() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) { points = s.points; healthLog = s.health }
    }

    /// Called every sample (2 s); folds samples into the current minute.
    func add(_ s: Snapshot, battery: BatteryInfo) {
        let minute = Int(Date().timeIntervalSince1970 / 60)
        if let a = acc, a.t != minute { flush() }
        var a = acc ?? (minute, 0, 0, 0, 0, 0, 0, nil)
        a.n += 1; a.cpu += Float(s.cpu); a.ram += Float(s.ramPct); a.gpu += Float(s.gpu ?? 0)
        if let t = s.hottest { a.temp += Float(t); a.nt += 1 }
        if battery.present { a.bat = Float(battery.percent) }
        acc = a
        if battery.present && battery.health > 0 { logHealth(battery) }
    }

    private func flush() {
        guard let a = acc, a.n > 0 else { return }
        acc = nil
        points.append(HistPoint(t: a.t, cpu: a.cpu / a.n, ram: a.ram / a.n, gpu: a.gpu / a.n,
                                temp: a.nt > 0 ? a.temp / a.nt : nil, battery: a.bat))
        let cutoff = a.t - 24 * 60
        if let i = points.firstIndex(where: { $0.t > cutoff }), i > 0 { points.removeFirst(i) }
        dirty += 1
        if dirty >= 10 { save() }   // write at most every 10 minutes
    }

    private func logHealth(_ b: BatteryInfo) {
        if let last = healthLog.last, Calendar.current.isDateInToday(last.date) { return }
        healthLog.append(HealthEntry(date: Date(), health: b.health, cycles: b.cycles))
        if healthLog.count > 400 { healthLog.removeFirst(healthLog.count - 400) }
        save()
    }

    func save() {
        dirty = 0
        if let d = try? JSONEncoder().encode(Saved(points: points, health: healthLog)) { try? d.write(to: file, options: .atomic) }
    }

    /// Fixed-width series for a chart: 60 one-minute slots or 144 ten-minute slots; nil where Thermo wasn't running.
    func series(_ key: KeyPath<HistPoint, Float?>, range: HistRange) -> [Double?] {
        let now = Int(Date().timeIntervalSince1970 / 60)
        let (slots, width) = range == .hour ? (60, 1) : (144, 10)
        let start = now - slots * width
        var sum = [Double](repeating: 0, count: slots), n = [Double](repeating: 0, count: slots)
        for p in points where p.t > start {
            guard let v = p[keyPath: key] else { continue }
            let i = min((p.t - start - 1) / width, slots - 1)
            sum[i] += Double(v); n[i] += 1
        }
        return (0..<slots).map { n[$0] > 0 ? sum[$0] / n[$0] : nil }
    }
}

extension HistPoint {
    var cpuV: Float? { cpu }
    var ramV: Float? { ram }
    var gpuV: Float? { gpu }
}

/// Shared crosshair so all four charts show the same moment.
final class ChartHover: ObservableObject { @Published var frac: CGFloat? }

struct LineChart: View {
    let values: [Double?]
    let color: Color
    var lo = 0.0, hi = 100.0
    var hover: ChartHover? = nil
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w
            let y = { (v: Double) in h * (1 - CGFloat(min(max((v - lo) / (hi - lo), 0), 1))) }
            ZStack(alignment: .topLeading) {
                // Filled area and line, broken where there's no data.
                Path { p in
                    var open = false
                    for (i, v) in values.enumerated() {
                        guard let v else { if open { p.addLine(to: CGPoint(x: CGFloat(i - 1) * step, y: h)); p.closeSubpath() }; open = false; continue }
                        let pt = CGPoint(x: CGFloat(i) * step, y: y(v))
                        if !open { p.move(to: CGPoint(x: pt.x, y: h)); open = true }
                        p.addLine(to: pt)
                    }
                    if open { p.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: h)); p.closeSubpath() }
                }.fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    var open = false
                    for (i, v) in values.enumerated() {
                        guard let v else { open = false; continue }
                        let pt = CGPoint(x: CGFloat(i) * step, y: y(v))
                        let lonely = !open && (i + 1 >= values.count || values[i + 1] == nil)
                        if lonely { p.addEllipse(in: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3)) }
                        open ? p.addLine(to: pt) : p.move(to: pt); open = true
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                if let hv = hover, let f = hv.frac {
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: h).offset(x: f * w)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard let hv = hover else { return }
                if case .active(let p) = phase { hv.frac = min(max(p.x / w, 0), 1) } else { hv.frac = nil }
            }
        }
    }
}

struct HistoryTab: View {
    @ObservedObject var m: Monitor
    @ObservedObject var hist = History.shared
    @StateObject private var hover = ChartHover()
    @StateObject private var rangeBox = RangeBox()

    var body: some View {
        let r = rangeBox.range
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                #if !NO_CONNECT
                ForEach([false, true], id: \.self) { b in
                    Button { withAnimation(.easeOut(duration: 0.15)) { rangeBox.bench = b } } label: {
                        Text(b ? "Benchmarks" : "Graphs").font(.system(size: 9, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(rangeBox.bench == b ? .white.opacity(0.2) : .white.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
                #endif
                if !rangeBox.bench {
                Text(caption(r)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 4)
                }
                Spacer()
                if !rangeBox.bench {
                ForEach(HistRange.allCases, id: \.self) { x in
                    Button { rangeBox.range = x } label: {
                        Text(x.rawValue).font(.system(size: 9, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(r == x ? .white.opacity(0.2) : .white.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
                }
            }
            #if !NO_CONNECT
            if rangeBox.bench { BenchList() }
            #endif
            if !rangeBox.bench {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                card("CPU", hist.series(\.cpuV, range: r), .cyan, unit: "%")
                card("Memory", hist.series(\.ramV, range: r), .blue, unit: "%")
                card("GPU", hist.series(\.gpuV, range: r), .purple, unit: "%")
                card("Temp", hist.series(\.temp, range: r), .orange, unit: "°", lo: 30, hi: 105)
            }
            }
        }
    }

    func caption(_ r: HistRange) -> String {
        guard let f = hover.frac else { return r == .hour ? "Last hour · hover a chart for details" : "Last 24 hours · hover a chart for details" }
        let minsAgo = Int((1 - f) * (r == .hour ? 60 : 1440))
        let t = Date().addingTimeInterval(Double(-minsAgo * 60))
        return minsAgo < 1 ? "Now" : "\(t.formatted(date: .omitted, time: .shortened)) · \(duration(minsAgo)) ago"
    }

    func card(_ title: String, _ v: [Double?], _ c: Color, unit: String, lo: Double = 0, hi: Double = 100) -> some View {
        let vals = v.compactMap { $0 }
        let shown: Double? = hover.frac.flatMap { f in v.isEmpty ? nil : v[min(Int((f * CGFloat(v.count - 1)).rounded()), v.count - 1)] } ?? vals.last
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                if let mx = vals.max() { Text("peak \(Int(mx))\(unit)").font(.system(size: 8)).foregroundStyle(.secondary) }
                Text(shown.map { "\(Int($0))\(unit)" } ?? "—").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(c)
            }
            if vals.isEmpty {
                Text("Collecting… first point in a minute").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 24)
            } else {
                LineChart(values: v, color: c, lo: lo, hi: hi, hover: hover).frame(height: 24)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
    }
}

final class RangeBox: ObservableObject { static var startInBench = false; @Published var range: HistRange = .hour; @Published var bench = RangeBox.startInBench }
