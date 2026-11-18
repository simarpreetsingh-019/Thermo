// Per-app CPU / memory usage and the thermal advisor (what's hot, why, how long to cool, what to close).

import AppKit
import Darwin

struct AppUsage: Identifiable {
    let id: String
    var name: String
    var project: String?       // working folder for CLI tools (node, python, builds…)
    var pids: [pid_t]
    var mainPID: pid_t
    var cpu: Double            // % of one core, like Activity Monitor
    var mem: Double            // bytes
    var isApp: Bool
    var canQuit: Bool
    var icon: NSImage?
}

final class ProcSampler {
    private var prev: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private let toNs: Double
    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private let responsible: RespFn?
    private let me = getpid()
    private let myUID = getuid()

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        toNs = Double(tb.numer) / Double(tb.denom)
        responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: RespFn.self) }
    }

    func sample() -> [AppUsage] {
        let now = mach_absolute_time()
        let wall = Double(now &- prevTime) * toNs
        let first = prevTime == 0
        prevTime = now

        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let c = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

        var apps: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            apps[a.processIdentifier] = a
        }

        var next: [pid_t: UInt64] = [:]
        var groups: [String: AppUsage] = [:]
        for pid in pids.prefix(c) where pid > 0 && pid != me {
            var ri = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let total = ri.ri_user_time + ri.ri_system_time
            next[pid] = total
            let cpu = (!first && wall > 0) ? Double(total &- (prev[pid] ?? total)) * toNs / wall * 100 : 0

            let pname = Self.name(pid)
            var key = "pid:\(pid)", app: NSRunningApplication? = apps[pid]
            if app == nil, let resp = responsible?(pid), resp != pid, let ra = apps[resp],
               Self.looksLikeHelper(pname, appName: ra.localizedName ?? "") {
                app = ra
            }
            if let app { key = "app:\(app.processIdentifier)" }

            if groups[key] == nil {
                groups[key] = AppUsage(id: key, name: app?.localizedName ?? pname, project: nil, pids: [],
                                       mainPID: app?.processIdentifier ?? pid, cpu: 0, mem: 0,
                                       isApp: app != nil, canQuit: app != nil, icon: app?.icon)
            }
            groups[key]!.pids.append(pid)
            groups[key]!.cpu += max(cpu, 0)
            groups[key]!.mem += Double(ri.ri_phys_footprint)
        }
        prev = next

        // Extra details only for the entries likely to be shown.
        var list = Array(groups.values)
        let top = Set(list.sorted { $0.cpu > $1.cpu }.prefix(12).map(\.id) + list.sorted { $0.mem > $1.mem }.prefix(12).map(\.id))
        for i in list.indices where top.contains(list[i].id) && !list[i].isApp {
            list[i].project = Self.cwdFolder(list[i].mainPID)
            list[i].canQuit = Self.safeToStop(list[i].mainPID, name: list[i].name)
        }
        return list
    }

    /// User-owned processes that keep the session alive: stopping them would log out or break the desktop.
    static let protected: Set<String> = ["launchd", "loginwindow", "Dock", "SystemUIServer", "ControlCenter",
        "WindowManager", "NotificationCenter", "Finder", "UserEventAgent", "cfprefsd", "distnoted", "secd",
        "trustd", "securityd", "sharingd", "coreaudiod", "WindowServer", "Thermo"]

    /// Only our own user's, non-critical processes may be stopped, and only if the pid still belongs to the
    /// same process we listed (guards against pid reuse between listing and clicking).
    static func safeToStop(_ pid: pid_t, name: String) -> Bool {
        pid > 1 && pid != getpid() && uid(pid) == getuid()
            && Self.name(pid) == name && !protected.contains(name)
    }

    static func looksLikeHelper(_ name: String, appName: String) -> Bool {
        let n = name.lowercased(), a = appName.lowercased()
        return n.contains("helper") || n.contains("renderer") || n.hasPrefix("com.apple.webkit")
            || (!a.isEmpty && n.hasPrefix(String(a.prefix(6))))
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, 256)
        let s = String(cString: buf)
        return s.isEmpty ? "pid \(pid)" : s
    }

    static func cwdFolder(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if path.isEmpty || path == "/" || path == NSHomeDirectory() { return nil }
        return (path as NSString).lastPathComponent
    }

    static func uid(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }
}

// MARK: - Thermal advisor

enum HeatLevel: Int, Comparable {
    case cool, warm, hot, critical
    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }
    var title: String { ["Cool", "Warm", "Hot", "Very hot"][rawValue] }
}

