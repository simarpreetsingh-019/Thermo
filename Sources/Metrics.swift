// System-wide metrics: CPU, RAM, GPU, temperature sensors. No sudo needed.

import Foundation
import IOKit
import Darwin

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
    var ramPct: Double { ramTotal > 0 ? ramUsed / ramTotal * 100 : 0 }
    var hottest: Double? { [cpuTemp, gpuTemp].compactMap { $0 }.max() }
}

final class Sampler {
    private var prevTicks: [UInt32]? = nil
    private let temps = TempReader()
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
        s.thermalState = ProcessInfo.processInfo.thermalState
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
