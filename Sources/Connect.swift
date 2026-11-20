// 1.7: let other programs use Thermo's readings.
//   • `Thermo --cli <command> [--json]`  one-shot readings for scripts and people (wrapped by the `thermo` command)
//   • `Thermo --mcp`                     an MCP server over stdio, for AI agents (Claude, Codex, Cursor, …)
//   • Local HTTP API                     opt-in, read-only, 127.0.0.1 only, token required (while the app runs)
// All three return the same JSON shapes, built here.

#if !NO_CONNECT   // `./build.sh --no-connect` leaves this whole file out

import AppKit
import Foundation
import Network

// MARK: - One reading of everything

struct Reading {
    var snap: Snapshot
    var apps: [AppUsage]
    var battery: BatteryInfo
    var advice: ThermalAdvice
    var mem: MemoryAdvice

    init(snap: Snapshot, apps: [AppUsage], battery: BatteryInfo, advice: ThermalAdvice? = nil) {
        self.snap = snap; self.apps = apps; self.battery = battery
        self.advice = advice ?? Advisor.advise(snap, apps: apps, history: [])
        self.mem = MemoryAdvisor.advise(snap, apps: apps)
    }
}

/// Takes readings without the app running (CLI and MCP). CPU % needs two samples, so it warms up once.
final class Probe {
    private let sampler = Sampler()
    private let procs = ProcSampler()
    private var lastApps: [AppUsage] = []

    init() { _ = sampler.sample(); _ = procs.sample(); usleep(800_000) }

    func read(processes: Bool = true) -> Reading {
        let s = sampler.sample()
        if processes { lastApps = procs.sample() }
        return Reading(snap: s, apps: lastApps, battery: .read())
    }
}

/// Whether app names and project folders may be shared with other programs (⚙ menu).
enum Sharing {
    static var processes: Bool {
        get { UserDefaults.standard.object(forKey: "shareProcesses") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shareProcesses") }
    }
}

// MARK: - JSON reports

enum Report {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private static func r1(_ v: Double?) -> Any { v.map { NSDecimalNumber(string: String(format: "%.1f", $0)) as Any } ?? NSNull() }
    private static func gbN(_ b: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", b / 1_073_741_824)) }
    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private static func heatName(_ l: HeatLevel) -> String { ["cool", "warm", "hot", "very_hot"][l.rawValue] }
    private static func stateName(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "unknown" }
    }
    private static func pressureName(_ p: MemPressure) -> String { ["normal", "tight", "critical"][p == .normal ? 0 : p == .warning ? 1 : 2] }

    static func status(_ r: Reading) -> [String: Any] {
        let s = r.snap, h = healthSummary(advice: r.advice, mem: r.mem, apps: r.apps)
        return [
            "thermo_version": version,
            "timestamp": iso(Date()),
            "health": ["level": ["good", "attention", "problem"][h.level], "summary": h.text],
            "cpu": ["percent": r1(s.cpu)],
            "gpu": ["percent": r1(s.gpu)],
            "memory": ["used_gb": gbN(s.ramUsed), "total_gb": gbN(s.ramTotal), "available_gb": gbN(max(s.ramTotal - s.ramUsed, 0)),
                       "percent": r1(s.ramPct), "swap_gb": gbN(s.swap), "pressure": pressureName(s.memPressure)],
            "thermal": ["hottest_c": r1(s.hottest), "cpu_c": r1(s.cpuTemp), "gpu_c": r1(s.gpuTemp),
                        "level": heatName(r.advice.level), "macos_thermal_state": stateName(s.thermalState),
                        "throttling": s.thermalState == .serious || s.thermalState == .critical],
            "battery": r.battery.present ? battery(r) : NSNull(),
        ]
    }

