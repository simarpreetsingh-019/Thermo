// 1.6: battery health, read from the AppleSmartBattery entry in the I/O Registry (no permissions needed).

import Foundation
import IOKit
import SwiftUI

struct BatteryInfo {
    var present = false
    var percent = 0.0
    var charging = false
    var plugged = false
    var full = false
    var cycles = 0
    var designCycles = 1000
    var designCap = 0          // mAh when new
    var maxCap = 0             // mAh it holds today
    var watts = 0.0            // + charging, − draining
    var minutesLeft: Int?      // to empty (on battery) or to full (charging)
    var failure = false

    var health: Double { designCap > 0 ? min(Double(maxCap) / Double(designCap) * 100, 100) : 0 }
    var needsService: Bool { failure || (health > 0 && health < 80) }
    var condition: String { needsService ? "Service recommended" : health >= 90 ? "Excellent" : "Normal" }
    var conditionColor: Color { needsService ? .red : health >= 90 ? .green : .yellow }

    static func read() -> BatteryInfo {
        var b = BatteryInfo()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return b }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return b }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        func num(_ k: String) -> NSNumber? { (d[k] ?? data[k]) as? NSNumber }
        func int(_ k: String) -> Int? { num(k).map { Int(Int32(truncatingIfNeeded: $0.int64Value)) } }   // values can be negative stored as UInt64

        b.present = d["BatteryInstalled"] as? Bool ?? (int("DesignCapacity") != nil)
        guard b.present else { return b }
        let cur = int("CurrentCapacity") ?? 0, maxField = int("MaxCapacity") ?? 100
        b.percent = maxField > 0 ? min(Double(cur) / Double(maxField) * 100, 100) : 0   // Apple Silicon reports both as %
        b.charging = d["IsCharging"] as? Bool ?? false
        b.plugged = d["ExternalConnected"] as? Bool ?? false
        b.full = d["FullyCharged"] as? Bool ?? false
        b.cycles = int("CycleCount") ?? 0
        b.designCycles = int("DesignCycleCount9C") ?? 1000
        b.designCap = int("DesignCapacity") ?? 0
        b.maxCap = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? (maxField > 200 ? maxField : 0)
        let mV = Double(int("Voltage") ?? 0), mA = Double(int("InstantAmperage") ?? int("Amperage") ?? 0)
        b.watts = mV * mA / 1_000_000
        if let t = int(b.charging ? "AvgTimeToFull" : "AvgTimeToEmpty") ?? int("TimeRemaining"), t > 0, t < 65535 { b.minutesLeft = t }
        b.failure = (int("PermanentFailureStatus") ?? 0) != 0
        return b
    }
}

func duration(_ min: Int) -> String { min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m" }

struct BatteryTab: View {
    @ObservedObject var m: Monitor
    @ObservedObject var hist = History.shared
    var body: some View {
        let b = m.battery
        if !b.present {
            VStack(spacing: 6) {
                Image(systemName: "powerplug.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("No battery").font(.system(size: 12, weight: .semibold))
                Text("This Mac runs on mains power.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "battery.100percent").font(.system(size: 20)).foregroundStyle(b.conditionColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Battery health \(Int(b.health.rounded()))% · \(b.condition)").font(.system(size: 13, weight: .bold))
                        Text(healthNote(b)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(b.percent))%").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(load(100 - b.percent))
                        Text(b.charging ? "charging" : b.plugged ? (b.full ? "full" : "plugged in") : "on battery").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    stat("Cycles", "\(b.cycles)", "of \(b.designCycles) rated")
                    stat("Holds", "\(b.maxCap) mAh", "new: \(b.designCap)")
                    stat(b.watts >= 0 ? "Charging" : "Using", String(format: "%.1f W", abs(b.watts)), b.minutesLeft.map { (b.charging ? "full in " : "") + duration($0) + (b.charging ? "" : " left") } ?? "—")
                    stat("Temp", m.snap.batteryTemp.map { "\(Int($0))°" } ?? "—", "battery")
                }
                HStack(spacing: 6) {
                    Text("CHARGE · 24H").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    LineChart(values: hist.series(\.battery, range: .day), color: .green).frame(height: 26)
                }
            }
        }
    }

    func healthNote(_ b: BatteryInfo) -> String {
        var s = b.needsService ? "It holds much less than when new; Apple suggests a service below 80%."
                               : "It holds \(Int(b.health.rounded()))% of the charge it did when new."
        if let first = hist.healthLog.first, first.health - b.health >= 1 {
            s += " Down \(Int((first.health - b.health).rounded())) pts since \(first.date.formatted(.dateTime.month(.abbreviated).day()))."
        }
        return s
    }

    func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
