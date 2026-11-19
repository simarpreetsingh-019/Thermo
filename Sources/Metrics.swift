// System-wide metrics: CPU, RAM, GPU, temperature sensors. No sudo needed.

import Foundation
import IOKit
import Darwin
import SwiftUI

struct Snapshot {
    var cpu: Double = 0
    var ramUsed: Double = 0
    var ramTotal: Double = 0
    var swap: Double = 0
    var gpu: Double? = nil
    var cpuTemp: Double? = nil
    var gpuTemp: Double? = nil
    var ssdTemp: Double? = nil
    var batteryTemp: Double? = nil
    var thermalState: ProcessInfo.ThermalState = .nominal
    var memPressure: MemPressure = .normal
    var parts: [TempPart] = []
    var ramPct: Double { ramTotal > 0 ? ramUsed / ramTotal * 100 : 0 }
    var hottest: Double? { [cpuTemp, gpuTemp].compactMap { $0 }.max() }
}

final class Sampler {
    private var prevTicks: [UInt32]? = nil
    private let temps = TempReader()
    private let smc = SMCReader()
    let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)

    func sample() -> Snapshot {
        var s = Snapshot()
        s.cpu = cpu()
        (s.ramUsed, s.swap) = ram()
        s.ramTotal = totalRAM
        s.gpu = gpu()
        let t = temps.read()
        func hottest(_ f: (String) -> Bool) -> Double? {
            t.filter { f($0.key.lowercased()) }.map(\.value).max()
        }
        s.cpuTemp = hottest { $0.contains("tdie") || $0.contains("tdev") || $0.contains("pmu") || $0.contains("cpu") || $0.contains("soc") }
        s.gpuTemp = hottest { $0.contains("gpu") }
        s.ssdTemp = hottest { $0.contains("nand") || $0.contains("ssd") }
        s.batteryTemp = hottest { $0.contains("batt") || $0.contains("gas gauge") }
        // Prefer the SMC's per-component sensors when present: they split CPU, GPU, SSD, battery and more.
        s.parts = smc.parts()
        func part(_ n: String) -> Double? { s.parts.first { $0.id == n }?.value }
        if let p = [part("CPU performance cores"), part("CPU efficiency cores")].compactMap({ $0 }).max() { s.cpuTemp = p }
        if let g = part("GPU") { s.gpuTemp = g }
        if let d = part("SSD") { s.ssdTemp = d }
        if let b = part("Battery") { s.batteryTemp = b }
        if s.parts.isEmpty {   // no SMC access: show what the HID sensors give
            s.parts = [("CPU", "cpu", s.cpuTemp, 80.0, 95.0), ("GPU", "cube.transparent", s.gpuTemp, 80, 95),
                       ("SSD", "internaldrive", s.ssdTemp, 60, 70), ("Battery", "battery.75percent", s.batteryTemp, 40, 45)]
                .compactMap { n, i, v, w, h in v.map { TempPart(id: n, icon: i, value: $0, warm: w, hot: h, sensors: 1) } }
        }
        s.thermalState = ProcessInfo.processInfo.thermalState
        s.memPressure = MemPressure.read()
        return s
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let d = zip(t, p).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : 0
    }

    private func ram() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard r == KERN_SUCCESS else { return (0, Double(swap.xsu_used)) }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (used, Double(swap.xsu_used))
    }

    private func gpu() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let ref = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let dict = ref.takeRetainedValue() as? [String: Any],
               let u = dict["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, u.doubleValue)
            }
        }
        return best
    }
}