    static func temperatures(_ r: Reading) -> [String: Any] {
        ["hottest_c": r1(r.snap.hottest),
         "level": heatName(r.advice.level),
         "parts": r.snap.parts.map { p -> [String: Any] in
            ["name": p.id, "celsius": r1(p.value), "status": p.value >= p.hot ? "hot" : p.value >= p.warm ? "warm" : "ok",
             "warm_at_c": p.warm, "hot_at_c": p.hot, "sensors": p.sensors]
         }]
    }

    static func processes(_ r: Reading, limit: Int = 8, sortBy: String = "cpu") -> [String: Any] {
        guard Sharing.processes else {
            return ["shared": false, "processes": [], "note": "The user turned off sharing app names in Thermo (⚙ → Share app names with other tools)."]
        }
        let sorted = r.apps.sorted { sortBy == "memory" ? $0.mem > $1.mem : $0.cpu > $1.cpu }
        return ["shared": true, "sort_by": sortBy == "memory" ? "memory" : "cpu",
                "processes": sorted.prefix(max(1, min(limit, 50))).map(proc)]
    }

    private static func proc(_ a: AppUsage) -> [String: Any] {
        ["name": a.name, "project": a.project ?? NSNull(), "pid": Int(a.mainPID), "processes": a.pids.count,
         "cpu_percent": r1(a.cpu), "memory_mb": Int(a.mem / 1_048_576), "is_app": a.isApp]
    }

    static func battery(_ r: Reading) -> [String: Any] {
        let b = r.battery
        guard b.present else { return ["present": false] }
        return ["present": true, "percent": r1(b.percent), "charging": b.charging, "plugged_in": b.plugged, "fully_charged": b.full,
                "health_percent": r1(b.health), "condition": b.condition, "cycles": b.cycles, "design_cycles": b.designCycles,
                "capacity_mah": b.maxCap, "design_capacity_mah": b.designCap, "watts": r1(b.watts),
                "minutes_left": b.minutesLeft ?? NSNull(), "temperature_c": r1(r.snap.batteryTemp)]
    }

    static func history(range: String) -> [String: Any] {
        let h = History.shared
        let mins = range == "24h" ? 1440 : 60
        let cutoff = Int(Date().timeIntervalSince1970 / 60) - mins
        let pts = h.points.filter { $0.t > cutoff }
        func stats(_ v: [Float]) -> Any { v.isEmpty ? NSNull() : ["avg": r1(Double(v.reduce(0, +) / Float(v.count))), "peak": r1(Double(v.max()!))] as [String: Any] }
        return ["range": mins == 60 ? "1h" : "24h", "minutes_with_data": pts.count,
                "summary": ["cpu_percent": stats(pts.map(\.cpu)), "memory_percent": stats(pts.map(\.ram)),
                            "gpu_percent": stats(pts.map(\.gpu)), "hottest_c": stats(pts.compactMap(\.temp))],
                "points": pts.map { p -> [String: Any] in
                    ["time": iso(Date(timeIntervalSince1970: Double(p.t * 60))), "cpu_percent": r1(Double(p.cpu)), "memory_percent": r1(Double(p.ram)),
                     "gpu_percent": r1(Double(p.gpu)), "hottest_c": r1(p.temp.map(Double.init)), "battery_percent": r1(p.battery.map(Double.init))]
                },
                "battery_health_log": h.healthLog.map { ["date": iso($0.date), "health_percent": r1($0.health), "cycles": $0.cycles] }]
    }

