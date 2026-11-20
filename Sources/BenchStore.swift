// Saved benchmark runs: ~/Library/Application Support/Thermo/benchmarks/<date>-<id>.json (last 200 kept).
// Lets people and agents compare runs (before/after a change) and export CSV or a Markdown table for PRs.

#if !NO_CONNECT

import Foundation

enum BenchStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Thermo/benchmarks")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    static func save(_ report: [String: Any], series: [[Any]]) -> URL? {
        var r = report
        r["series_columns"] = ["seconds", "cpu_percent", "gpu_percent", "hottest_c", "memory_used_gb", "process_cpu_percent"]
        r["series"] = series
        let stamp = (report["started_at"] as? String ?? "run").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp)-\(report["id"] as? String ?? UUID().uuidString.prefix(8).lowercased()).json")
        guard (try? Data(Report.json(r, pretty: false).utf8).write(to: url, options: .atomic)) != nil else { return nil }
        let all = files()
        if all.count > 200 { all.suffix(from: 200).forEach { try? FileManager.default.removeItem(at: $0) } }
        return url
    }

    /// Newest first.
    static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func load(_ u: URL) -> [String: Any]? { (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    static func list(limit: Int = 10) -> [[String: Any]] { files().prefix(max(1, limit)).compactMap(load) }

    /// Find by id (or id prefix) or exact label, newest match first.
    static func find(_ key: String) -> [String: Any]? {
        let k = key.lowercased()
        return files().lazy.compactMap(load).first { ($0["id"] as? String ?? "").hasPrefix(k) || ($0["label"] as? String ?? "").lowercased() == k }
    }

    /// (earlier, later). Defaults to the last two runs.
    static func pair(_ a: String?, _ b: String?) -> ([String: Any], [String: Any])? {
        let recent = list(limit: 2)
        guard let later = b.flatMap(find) ?? recent.first,
              let earlier = a.flatMap(find) ?? recent.first(where: { ($0["id"] as? String) != (later["id"] as? String) }) else { return nil }
        return (earlier, later)
    }

    static func brief(_ r: [String: Any]) -> [String: Any] {
        ["id": r["id"] ?? "", "label": r["label"] ?? "", "started_at": r["started_at"] ?? "", "summary": r["summary"] ?? ""]
    }

    // MARK: Compare

    private static func num(_ r: [String: Any], _ path: [String]) -> Double? {
        var cur: Any? = r
        for p in path { cur = (cur as? [String: Any])?[p] }
        return (cur as? NSNumber)?.doubleValue
    }

    /// name, path, unit, lower is better
    static let metrics: [(String, [String], String)] = [
        ("Duration", ["duration_seconds"], "s"),
        ("CPU avg", ["cpu_percent", "avg"], "%"), ("CPU peak", ["cpu_percent", "peak"], "%"),
        ("GPU avg", ["gpu_percent", "avg"], "%"), ("GPU peak", ["gpu_percent", "peak"], "%"),
        ("Peak temperature", ["temperature", "peak_c"], "°C"), ("Heat rise", ["temperature", "rise_c"], "°C"),
        ("Throttled", ["throttling", "seconds"], "s"),
        ("Memory peak", ["memory", "peak_used_gb"], " GB"),
        ("Process CPU avg", ["process", "cpu_percent", "avg"], "%"),
    ]

    static func compare(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var rows: [[String: Any]] = []
        for (name, path, unit) in metrics {
            guard let x = num(a, path), let y = num(b, path) else { continue }
            let d = y - x
            let rel = x != 0 ? d / x * 100 : 0
            rows.append(["metric": name, "a": BenchRecorder.n1(x), "b": BenchRecorder.n1(y), "change": BenchRecorder.n1(d),
                         "change_percent": BenchRecorder.n1(rel), "unit": unit.trimmingCharacters(in: .whitespaces), "better": d < 0 ? "b" : d > 0 ? "a" : "same"])
        }
        let la = a["label"] as? String ?? "A", lb = b["label"] as? String ?? "B"
        var verdict: [String] = []
        for r in rows where ["CPU avg", "Peak temperature", "Throttled", "Duration"].contains(r["metric"] as? String ?? "") {
            let d = (r["change"] as? NSNumber)?.doubleValue ?? 0
            if abs(d) >= 1 { let u = r["unit"] as? String ?? ""
                verdict.append("\((r["metric"] as! String).lowercased()) \(d > 0 ? "+" : "−")\(fmt(abs(d)))\(u == "%" ? " pts" : u)") }
        }
        return ["a": brief(a), "b": brief(b), "rows": rows,
                "summary": verdict.isEmpty ? "No meaningful difference between \(la) and \(lb)." : "\(lb) vs \(la): " + verdict.joined(separator: ", "),
                "markdown": markdown(rows, la, lb)]
    }

    private static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }

    static func markdown(_ rows: [[String: Any]], _ la: String, _ lb: String) -> String {
        var l = ["| Metric | \(la) | \(lb) | Change |", "|---|---:|---:|---:|"]
        for r in rows {
            let u = r["unit"] as? String ?? "", sp = u == "GB" ? " " : ""
            func v(_ k: String) -> String { fmt((r[k] as? NSNumber)?.doubleValue ?? 0) + sp + u }
            let d = (r["change"] as? NSNumber)?.doubleValue ?? 0, p = (r["change_percent"] as? NSNumber)?.doubleValue ?? 0
            let ch = d == 0 ? "–" : "\(d > 0 ? "+" : "−")\(fmt(abs(d)))\(sp)\(u == "%" ? " pts" : u)" + (u == "%" || u == "°C" ? "" : " (\(p > 0 ? "+" : "−")\(Int(abs(p).rounded()))%)")
            l.append("| \(r["metric"] as? String ?? "") | \(v("a")) | \(v("b")) | \(ch) |")
        }
        l.append("")
        l.append("<sub>Measured with [Thermo](https://github.com/simarpreetsingh-019/Thermo) · `thermo bench`</sub>")
        return l.joined(separator: "\n")
    }

    // MARK: CLI

    static func cliList(json: Bool) -> Int32 {
        let runs = list(limit: 20)
        if json { print(Report.json(["runs": runs.map(brief)])); return 0 }
        if runs.isEmpty { print("No saved benchmarks yet. Run: thermo bench -- <command>"); return 0 }
        for r in runs {
            let when = (r["started_at"] as? String ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
            print("\(r["id"] as? String ?? "")  \(when)  \(r["label"] as? String ?? "")\n          \(r["summary"] as? String ?? "")")
        }
        return 0
    }

    static func cliCompare(_ args: [String], json: Bool) -> Int32 {
        let pos = args.filter { !$0.hasPrefix("--") }
        guard let (a, b) = pair(pos.count > 1 ? pos[0] : nil, pos.last.flatMap { pos.count > 1 ? $0 : nil } ?? pos.first) else {
            print("Need two saved benchmarks. Run `thermo bench -- <command>` twice (e.g. before and after a change)."); return 1
        }
        let c = compare(a, b)
        if json { print(Report.json(c)) }
        else if args.contains("--markdown") { print(c["markdown"] as? String ?? "") }
        else {
            print("📊 \(c["summary"] as? String ?? "")\n")
            for r in c["rows"] as? [[String: Any]] ?? [] {
                let u = r["unit"] as? String ?? "", d = (r["change"] as? NSNumber)?.doubleValue ?? 0
                let arrow = d == 0 ? "  " : (r["better"] as? String == "b" ? "↓ " : "↑ ")
                print("  \((r["metric"] as? String ?? "").padding(toLength: 18, withPad: " ", startingAt: 0)) \(fmt((r["a"] as? NSNumber)?.doubleValue ?? 0))\(u) → \(fmt((r["b"] as? NSNumber)?.doubleValue ?? 0))\(u)  \(arrow)\(d > 0 ? "+" : d < 0 ? "−" : "")\(fmt(abs(d)))\(u == "%" ? " pts" : u)")
            }
            print("\n  A = \(a["label"] as? String ?? "") (\(a["id"] as? String ?? ""))\n  B = \(b["label"] as? String ?? "") (\(b["id"] as? String ?? ""))")
        }
        return 0
    }

    static func cliShow(_ args: [String], json: Bool) -> Int32 {
        guard let r = args.first(where: { !$0.hasPrefix("--") }).flatMap(find) ?? list(limit: 1).first else { print("No saved benchmarks yet."); return 1 }
        if args.contains("--csv") {
            print((r["series_columns"] as? [String] ?? []).joined(separator: ","))
            for row in r["series"] as? [[Any]] ?? [] { print(row.map { $0 is NSNull ? "" : "\($0)" }.joined(separator: ",")) }
        } else if args.contains("--markdown") {
            print("**\(r["label"] as? String ?? "Benchmark")**: \(r["summary"] as? String ?? "")\n")
            print(markdown(compare(r, r)["rows"] as? [[String: Any]] ?? [], "Run", "Run").components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: " | Run | Change |", with: " | Value |").replacingOccurrences(of: "|---|---:|---:|---:|", with: "|---|---:|") }
                .map { line -> String in   // keep metric + value columns only
                    let cols = line.split(separator: "|", omittingEmptySubsequences: false)
                    return cols.count >= 5 && !line.contains("Value") && !line.contains("---") ? "|\(cols[1])|\(cols[2])|" : line
                }.joined(separator: "\n"))
        } else {
            var o = r; o.removeValue(forKey: "series")
            print(json ? Report.json(o) : BenchRecorder.text(o))
        }
        return 0
    }
}

#endif
