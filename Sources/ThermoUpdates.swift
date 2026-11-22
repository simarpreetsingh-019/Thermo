// Thermo's glue around shipcrate's updater (Sources/Updater.swift, from https://github.com/simarpreetsingh-019/shipcrate):
// Thermo's own toasts for updates, announcements and "what's new", plus feedback. Updater.swift stays as shipcrate
// generates it, so it can be refreshed from shipcrate later.
import AppKit

enum ThermoUpdates {
    /// Call once at launch: starts the daily check and routes its events to Thermo's toasts.
    static func start() {
        let u = Updater.shared
        u.onUpdateAvailable = { r in
            // Announce each new version once (the orange Update button stays visible either way).
            guard UserDefaults.standard.string(forKey: "notifiedVersion") != r.version else { return }
            UserDefaults.standard.set(r.version, forKey: "notifiedVersion")
            Toasts.shared.updateAvailable(r)
        }
        u.onAnnouncement = { a in Toasts.shared.announcement(a) }
    }

    /// First launch → welcome card; first launch after an update → "what's new" card. True if a card is showing.
    @discardableResult
    static func announceLaunch() -> Bool {
        let d = UserDefaults.standard, current = Updater.shared.current
        let last = d.string(forKey: "lastSeenVersion")
        d.set(current, forKey: "lastSeenVersion")
        if last == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Toasts.shared.welcome() }
        } else if last != current {
            fetchNotes(for: current) { notes in Toasts.shared.whatsNew(version: current, notes: notes) }
        }
        return last != current
    }

    static func fetchNotes(for version: String, _ done: @escaping (String) -> Void) {
        var req = Updater.shared.request("releases/tags/v\(version)")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["body"] as? String ?? ""
            DispatchQueue.main.async { done(body) }
        }.resume()
    }

    /// Beta updates: maintainers and testers get pre-releases (e.g. 1.10.0-beta.1) first; everyone else never sees them.
    static var beta: Bool {
        get { Updater.channel == "beta" }
        set { Updater.channel = newValue ? "beta" : "stable"; Updater.shared.check(userInitiated: false) }
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