    /// "Can I start a heavy job now?" → go / wait / no, with reasons and what to close.
    static func headroom(_ r: Reading, kind: String = "any", memoryGB: Double = 0) -> [String: Any] {
        let s = r.snap
        var verdict = 0                 // 0 go, 1 wait, 2 no
        var reasons: [String] = [], tips: [String] = []
        func flag(_ v: Int, _ why: String) { verdict = max(verdict, v); reasons.append(why) }

        // Heat matters for every kind of heavy job.
        if s.thermalState == .critical || r.advice.level == .critical { flag(1, "The Mac is very hot (\(Int(s.hottest ?? 0))°C) and macOS is throttling it heavily.") }
        else if s.thermalState == .serious || r.advice.level == .hot { flag(1, "The Mac is hot (\(Int(s.hottest ?? 0))°C); a heavy job now would run slower.") }
        if kind == "gpu" || kind == "any", let g = s.gpu, g >= 85 { flag(1, "The GPU is already \(Int(g))% busy.") }
        if kind == "cpu" || kind == "any", s.cpu >= 85 { flag(1, "The CPU is already \(Int(s.cpu))% busy.") }
        if kind == "memory" || kind == "gpu" || kind == "any" {   // Apple Silicon GPUs share system memory
            let avail = max(s.ramTotal - s.ramUsed, 0) / 1_073_741_824
            if s.memPressure == .critical { flag(2, "Memory is critically low; macOS is swapping heavily.") }
            else if s.memPressure == .warning { flag(1, "Memory is tight (macOS is compressing memory).") }
            if memoryGB > 0 {
                let freeable = r.mem.freeable / 1_073_741_824
                if memoryGB > avail + freeable { flag(2, String(format: "The job needs %.1f GB but only %.1f GB is free, even after closing big apps.", memoryGB, avail)) }
                else if memoryGB > avail { flag(1, String(format: "The job needs %.1f GB but only %.1f GB is free right now.", memoryGB, avail)) }
            }
        }
        if verdict > 0 {
            if r.advice.level >= .hot { tips.append("Wait for it to cool below about 70°C (use wait_until_cool / `thermo wait-cool`).") }
            if let c = (r.advice.culprits.first ?? r.mem.suggestions.first), Sharing.processes {
                tips.append("Closing \(c.name) would help (\(Int(c.cpu))% CPU, \(Int(c.mem / 1_048_576)) MB).")
            }
        }
        let names = ["go", "wait", "no"]
        let advice = verdict == 0 ? "Good to go: the Mac has room for a heavy \(kind == "any" ? "" : kind + " ")job."
            : (verdict == 1 ? "Better to wait: " : "Not now: ") + reasons.joined(separator: " ")
        let suggest = Sharing.processes && verdict > 0 ? Array(Set((r.advice.culprits + r.mem.suggestions).map(\.id)))
            .compactMap { id in r.apps.first { $0.id == id } }.sorted { $0.cpu > $1.cpu }.prefix(3).map(proc) : []
        return ["verdict": names[verdict], "ok": verdict == 0, "kind": kind, "advice": advice, "reasons": reasons, "tips": tips,
                "close_candidates": suggest,
                "now": ["cpu_percent": r1(s.cpu), "gpu_percent": r1(s.gpu), "memory_available_gb": gbN(max(s.ramTotal - s.ramUsed, 0)),
                        "memory_pressure": pressureName(s.memPressure), "hottest_c": r1(s.hottest)]]
    }

    static func json(_ o: Any, pretty: Bool = true) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Command line: `Thermo --cli <command> [options] [--json]`

enum CLI {
    /// Returns an exit code when Thermo was started as a command-line tool, nil to start the app normally.
    static func run(_ args: [String]) -> Int32? {
        if args.contains("--mcp") { MCPServer.serve(); return 0 }
        guard let i = args.firstIndex(of: "--cli") else { return nil }
        let rest = Array(args.dropFirst(i + 1))
        let cmd = rest.first ?? "status", json = rest.contains("--json")
        func opt(_ name: String) -> String? { rest.firstIndex(of: name).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } }
        func out(_ o: [String: Any], _ text: () -> String) { print(json ? Report.json(o) : text()) }

