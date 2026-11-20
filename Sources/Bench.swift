// 1.8: benchmark recorder. Samples CPU, GPU, memory and every temperature while a workload runs, then
// reports averages, peaks, temperature rise and throttling time. Used by `thermo bench` and the MCP tools
// start_benchmark / stop_benchmark, so an agent can measure the load its own test or build puts on the Mac.

#if !NO_CONNECT

import Foundation

final class BenchRecorder {
    struct Sample {
        let t: Double
        let cpu: Double, gpu: Double?, ramUsed: Double, swap: Double
        let hottest: Double?, parts: [String: Double]
        let throttled: Bool
        let procCPU: Double?, procMem: Double?
    }

    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let label: String
    let process: String?
    let interval: Double
    let started = Date()
    private(set) var samples: [Sample] = []
    private var running = true
    private let lock = NSLock()
    private var thread: Thread?
    private var ramTotal = 0.0

    init(label: String, process: String? = nil, interval: Double = 1) {
        self.label = label
        self.process = process?.lowercased()
        self.interval = min(max(interval, 0.5), 10)
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    private func loop() {
        let probe = Probe()
        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { break }
            let r = probe.read(processes: process != nil)
            let s = r.snap
            ramTotal = s.ramTotal
            var pc: Double?, pm: Double?
            if let p = process {
                let hits = r.apps.filter { $0.name.lowercased().contains(p) || ($0.project?.lowercased().contains(p) ?? false) }
                if !hits.isEmpty { pc = hits.reduce(0) { $0 + $1.cpu }; pm = hits.reduce(0) { $0 + $1.mem } }
            }
            let sample = Sample(t: Date().timeIntervalSince(started), cpu: s.cpu, gpu: s.gpu, ramUsed: s.ramUsed, swap: s.swap,
                                hottest: s.hottest, parts: Dictionary(uniqueKeysWithValues: s.parts.map { ($0.id, $0.value) }),
                                throttled: s.thermalState == .serious || s.thermalState == .critical, procCPU: pc, procMem: pm)
            lock.lock(); samples.append(sample); if samples.count > 7200 { samples.removeFirst() }; lock.unlock()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Stops sampling and returns the report.
    func stop() -> [String: Any] {
        lock.lock(); running = false; let s = samples; lock.unlock()
        var r = Self.report(label: label, process: process, duration: Date().timeIntervalSince(started), samples: s, ramTotal: ramTotal, interval: interval)
        r["id"] = id
        r["started_at"] = ISO8601DateFormatter().string(from: started)
        return r
    }

    /// Per-sample series for CSV export: seconds, cpu %, gpu %, hottest °C, memory used GB, process cpu %.
    var series: [[Any]] {
        lock.lock(); defer { lock.unlock() }
        return samples.map { [Self.n1($0.t), Self.n1($0.cpu), $0.gpu.map(Self.n1) ?? NSNull(), $0.hottest.map(Self.n1) ?? NSNull(),
                              Self.n1($0.ramUsed / 1_073_741_824), $0.procCPU.map(Self.n1) ?? NSNull()] }
    }

    var elapsed: Double { Date().timeIntervalSince(started) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    // MARK: Report

    static func n1(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", v)) }
    private static func stat(_ v: [Double]) -> Any {
        guard !v.isEmpty else { return NSNull() }
        let avg = v.reduce(0, +) / Double(v.count), sorted = v.sorted()
        return ["avg": n1(avg), "peak": n1(sorted.last!), "min": n1(sorted.first!), "p95": n1(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])]
    }

    static func report(label: String, process: String?, duration: Double, samples s: [Sample], ramTotal: Double, interval: Double) -> [String: Any] {
        let gb = 1_073_741_824.0
        let temps = s.compactMap(\.hottest)
        let throttledSamples = s.filter(\.throttled)
        var parts: [String: Any] = [:]
        for name in Set(s.flatMap { $0.parts.keys }) {
            let v = s.compactMap { $0.parts[name] }
            if let first = v.first, let peak = v.max() { parts[name] = ["start_c": n1(first), "peak_c": n1(peak), "rise_c": n1(peak - first)] }
        }
        let startT = temps.first, peakT = temps.max(), endT = temps.last
        var out: [String: Any] = [
            "label": label,
            "duration_seconds": n1(duration),
            "samples": s.count,
            "interval_seconds": n1(interval),
            "cpu_percent": stat(s.map(\.cpu)),
            "gpu_percent": stat(s.compactMap(\.gpu)),
            "memory": ["peak_used_gb": n1((s.map(\.ramUsed).max() ?? 0) / gb), "total_gb": n1(ramTotal / gb),
                       "swap_growth_gb": n1(max(0, ((s.last?.swap ?? 0) - (s.first?.swap ?? 0)) / gb))],
            "temperature": ["start_c": startT.map(n1) ?? NSNull(), "peak_c": peakT.map(n1) ?? NSNull(), "end_c": endT.map(n1) ?? NSNull(),
                            "rise_c": (startT != nil && peakT != nil) ? n1(peakT! - startT!) : NSNull(), "parts": parts],
            "throttling": ["seconds": n1(Double(throttledSamples.count) * interval), "first_at_seconds": throttledSamples.first.map { n1($0.t) } ?? NSNull()],
        ]
        if let p = process {
            let pc = s.compactMap(\.procCPU), pm = s.compactMap(\.procMem)
            out["process"] = ["match": p, "seen_in_samples": pc.count, "cpu_percent": stat(pc),
                              "peak_memory_mb": pm.max().map { Int($0 / 1_048_576) } ?? NSNull()]
        }
        out["summary"] = summary(out, s: s, startT: startT, peakT: peakT, throttled: Double(throttledSamples.count) * interval)
        return out
    }

    private static func summary(_ o: [String: Any], s: [Sample], startT: Double?, peakT: Double?, throttled: Double) -> String {
        func v(_ k: String, _ f: String) -> Int { Int(((o[k] as? [String: Any])?[f] as? NSNumber)?.doubleValue ?? 0) }
        var parts = ["\(Int((o["duration_seconds"] as? NSNumber)?.doubleValue ?? 0)) s: CPU avg \(v("cpu_percent", "avg"))% (peak \(v("cpu_percent", "peak"))%)"]
        if s.contains(where: { $0.gpu != nil }) { parts.append("GPU avg \(v("gpu_percent", "avg"))% (peak \(v("gpu_percent", "peak"))%)") }
        if let a = startT, let b = peakT { parts.append("heat \(Int(a))→\(Int(b))°C (+\(Int(b - a)))") }
        parts.append(throttled > 0 ? "throttled for \(Int(throttled)) s" : "no throttling")
        if let p = o["process"] as? [String: Any], let c = p["cpu_percent"] as? [String: Any] {
            parts.append("\(p["match"] as? String ?? "process") avg \(Int((c["avg"] as? NSNumber)?.doubleValue ?? 0))% CPU")
        }
        return parts.joined(separator: ", ")
    }

    static func text(_ o: [String: Any]) -> String {
        func row(_ name: String, _ k: String, _ unit: String) -> String? {
            guard let d = o[k] as? [String: Any] else { return nil }
            func g(_ f: String) -> Int { Int((d[f] as? NSNumber)?.doubleValue ?? 0) }
            return "  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) avg \(g("avg"))\(unit) · p95 \(g("p95"))\(unit) · peak \(g("peak"))\(unit)"
        }
        var l = ["📊 \(o["label"] as? String ?? "benchmark"): \(o["summary"] as? String ?? "")", ""]
        l += [row("CPU", "cpu_percent", "%"), row("GPU", "gpu_percent", "%")].compactMap { $0 }
        if let t = o["temperature"] as? [String: Any], let parts = t["parts"] as? [String: [String: Any]] {
            l.append("  Heat by part (start → peak):")
            for (k, v) in parts.sorted(by: { $0.key < $1.key }) {
                l.append("    \(k.padding(toLength: 24, withPad: " ", startingAt: 0)) \(Int((v["start_c"] as? NSNumber)?.doubleValue ?? 0))→\(Int((v["peak_c"] as? NSNumber)?.doubleValue ?? 0))°C")
            }
        }
        if let m = o["memory"] as? [String: Any] {
            l.append("  Memory peak \((m["peak_used_gb"] as? NSNumber)?.stringValue ?? "?") of \((m["total_gb"] as? NSNumber)?.stringValue ?? "?") GB, swap +\((m["swap_growth_gb"] as? NSNumber)?.stringValue ?? "0") GB")
        }
        return l.joined(separator: "\n")
    }
}

/// Running benchmarks, by id (MCP server).
enum Benchmarks {
    private static var all: [String: BenchRecorder] = [:]
    static func start(label: String, process: String?, interval: Double) -> BenchRecorder {
        let b = BenchRecorder(label: label, process: process, interval: interval)
        all[b.id] = b
        return b
    }
    static func stop(_ id: String?) -> BenchRecorder? {
        let key = id ?? all.values.sorted { $0.started > $1.started }.first?.id
        guard let k = key, let b = all.removeValue(forKey: k) else { return nil }
        return b
    }
    static var running: [[String: Any]] { all.values.map { ["id": $0.id, "label": $0.label, "elapsed_seconds": Int($0.elapsed), "samples": $0.count] } }
}

/// `thermo bench [--label x] [--process name] [--interval 1] [--seconds N] [--json] [-- command args…]`
enum BenchCLI {
    static func run(_ rest: [String], json: Bool) -> Int32 {
        switch rest.first {
        case "list": return BenchStore.cliList(json: json)
        case "compare": return BenchStore.cliCompare(Array(rest.dropFirst()), json: json)
        case "show", "export": return BenchStore.cliShow(Array(rest.dropFirst()), json: json)
        default: break
        }
        func opt(_ n: String) -> String? { rest.firstIndex(of: n).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } }
        let cmd = rest.firstIndex(of: "--").map { Array(rest[($0 + 1)...]) } ?? []
        let seconds = Double(opt("--seconds") ?? "")
        guard !cmd.isEmpty || seconds != nil else {
            FileHandle.standardError.write(Data("""
            Usage: thermo bench [--label NAME] [--process NAME] -- <command…>
                   thermo bench --seconds 60          record while you run something yourself
                   thermo bench list                  saved runs
                   thermo bench compare [A] [B]       compare two runs (default: last two); --markdown for a PR table
                   thermo bench show [ID] --csv|--markdown|--json

            """.utf8))
            return 1
        }
        let label = opt("--label") ?? (cmd.isEmpty ? "\(Int(seconds!)) s recording" : cmd.joined(separator: " "))
        let rec = BenchRecorder(label: label, process: opt("--process"), interval: Double(opt("--interval") ?? "") ?? 1)
        Thread.sleep(forTimeInterval: 1.2)   // baseline sample before the load starts
        var code: Int32 = 0
        if cmd.isEmpty {
            if !json { FileHandle.standardError.write(Data("Recording for \(Int(seconds!)) s…\n".utf8)) }
            Thread.sleep(forTimeInterval: seconds!)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = cmd
            if json { p.standardOutput = FileHandle.standardError }   // keep stdout clean for the JSON report
            do { try p.run(); p.waitUntilExit(); code = p.terminationStatus }
            catch { FileHandle.standardError.write(Data("Couldn't run \(cmd[0]): \(error.localizedDescription)\n".utf8)); code = 127 }
        }
        var report = rec.stop()
        if !cmd.isEmpty { report["exit_code"] = Int(code) }
        BenchStore.save(report, series: rec.series)
        print(json ? Report.json(report) : "\n" + BenchRecorder.text(report))
        return code
    }
}

#endif