/// Reads Apple Silicon temperature sensors through IOKit's HID event system (loaded via dlsym).
final class TempReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private var client: AnyObject?
    private var copyServices: CopyServicesFn?
    private var copyProp: CopyPropFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatch = sym("IOHIDEventSystemClientSetMatching", SetMatchFn.self) else { return }
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = setMatch(c, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        client = c
    }

    func read() -> [String: Double] {
        guard let client, let copyServices, let copyProp, let copyEvent, let getFloat,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [:] }
        var out: [String: Double] = [:]
        for (i, svc) in services.enumerated() {
            let name = (copyProp(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? "sensor\(i)"
            guard let ev = copyEvent(svc, 15, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(ev, 15 << 16)
            if t > 0 && t < 150 { out[name] = max(out[name] ?? 0, t) }
        }
        return out
    }
}

// MARK: - Per-component temperatures (1.6)

struct TempPart: Identifiable {
    let id: String          // component name
    let icon: String
    let value: Double       // hottest sensor in the group
    let warm: Double, hot: Double
    let sensors: Int
    var color: Color { value >= hot ? .red : value >= warm ? .orange : .green }
}

/// Reads temperature keys from the System Management Controller. User-level access, no admin rights.
/// Keys are discovered once at launch; each sample reads only the cached temperature keys.
final class SMCReader {
    private var conn: io_connect_t = 0
    private var keys: [(key: UInt32, size: Int, type: UInt32, group: Int)] = []

    // Component groups by SMC key prefix (Apple Silicon and Intel conventions).
    static let groups: [(name: String, icon: String, warm: Double, hot: Double, match: (String) -> Bool)] = [
        ("CPU performance cores", "cpu", 80, 95, { $0.hasPrefix("Tp") || $0.hasPrefix("TC") || $0.hasPrefix("Tc") }),
        ("CPU efficiency cores", "leaf.fill", 80, 95, { $0.hasPrefix("Te") }),
        ("GPU", "cube.transparent", 80, 95, { $0.hasPrefix("Tg") || $0.hasPrefix("TG") }),
        ("Memory", "memorychip", 75, 90, { $0.hasPrefix("Tm") || $0.hasPrefix("TM") }),
        ("SSD", "internaldrive", 60, 70, { $0.hasPrefix("TH") }),
        ("Battery", "battery.75percent", 40, 45, { $0.hasPrefix("TB") }),
        ("Wi-Fi", "wifi", 70, 85, { $0.hasPrefix("TW") }),
        ("Palm rest", "hand.raised.fill", 38, 43, { $0 == "Ts0P" || $0 == "Ts1P" }),
    ]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { conn = 0; return }
        let count = read(Self.fourcc("#KEY"), size: 4).map { $0.reduce(0) { $0 << 8 | Int($1) } } ?? 0
        for i in 0..<min(count, 6000) {
            var b = Self.blank(); b[42] = 8; Self.put(&b, 44, UInt32(i))
            guard let o = call(b) else { continue }
            let k = Self.get(o, 0), name = Self.name(k)
            guard name.hasPrefix("T"), let g = Self.groups.firstIndex(where: { $0.match(name) }),
                  let (size, type) = info(k), (Self.name(type) == "flt " && size == 4) || (Self.name(type) == "sp78" && size == 2)
            else { continue }
            keys.append((k, size, type, g))
        }
    }

    var available: Bool { !keys.isEmpty }

    func parts() -> [TempPart] {
        var vals = [[Double]](repeating: [], count: Self.groups.count)
        for k in keys {
            guard let d = read(k.key, size: k.size) else { continue }
            let v: Double = Self.name(k.type) == "flt "
                ? Double(d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
                : Double(Int16(bitPattern: UInt16(d[0]) << 8 | UInt16(d[1]))) / 256
            if v > 5 && v < 130 { vals[k.group].append(v) }
        }
        return Self.groups.enumerated().compactMap { i, g in
            vals[i].max().map { TempPart(id: g.name, icon: g.icon, value: $0, warm: g.warm, hot: g.hot, sensors: vals[i].count) }
        }
    }

    // SMCKeyData_t is an 80-byte struct: key @0, keyInfo.dataSize @28, dataType @32, result @40, data8 @42, data32 @44, bytes @48.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var i = input, o = [UInt8](repeating: 0, count: 80), n = 80
        return IOConnectCallStructMethod(conn, 2, &i, 80, &o, &n) == KERN_SUCCESS && o[40] == 0 ? o : nil
    }
    private func info(_ key: UInt32) -> (Int, UInt32)? {
        var b = Self.blank(); Self.put(&b, 0, key); b[42] = 9
        return call(b).map { (Int(Self.get($0, 28)), Self.get($0, 32)) }
    }
    private func read(_ key: UInt32, size: Int) -> [UInt8]? {
        guard conn != 0 else { return nil }
        var b = Self.blank(); Self.put(&b, 0, key); Self.put(&b, 28, UInt32(size)); b[42] = 5
        return call(b).map { Array($0[48..<48 + size]) }
    }
    private static func blank() -> [UInt8] { [UInt8](repeating: 0, count: 80) }
    private static func put(_ b: inout [UInt8], _ off: Int, _ v: UInt32) { for j in 0..<4 { b[off + j] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(j))) } }
    private static func get(_ b: [UInt8], _ off: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[off + $1]) << (8 * UInt32($1)) } }
    private static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ k: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: k >> $0) }, encoding: .ascii) ?? "" }
}