        switch cmd {
        case "status":
            let r = Probe().read(); out(Report.status(r)) { Text.status(r) }
        case "temps", "temperatures":
            let r = Probe().read(processes: false); out(Report.temperatures(r)) { Text.temps(r) }
        case "apps", "processes":
            let r = Probe().read()
            let o = Report.processes(r, limit: Int(opt("--limit") ?? "") ?? 8, sortBy: opt("--sort") ?? "cpu")
            out(o) { Text.processes(o) }
        case "battery":
            let r = Probe().read(processes: false); out(Report.battery(r)) { Text.battery(r) }
        case "history":
            let o = Report.history(range: opt("--range") ?? "1h"); out(o) { Text.history(o) }
        case "headroom":
            let r = Probe().read()
            let o = Report.headroom(r, kind: opt("--kind") ?? "any", memoryGB: Double(opt("--memory-gb") ?? "") ?? 0)
            out(o) { Text.headroom(o) }
            return ["go": 0, "wait": 3, "no": 4][o["verdict"] as? String ?? "go"] ?? 0
        case "wait-cool":
            let o = waitUntilCool(target: Double(opt("--target") ?? "") ?? 70, timeout: Double(opt("--timeout") ?? "") ?? 600) { t in
                if !json { print("  \(Int(t))°C…") }
            }
            out(o) { (o["cooled"] as? Bool == true ? "✓ " : "✗ ") + (o["message"] as? String ?? "") }
            return o["cooled"] as? Bool == true ? 0 : 3
        case "bench", "benchmark":
            return BenchCLI.run(Array(rest.dropFirst()), json: json)
        case "api":
            print(LocalAPI.infoText()); return 0
        default:
            FileHandle.standardError.write(Data("Unknown command: \(cmd)\n".utf8)); return 1
        }
        return 0
    }

