// Benchmarks inside the History tab: record a run from the app, browse saved runs (from the app, CLI or
// AI agents), see CPU and heat over the run, and copy a before/after table for a pull request.

#if !NO_CONNECT

import AppKit
import SwiftUI

final class BenchUI: ObservableObject {
    static let shared = BenchUI()
    @Published var runs: [[String: Any]] = []
    @Published var recording: BenchRecorder?
    @Published var openID: String?
    @Published var note: String?

    func reload() { runs = BenchStore.list(limit: 20) }

    func toggleRecord() {
        if let r = recording {
            let rep = r.stop()
            BenchStore.save(rep, series: r.series)
            recording = nil
            reload()
            openID = rep["id"] as? String
        } else {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            recording = BenchRecorder(label: "Recorded at \(f.string(from: Date()))")
        }
    }

    func copyCompare() {
        guard let (a, b) = BenchStore.pair(nil, nil), let md = BenchStore.compare(a, b)["markdown"] as? String else {
            flash("Record two runs to compare"); return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(md, forType: .string)
        flash("Comparison table copied")
    }

    private func flash(_ t: String) {
        note = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.note == t { self?.note = nil } }
    }
}

struct BenchList: View {
    @ObservedObject var ui = BenchUI.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: ui.toggleRecord) {
                    HStack(spacing: 5) {
                        Circle().fill(ui.recording == nil ? Color.red : Color.white).frame(width: 7, height: 7)
                        if let r = ui.recording {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in Text("Stop · \(Int(r.elapsed)) s") }
                        } else { Text("Record") }
                    }
                    .font(.system(size: 10, weight: .bold)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(ui.recording == nil ? Color.white.opacity(0.1) : Color.red.opacity(0.8)))
                }.buttonStyle(.plain).help("Record CPU, GPU and temperatures while you run something")
                Button(action: ui.copyCompare) {
                    Text("Copy last two as table").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).disabled(ui.runs.count < 2).help("Before/after Markdown table for a pull request")
                Spacer()
                if let n = ui.note { Text(n).font(.system(size: 9)).foregroundStyle(.green) }
            }
            if ui.runs.isEmpty {
                Text("No benchmarks yet. Press Record, run your app or tests, then Stop. Or in Terminal: thermo bench -- npm test")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            } else {
                MaybeScroll {
                    VStack(spacing: 4) {
                        ForEach(ui.runs.indices, id: \.self) { i in
                            BenchRow(r: ui.runs[i], open: ui.openID == ui.runs[i]["id"] as? String) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    let id = ui.runs[i]["id"] as? String
                                    ui.openID = ui.openID == id ? nil : id
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { ui.reload() }
    }
}

struct BenchRow: View {
    let r: [String: Any]
    let open: Bool
    let toggle: () -> Void

    private func col(_ i: Int) -> [Double?] {
        let rows = r["series"] as? [[Any]] ?? []
        let step = max(1, rows.count / 120)
        return stride(from: 0, to: rows.count, by: step).map { (rows[$0].count > i ? rows[$0][i] as? NSNumber : nil)?.doubleValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 10)).foregroundStyle(.cyan)
                Text(r["label"] as? String ?? "Benchmark").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer()
                if let d = (r["started_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                    Text(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle()).onTapGesture(perform: toggle)
            Text(r["summary"] as? String ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(open ? 3 : 1)
            if open {
                ZStack {
                    LineChart(values: col(1), color: .cyan)
                    LineChart(values: col(3), color: .orange, lo: 30, hi: 105)
                }.frame(height: 36)
                HStack(spacing: 10) {
                    Label("CPU %", systemImage: "circle.fill").foregroundStyle(.cyan)
                    Label("Hottest °C", systemImage: "circle.fill").foregroundStyle(.orange)
                    Spacer()
                    Text("id \(r["id"] as? String ?? "")").foregroundStyle(.secondary)
                }.font(.system(size: 8)).labelStyle(.titleAndIcon).imageScale(.small)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(open ? 0.1 : 0.05)))
    }
}

#endif