struct ThermalAdvice {
    var level: HeatLevel = .cool
    var headline = "Running cool"
    var affected: [String] = []
    var eta = ""
    var culprits: [AppUsage] = []
    var tips: [String] = []
}

enum Advisor {
    static let comfortable = 60.0

    static func advise(_ s: Snapshot, apps: [AppUsage], history: [(t: Date, temp: Double)]) -> ThermalAdvice {
        var a = ThermalAdvice()
        let temp = s.hottest ?? 0
        let state = s.thermalState

        if state == .critical || temp >= 95 { a.level = .critical }
        else if state == .serious || temp >= 85 { a.level = .hot }
        else if state == .fair || temp >= 72 { a.level = .warm }

        let throttling = state == .serious || state == .critical
        switch a.level {
        case .cool:
            a.headline = "Running cool — full performance"
        case .warm:
            a.headline = "Warming up — still at full speed"
            a.affected = ["Fans may spin up on Macs that have them",
                          "Long heavy tasks may start to slow if this continues"]
        case .hot:
            a.headline = throttling ? "Hot — macOS is slowing the CPU/GPU to cool down" : "Hot — slowdown likely soon"
            a.affected = ["CPU and GPU clock speeds reduced",
                          "Builds, exports and renders take longer",
                          "Games and video may drop frames",
                          "Battery drains faster; charging may slow"]
        case .critical:
            a.headline = "Very hot — performance heavily reduced"
            a.affected = ["CPU and GPU strongly throttled",
                          "Apps may feel laggy or stutter",
                          "Builds, exports, games much slower",
                          "Battery charging may pause to protect it"]
        }

        a.culprits = apps.filter { $0.cpu >= 15 }.sorted { $0.cpu > $1.cpu }.prefix(4).map { $0 }
        a.eta = eta(temp: temp, history: history)

        if a.level >= .warm {
            if let top = a.culprits.first {
                a.tips.append("Quit or pause \(top.name)\(top.project.map { " (\($0))" } ?? "") — it's using \(Int(top.cpu))% CPU")
            } else {
                a.tips.append("No single app is busy — heat may come from the GPU, charging, or the room")
            }
            if (s.gpu ?? 0) > 50 { a.tips.append("GPU is busy: close games, 3D or video apps, or browser tabs playing video") }
            if (s.batteryTemp ?? 0) > 38 { a.tips.append("Battery is warm: unplugging the charger for a while helps") }
            a.tips.append("Keep vents clear; use a hard, flat surface (not a bed or lap)")
        }
        return a
    }

    static func eta(temp: Double, history: [(t: Date, temp: Double)]) -> String {
        guard temp > 0 else { return "Temperature sensors unavailable on this Mac" }
        if temp <= comfortable + 1 { return "Already in the comfortable range (≤\(Int(comfortable))°)" }
        let recent = history.filter { $0.t > Date().addingTimeInterval(-30) }
        if let f = recent.first, let l = recent.last {
            let dt = l.t.timeIntervalSince(f.t)
            if dt > 10 {
                let slope = (l.temp - f.temp) / dt
                if slope < -0.03 {
                    return "Cooling now — about \(fmt((temp - comfortable) / -slope)) to reach \(Int(comfortable))°"
                }
            }
        }
        // Newton cooling estimate once load drops (Apple Silicon idles ~38°, time constant ~45 s).
        let ambient = 38.0
        let secs = 45 * log((temp - ambient) / (comfortable - ambient))
        return "Not cooling while load continues. After closing the top apps, about \(fmt(secs)) to \(Int(comfortable))°"
    }

    static func fmt(_ s: Double) -> String {
        s < 60 ? "\(max(Int(s), 5)) sec" : "\(Int((s / 60).rounded(.up))) min"
    }
}

func stopApp(_ a: AppUsage) {
    if a.isApp, let app = NSRunningApplication(processIdentifier: a.mainPID), app.localizedName == a.name {
        app.terminate()   // graceful: the app can ask to save documents
        return
    }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Stop “\(a.name)”?"
    alert.informativeText = "This is a background process\(a.project.map { " in \($0)" } ?? "") (\(a.pids.count) process\(a.pids.count == 1 ? "" : "es")). Any unsaved work in it may be lost."
    alert.addButton(withTitle: "Stop")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
        // Re-check right before signalling: the pid may have exited and been reused while the alert was open.
        guard ProcSampler.safeToStop(a.mainPID, name: a.name) else { NSSound.beep(); return }
        kill(a.mainPID, SIGTERM)   // background entries are always a single process
    }
}