    static func waitUntilCool(target: Double, timeout: Double, progress: (Double) -> Void = { _ in }) -> [String: Any] {
        let probe = Probe(), start = Date()
        let limit = min(max(timeout, 5), 3600)
        var last = 0.0, ticks = 0
        while true {
            let s = probe.read(processes: false).snap
            last = s.hottest ?? 0
            if last <= target && s.thermalState != .serious && s.thermalState != .critical {
                return ["cooled": true, "hottest_c": Int(last.rounded()), "waited_seconds": Int(Date().timeIntervalSince(start)),
                        "message": "Cooled to \(Int(last))°C (target \(Int(target))°C) after \(Int(Date().timeIntervalSince(start)))s."]
            }
            if Date().timeIntervalSince(start) >= limit {
                return ["cooled": false, "hottest_c": Int(last.rounded()), "waited_seconds": Int(limit),
                        "message": "Still \(Int(last))°C after \(Int(limit))s (target \(Int(target))°C). Closing busy apps would help."]
            }
            if ticks % 5 == 0 { progress(last) }
            ticks += 1
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Plain-text versions for people.
    enum Text {
        static func status(_ r: Reading) -> String {
            let s = r.snap, h = healthSummary(advice: r.advice, mem: r.mem, apps: r.apps)
            var l = ["\(["✅", "⚠️", "🔴"][h.level]) \(h.text)", "",
                     "  CPU     \(Int(s.cpu))%",
                     "  GPU     \(s.gpu.map { "\(Int($0))%" } ?? "n/a")",
                     "  Memory  \(gb(s.ramUsed)) of \(gb(s.ramTotal)) · pressure \(s.memPressure.title.lowercased())\(s.swap > 0 ? " · swap \(gb(s.swap))" : "")",
                     "  Heat    \(s.hottest.map { "\(Int($0))°C" } ?? "n/a") · \(r.advice.level.title.lowercased())"]
            if r.battery.present { l.append("  Battery \(Int(r.battery.percent))% · health \(Int(r.battery.health.rounded()))%") }
            return l.joined(separator: "\n")
        }
        static func temps(_ r: Reading) -> String {
            guard !r.snap.parts.isEmpty else { return "No temperature sensors found on this Mac." }
            return r.snap.parts.map { p in
                let mark = p.value >= p.hot ? "🔴" : p.value >= p.warm ? "🟠" : "🟢"
                return "\(mark) \(p.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(Int(p.value.rounded()))°C"
            }.joined(separator: "\n")
        }
        static func processes(_ o: [String: Any]) -> String {
            guard o["shared"] as? Bool == true else { return o["note"] as? String ?? "" }
            let rows = (o["processes"] as? [[String: Any]] ?? []).map { p -> String in
                let name = (p["name"] as? String ?? "") + ((p["project"] as? String).map { " (\($0))" } ?? "")
                return "\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%6.1f%%", (p["cpu_percent"] as? NSNumber)?.doubleValue ?? 0))  \(p["memory_mb"] as? Int ?? 0) MB"
            }
            return (["NAME".padding(toLength: 34, withPad: " ", startingAt: 0) + "    CPU  MEMORY"] + rows).joined(separator: "\n")
        }
        static func battery(_ r: Reading) -> String {
            let b = r.battery
            guard b.present else { return "No battery (this Mac runs on mains power)." }
            return """
            🔋 \(Int(b.percent))% · \(b.charging ? "charging" : b.plugged ? "plugged in" : "on battery")\(b.minutesLeft.map { " · \(duration($0)) \(b.charging ? "to full" : "left")" } ?? "")
               Health \(Int(b.health.rounded()))% (\(b.condition)) · \(b.cycles) of \(b.designCycles) cycles · \(b.maxCap) of \(b.designCap) mAh
               \(abs(b.watts) < 0.5 ? "Not drawing from the battery" : (b.watts > 0 ? "Charging at " : "Using ") + String(format: "%.1f W", abs(b.watts)))
            """
        }
        static func history(_ o: [String: Any]) -> String {
            let s = o["summary"] as? [String: Any] ?? [:]
            func line(_ k: String, _ label: String, _ unit: String) -> String {
                guard let v = s[k] as? [String: Any] else { return "  \(label) no data yet" }
                return "  \(label) avg \(Int((v["avg"] as? NSNumber)?.doubleValue ?? 0))\(unit) · peak \(Int((v["peak"] as? NSNumber)?.doubleValue ?? 0))\(unit)"
            }
            return ["Last \(o["range"] as? String ?? "") (\(o["minutes_with_data"] as? Int ?? 0) minutes recorded)",
                    line("cpu_percent", "CPU    ", "%"), line("memory_percent", "Memory ", "%"),
                    line("gpu_percent", "GPU    ", "%"), line("hottest_c", "Heat   ", "°C")].joined(separator: "\n")
        }
        static func headroom(_ o: [String: Any]) -> String {
            let v = o["verdict"] as? String ?? "go"
            var l = ["\(["go": "✅ GO", "wait": "⏳ WAIT", "no": "⛔ NO"][v] ?? v): \(o["advice"] as? String ?? "")"]
            l += (o["tips"] as? [String] ?? []).map { "   • \($0)" }
            return l.joined(separator: "\n")
        }
    }
}

// MARK: - MCP server (JSON-RPC 2.0 over stdio, one message per line)

enum MCPServer {
    static let tools: [[String: Any]] = [
        tool("get_status", "Current Mac load and health: CPU %, GPU %, memory use and pressure, hottest temperature, thermal throttling, battery, and a one-line summary.", [:]),
        tool("get_temperatures", "Temperature of each component: CPU performance and efficiency cores, GPU, memory, SSD, battery, Wi-Fi, palm rest, with ok/warm/hot status.", [:]),
        tool("get_top_processes", "Apps and processes using the most CPU or memory right now (app names, project folders for dev tools, CPU %, MB).", [
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 8],
            "sort_by": ["type": "string", "enum": ["cpu", "memory"], "default": "cpu"]]),
        tool("get_battery", "Battery health % and condition, cycle count, charge %, charging state, watts in/out, time left.", [:]),
        tool("get_history", "Per-minute history of CPU, memory, GPU, temperature and battery for the last 1 or 24 hours, with averages and peaks, plus the daily battery-health log.", [
            "range": ["type": "string", "enum": ["1h", "24h"], "default": "1h"]]),
        tool("check_headroom", "Before starting a heavy job (ML training, builds, renders, video export, large models): is there room right now? Returns verdict go / wait / no, the reasons, and which apps to close.", [
            "kind": ["type": "string", "enum": ["any", "gpu", "cpu", "memory"], "default": "any", "description": "Which resource the job leans on."],
            "memory_gb": ["type": "number", "minimum": 0, "description": "Memory the job needs, in GB (optional)."]]),
        tool("start_benchmark", "Start recording CPU, GPU, memory and every temperature (about once a second) before running a test, build, benchmark or app you want to measure. Returns an id; run the workload, then call stop_benchmark.", [
            "label": ["type": "string", "description": "Name for this run, e.g. 'pytest' or 'render 4K'."],
            "process": ["type": "string", "description": "Optional app/process name (or project folder) to track separately, e.g. 'python' or 'node'."],
            "interval_seconds": ["type": "number", "minimum": 0.5, "maximum": 10, "default": 1]]),
        tool("stop_benchmark", "Stop a recording and get the load report: CPU/GPU avg, p95 and peak, memory peak and swap growth, temperature start→peak (overall and per part), throttling time, and the tracked process's usage.", [
            "id": ["type": "string", "description": "The id from start_benchmark (defaults to the most recent)."]]),
        tool("list_benchmarks", "List saved benchmark runs (newest first) with id, label, date and summary.", [
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10]]),
        tool("compare_benchmarks", "Compare two saved benchmark runs (default: the last two), e.g. before and after a code change. Returns each metric for both runs, the change, and a Markdown table ready for a pull request.", [
            "a": ["type": "string", "description": "Earlier run: id or label (default: second newest)."],
            "b": ["type": "string", "description": "Later run: id or label (default: newest)."]]),
        tool("wait_until_cool", "Wait until the Mac cools to a target temperature (or the timeout passes) before continuing a heavy job.", [
            "target_celsius": ["type": "number", "minimum": 40, "maximum": 100, "default": 70],
            "timeout_seconds": ["type": "number", "minimum": 5, "maximum": 1800, "default": 300]]),
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    static func serve() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var probe: Probe?   // created on first tool call, so `initialize` answers instantly
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            guard let id = msg["id"] else { continue }   // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch msg["method"] as? String ?? "" {
            case "initialize":
                reply["result"] = [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "thermo", "title": "Thermo", "version": Report.version],
                    "instructions": "Thermo measures Mac load and heat. To benchmark a test, build or app: call start_benchmark, run the workload, then stop_benchmark for CPU/GPU/memory/temperature averages, peaks, temperature rise and throttling. Before heavy work, call check_headroom (and wait_until_cool if it says wait). All tools are read-only.",
                ]
            case "ping": reply["result"] = [String: Any]()
            case "tools/list": reply["result"] = ["tools": tools]
            case "tools/call":
                let name = params["name"] as? String ?? "", a = params["arguments"] as? [String: Any] ?? [:]
                if probe == nil { probe = Probe() }
                if let out = call(name, a, probe!) {
                    reply["result"] = ["content": [["type": "text", "text": Report.json(out)]], "structuredContent": out, "isError": false]
                } else {
                    reply["error"] = ["code": -32602, "message": "Unknown tool: \(name)"]
                }
            default:
                reply["error"] = ["code": -32601, "message": "Method not found"]
            }
            print(Report.json(reply, pretty: false))
        }
    }

    private static func call(_ name: String, _ a: [String: Any], _ p: Probe) -> [String: Any]? {
        func num(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        switch name {
        case "get_status": return Report.status(p.read())
        case "get_temperatures": return Report.temperatures(p.read(processes: false))
        case "get_top_processes": return Report.processes(p.read(), limit: Int(num("limit") ?? 8), sortBy: a["sort_by"] as? String ?? "cpu")
        case "get_battery": return Report.battery(p.read(processes: false))
        case "get_history": History.shared.reload(); return Report.history(range: a["range"] as? String ?? "1h")
        case "check_headroom": return Report.headroom(p.read(), kind: a["kind"] as? String ?? "any", memoryGB: num("memory_gb") ?? 0)
        case "start_benchmark":
            let b = Benchmarks.start(label: a["label"] as? String ?? "benchmark", process: a["process"] as? String, interval: num("interval_seconds") ?? 1)
            return ["id": b.id, "label": b.label, "recording": true, "next": "Run the workload now, then call stop_benchmark with this id.", "also_running": Benchmarks.running.filter { $0["id"] as? String != b.id }]
        case "stop_benchmark":
            guard let b = Benchmarks.stop(a["id"] as? String) else { return ["error": "No running benchmark with that id. Call start_benchmark first."] }
            let r = b.stop()
            BenchStore.save(r, series: b.series)
            return r
        case "list_benchmarks":
            return ["runs": BenchStore.list(limit: Int(num("limit") ?? 10)).map(BenchStore.brief)]
        case "compare_benchmarks":
            guard let (x, y) = BenchStore.pair(a["a"] as? String, a["b"] as? String) else { return ["error": "Need two saved benchmarks. Run start_benchmark/stop_benchmark twice first."] }
            return BenchStore.compare(x, y)
        case "wait_until_cool": return CLI.waitUntilCool(target: num("target_celsius") ?? 70, timeout: min(num("timeout_seconds") ?? 300, 1800))
        default: return nil
        }
    }
}

