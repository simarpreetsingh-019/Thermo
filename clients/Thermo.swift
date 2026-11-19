// Thermo client for Swift (macOS 13+). Copy this file into your app; Foundation only.
//
//   let t = ThermoClient()
//   let h = try await t.headroom(kind: "gpu", memoryGB: 8)
//   if h["verdict"] as? String != "go" { _ = try await t.waitUntilCool(target: 70) }
//
// Uses Thermo's local API when it's on, otherwise the Thermo app's command line. Same JSON either way.
// A sandboxed app can't read the token file or run other apps: use a non-sandboxed helper, or ask the
// user to paste the token (⚙ → Connections → Copy API token). Docs: https://simarpreetsingh-019.github.io/Thermo/
import Foundation

struct ThermoClient {
    typealias JSON = [String: Any]
    var appPath = ["/Applications/Thermo.app", NSHomeDirectory() + "/Applications/Thermo.app"]
        .first { FileManager.default.fileExists(atPath: $0 + "/Contents/MacOS/Thermo") }
    var token: String? = nil   // set this if you can't read api.json

    func status() async throws -> JSON { try await get("/v1/status", ["status"]) }
    func temperatures() async throws -> JSON { try await get("/v1/temperatures", ["temps"]) }
    func battery() async throws -> JSON { try await get("/v1/battery", ["battery"]) }
    func processes(limit: Int = 8, sort: String = "cpu") async throws -> JSON {
        try await get("/v1/processes?limit=\(limit)&sort=\(sort)", ["apps", "--limit", "\(limit)", "--sort", sort])
    }
    func history(range: String = "1h") async throws -> JSON { try await get("/v1/history?range=\(range)", ["history", "--range", range]) }
    /// ["verdict": "go" | "wait" | "no", "advice": …, "reasons": […], …]
    func headroom(kind: String = "any", memoryGB: Double = 0) async throws -> JSON {
        try await get("/v1/headroom?kind=\(kind)&memory_gb=\(memoryGB)", ["headroom", "--kind", kind, "--memory-gb", "\(memoryGB)"])
    }
    func waitUntilCool(target: Double = 70, timeout: Double = 600) async throws -> JSON {
        try cli(["wait-cool", "--target", "\(target)", "--timeout", "\(timeout)"])
    }

    private func get(_ path: String, _ args: [String]) async throws -> JSON {
        if let j = await api(path) { return j }
        return try cli(args)
    }

    private func api(_ path: String) async -> JSON? {
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Thermo/api.json")
        let info = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        guard let base = info?["url"] ?? (token != nil ? "http://127.0.0.1:47615" : nil),
              let tok = token ?? info?["token"], let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? JSON
    }

    private func cli(_ args: [String]) throws -> JSON {
        guard let app = appPath else { throw NSError(domain: "Thermo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Thermo.app not found"]) }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: app + "/Contents/MacOS/Thermo")
        p.arguments = ["--cli"] + args + ["--json"]
        p.standardOutput = pipe
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try JSONSerialization.jsonObject(with: d)) as? JSON ?? [:]
    }
}
