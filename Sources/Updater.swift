// Self-updater: checks GitHub Releases once a day, and on request downloads the new Thermo.zip,
// verifies its SHA-256 against the checksum file published with the release, checks the bundle,
// then swaps the app in place and relaunches.

import AppKit
import CryptoKit

struct Release {
    let version: String
    let notes: String
    let zipURL: URL
    let shaURL: URL
    let pageURL: URL
}

final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "simarpreetsingh-019/Thermo"
    static let bundleID = "local.thermo"

    @Published var available: Release?
    @Published var status: String?          // progress / error text shown in the UI
    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") } }
    private var timer: Timer?

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.scheduledCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.scheduledCheck() }
        timer?.tolerance = 600
    }

    private func scheduledCheck() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 20 * 3600 { check(userInitiated: false) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(userInitiated: Bool, then done: ((Release?) -> Void)? = nil) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Thermo-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        if userInitiated { status = "Checking for updates…" }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            var found: Release?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
               let assets = json["assets"] as? [[String: Any]] {
                let url = { (name: String) in
                    assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String
                }
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if let z = url("Thermo.zip").flatMap(URL.init(string:)),
                   let s = url("Thermo.zip.sha256").flatMap(URL.init(string:)),
                   z.host == "github.com", s.host == "github.com",
                   Self.isNewer(v, than: self.current) {
                    found = Release(version: v, notes: json["body"] as? String ?? "", zipURL: z, shaURL: s, pageURL: page)
                }
            }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                self.available = found
                done?(found)
                // Announce each new version once with a small notification card.
                if let f = found, done == nil, UserDefaults.standard.string(forKey: "notifiedVersion") != f.version || userInitiated {
                    UserDefaults.standard.set(f.version, forKey: "notifiedVersion")
                    Toasts.shared.updateAvailable(f)
                }
                if userInitiated {
                    self.status = error != nil ? "Couldn't reach GitHub. Try again later."
                        : found == nil ? "You're on the latest version (\(self.current))." : nil
                    if found == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.status = nil } }
                }
            }
        }.resume()
    }

    /// Ask, then download → verify → replace → relaunch.
    func promptInstall() {
        guard let r = available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Thermo \(r.version) is available"
        let notes = r.notes.count > 600 ? String(r.notes.prefix(600)) + "…" : r.notes
        alert.informativeText = "You have \(current).\n\n\(notes)"
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release page")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.pageURL)
        default: break
        }
    }

    /// First launch → welcome card; first launch after an update → "what's new" card for this version.
    func announceLaunch() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "lastSeenVersion")
        d.set(current, forKey: "lastSeenVersion")
        if last == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Toasts.shared.welcome() }
        } else if last != current {
            fetchNotes(for: current) { notes in Toasts.shared.whatsNew(version: self.current, notes: notes) }
        }
    }

    func fetchNotes(for version: String, _ done: @escaping (String) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/tags/v\(version)")!)
        req.setValue("Thermo-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["body"] as? String ?? ""
            DispatchQueue.main.async { done(body) }
        }.resume()
    }

    /// `Thermo --update-now`: check and install without prompting (used from the command line / for testing).
    func updateNow() {
        check(userInitiated: true) { [weak self] r in
            if let r { self?.install(r) } else { print(self?.status ?? "No update"); NSApp.terminate(nil) }
        }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.status = "Update failed: \(msg)"; NSLog("Thermo update failed: %@", msg) }
    }

    private func install(_ r: Release) {
        status = "Downloading \(r.version)…"
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            fail("no permission to replace \(target.path). Download it from the release page instead.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let shaText = try String(contentsOf: r.shaURL, encoding: .utf8)
                guard let expected = shaText.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased(),
                      expected.count == 64 else { return self.fail("invalid checksum file") }
                let zip = try Data(contentsOf: r.zipURL)
                let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { return self.fail("checksum mismatch — download rejected") }

                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zipFile = tmp.appendingPathComponent("Thermo.zip")
                try zip.write(to: zipFile)
                guard Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, tmp.path]) == 0 else { return self.fail("couldn't unzip") }
                let newApp = tmp.appendingPathComponent("Thermo.app")
                guard Bundle(url: newApp)?.bundleIdentifier == Self.bundleID,
                      Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0
                else { return self.fail("downloaded app failed verification") }

                // Swap after we quit, then relaunch. Paths are passed as arguments, never interpolated into the script.
                let script = """
                while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
                /bin/rm -rf "$2.old" && /bin/mv "$2" "$2.old" && /bin/mv "$3" "$2" && /bin/rm -rf "$2.old" "$4"
                /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
                /usr/bin/open "$2"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "thermo-update", String(getpid()), target.path, newApp.path, tmp.path]
                try p.run()
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

/// Opens a pre-filled feedback issue on GitHub (with app version, macOS and Mac model filled in).
func sendFeedback() {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var model = [CChar](repeating: 0, count: 64); var size = 64
    sysctlbyname("hw.model", &model, &size, nil, 0)
    var c = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
    c.queryItems = [URLQueryItem(name: "template", value: "feedback.yml"),
                    URLQueryItem(name: "environment", value: "Thermo \(v) · macOS \(os) · \(String(cString: model))")]
    if let u = c.url { NSWorkspace.shared.open(u) }
}