// MARK: - `thermo` Terminal command for people who didn't use Homebrew

/// Links the bundled `thermo` script into /usr/local/bin (on the default PATH). macOS asks for an admin
/// password, like VS Code's "Install 'code' command". Homebrew installs it automatically instead.
enum CommandInstaller {
    static let link = "/usr/local/bin/thermo"
    static var installed: Bool { ["/usr/local/bin/thermo", "/opt/homebrew/bin/thermo"].contains { FileManager.default.fileExists(atPath: $0) } }

    static func install() {
        let src = Bundle.main.bundlePath + "/Contents/Resources/thermo"
        guard FileManager.default.fileExists(atPath: src), !src.contains("'"), !src.contains("\"") else { NSSound.beep(); return }
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(src)' \(link)\" with administrator privileges")?.executeAndReturnError(&err)
        if err == nil {
            Toasts.shared.show(ToastContent(icon: "terminal.fill", tint: .mint, title: "thermo command installed",
                subtitle: "Open a new Terminal window and try: thermo status · thermo temps · thermo help", autoHide: 15, keepInInbox: false))
        }
    }
}

// MARK: - Local HTTP API (opt-in, while the app runs)

/// Read-only JSON over http://127.0.0.1:47615. Every data request needs the token from
/// ~/Library/Application Support/Thermo/api.json (readable only by this user). Requests from web pages
/// (an Origin header) and foreign Host names are refused, so websites can't read your stats.
final class LocalAPI: ObservableObject {
    static let shared = LocalAPI()
    static let port: UInt16 = 47615
    weak var monitor: Monitor?
    @Published private(set) var running = false
    @Published private(set) var problem: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "thermo.api")

    static var infoFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Thermo/api.json")
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "apiEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "apiEnabled"); newValue ? start() : stop() }
    }

    var token: String {
        if let t = UserDefaults.standard.string(forKey: "apiToken"), t.count == 64 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(t, forKey: "apiToken")
        return t
    }

    func resetToken() {
        UserDefaults.standard.removeObject(forKey: "apiToken")
        if running { writeInfo() }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.running = true; self?.problem = nil; self?.writeInfo()
                    case .failed(let e): self?.running = false; self?.problem = "Port \(Self.port) unavailable: \(e.localizedDescription)"; self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch { problem = error.localizedDescription }
    }

    func stop() {
        listener?.cancel(); listener = nil; running = false
        try? FileManager.default.removeItem(at: Self.infoFile)
    }

    private func writeInfo() {
        let info: [String: Any] = ["url": "http://127.0.0.1:\(Self.port)", "token": token, "version": Report.version,
                                   "docs": "https://simarpreetsingh-019.github.io/Thermo/agents.html#api"]
        let f = Self.infoFile
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: f.path, contents: Data(Report.json(info).utf8), attributes: [.posixPermissions: 0o600])
    }

    static func infoText() -> String {
        if let d = try? Data(contentsOf: infoFile), let s = String(data: d, encoding: .utf8) { return s }
        return "The local API is off. Turn it on in Thermo: ⚙ → Connections → Local API for other apps."
    }

    // Minimal HTTP/1.1: one GET per connection.
    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        var buf = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
                guard let self else { c.cancel(); return }
                if let data { buf.append(data) }
                if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(c, String(decoding: buf[..<end.lowerBound], as: UTF8.self))
                } else if done || err != nil || buf.count > 16_384 { c.cancel() }
                else { receive() }
            }
        }
        receive()
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        func send(_ code: Int, _ body: [String: Any]) {
            let text = ["200": "OK", "400": "Bad Request", "401": "Unauthorized", "403": "Forbidden", "404": "Not Found", "405": "Method Not Allowed"]["\(code)"] ?? "OK"
            let b = Data(Report.json(body).utf8)
            let h = "HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(b.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8) + b, completion: .contentProcessed { _ in c.cancel() })
        }
        guard parts.count >= 2 else { return send(400, ["error": "bad request"]) }
        guard parts[0] == "GET" else { return send(405, ["error": "read-only API: GET only"]) }
        let host = headers["host"] ?? ""
        guard ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"].contains(host) else { return send(403, ["error": "bad Host header"]) }
        guard headers["origin"] == nil else { return send(403, ["error": "requests from web pages are not allowed"]) }

        let comps = URLComponents(string: String(parts[1]))
        let path = comps?.path ?? "/"
        let q = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if path == "/" || path == "/v1" {
            return send(200, ["thermo": true, "version": Report.version, "auth": "Authorization: Bearer <token from ~/Library/Application Support/Thermo/api.json>",
                              "endpoints": ["/v1/status", "/v1/temperatures", "/v1/processes?limit=8&sort=cpu|memory", "/v1/battery",
                                            "/v1/history?range=1h|24h", "/v1/headroom?kind=any|gpu|cpu|memory&memory_gb=8"]])
        }
        let auth = headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? headers["x-thermo-token"]
        guard let auth, auth == token else { return send(401, ["error": "missing or wrong token (see ~/Library/Application Support/Thermo/api.json)"]) }

        DispatchQueue.main.async { [weak self] in
            guard let m = self?.monitor else { return send(404, ["error": "not ready"]) }
            let r = Reading(snap: m.snap, apps: m.apps, battery: m.battery, advice: m.advice)
            switch path {
            case "/v1/status": send(200, Report.status(r))
            case "/v1/temperatures": send(200, Report.temperatures(r))
            case "/v1/processes": send(200, Report.processes(r, limit: Int(q["limit"] ?? "") ?? 8, sortBy: q["sort"] ?? "cpu"))
            case "/v1/battery": send(200, Report.battery(r))
            case "/v1/history": send(200, Report.history(range: q["range"] ?? "1h"))
            case "/v1/headroom": send(200, Report.headroom(r, kind: q["kind"] ?? "any", memoryGB: Double(q["memory_gb"] ?? "") ?? 0))
            default: send(404, ["error": "unknown endpoint", "see": "/v1"])
            }
        }
    }
}

#endif
