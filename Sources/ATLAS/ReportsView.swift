import AtlasCore
import Charts
import SwiftUI

struct DayStats: Identifiable {
    var id: Date { day }
    var day: Date
    var byGroup: [AllocationGroup: TimeInterval]
    var engaged: TimeInterval
    var uncertain: TimeInterval
    var switches: Int
    var focusSessions: Int
    var longestFocus: TimeInterval
    var plannedMinutes: Int
    var completed: Int
    var planned: Int
    var unplanned: TimeInterval
    var score: Double?
}

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var range = 7
    @State private var stats: [DayStats] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).frame(width: 280)

                let engaged = stats.reduce(0) { $0 + $1.engaged }
                let planned = stats.reduce(0) { $0 + $1.planned }
                let completed = stats.reduce(0) { $0 + $1.completed }
                let switches = stats.reduce(0) { $0 + $1.switches }
                HStack(spacing: 28) {
                    Metric(label: "Engaged time", value: Fmt.duration(engaged))
                    Metric(label: "Task completion", value: planned > 0 ? "\(completed)/\(planned)" : "—",
                           caption: planned > 0 ? "\(Int(Double(completed) / Double(planned) * 100))% of planned tasks" : "no planned tasks")
                    Metric(label: "Switches / hour", value: engaged > 0 ? String(format: "%.1f", Double(switches) / (engaged / 3600)) : "—")
                    Metric(label: "Longest focus", value: Fmt.duration(stats.map(\.longestFocus).max() ?? 0))
                    Metric(label: "Unplanned leisure", value: Fmt.duration(stats.reduce(0) { $0 + $1.unplanned }),
                           caption: "entertainment, social, gaming")
                    Metric(label: "Uncertain", value: Fmt.duration(stats.reduce(0) { $0 + $1.uncertain }))
                }

                Card(title: "Time allocation", systemImage: "chart.bar") {
                    Chart {
                        ForEach(stats) { d in
                            ForEach(AllocationGroup.allCases, id: \.self) { g in
                                if let v = d.byGroup[g], v > 0 {
                                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", v / 3600))
                                        .foregroundStyle(by: .value("Group", g.displayName))
                                }
                            }
                        }
                    }
                    .chartYAxisLabel("hours")
                    .frame(height: 220)
                }

                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Planned vs. actual (minutes)", systemImage: "arrow.left.arrow.right") {
                        Chart {
                            ForEach(stats) { d in
                                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.plannedMinutes))
                                    .foregroundStyle(by: .value("Kind", "Planned")).position(by: .value("Kind", "Planned"))
                                BarMark(x: .value("Day", d.day, unit: .day),
                                        y: .value("Minutes", ((d.byGroup[.activeWork] ?? 0) + (d.byGroup[.learning] ?? 0) + (d.byGroup[.reading] ?? 0)) / 60))
                                    .foregroundStyle(by: .value("Kind", "Productive actual")).position(by: .value("Kind", "Productive actual"))
                            }
                        }
                        .frame(height: 180)
                    }
                    Card(title: "Rubric trend", systemImage: "chart.line.uptrend.xyaxis") {
                        let scored = stats.filter { $0.score != nil }
                        if scored.isEmpty {
                            Text("No scored windows yet — scores need enough observed time.").foregroundStyle(.secondary)
                        } else {
                            Chart(scored) { d in
                                LineMark(x: .value("Day", d.day, unit: .day), y: .value("Score", d.score!))
                                PointMark(x: .value("Day", d.day, unit: .day), y: .value("Score", d.score!))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 180)
                        }
                        Text("Score = weighted rubric (Settings → Claude → Rubric). Days with insufficient data have no score.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Focus sessions", systemImage: "scope") {
                    Chart(stats) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Sessions", d.focusSessions))
                    }
                    .frame(height: 140)
                    Text("Sessions ≥ 25 minutes whose primary category is work, learning or reading.").font(.caption).foregroundStyle(.secondary)
                }

                if let today = model.dailySummaries.first {
                    Card(title: "Recommendations from \(today.day)", systemImage: "lightbulb") {
                        ForEach(today.recommendations.suffix(8), id: \.self) { Text("• \($0)").font(.callout) }
                        if !today.scheduleChanges.isEmpty {
                            Text("Schedule changes proposed").font(.subheadline.weight(.semibold)).padding(.top, 4)
                            ForEach(today.scheduleChanges.suffix(8), id: \.self) { Text("• \($0)").font(.caption) }
                        }
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Reports")
        .task(id: range) { await load() }
    }

    private func load() async {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var out: [DayStats] = []
        let plan = model.planItems
        let summaries = Dictionary(model.dailySummaries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for offset in stride(from: range - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let end = min(next, Date())
            let raw = (try? await model.store.events(from: day, to: end)) ?? []
            let events = TimeAccounting.normalized(raw, from: day, to: end)
            var byGroup: [AllocationGroup: TimeInterval] = [:]
            for (cat, v) in TimeAccounting.totals(events) { byGroup[cat.allocationGroup, default: 0] += v.observed }
            let sessions = SessionBuilder.build(events).sessions
            let focusGroups: Set<AllocationGroup> = [.activeWork, .learning, .reading]
            let focus = sessions.filter { focusGroups.contains($0.primaryCategory.allocationGroup) && $0.activeSeconds >= 25 * 60 }
            let todays = plan.filter { p in p.plannedStart.map { $0 >= day && $0 < next } ?? false }
            out.append(DayStats(
                day: day, byGroup: byGroup, engaged: events.filter { $0.state.isEngaged }.reduce(0) { $0 + $1.duration },
                uncertain: events.filter { $0.state == .uncertain || ($0.state.isEngaged && $0.classification.isUncertain) }.reduce(0) { $0 + $1.duration },
                switches: FocusMetrics.compute(events).switches, focusSessions: focus.count,
                longestFocus: FocusMetrics.compute(events).longestFocus,
                plannedMinutes: todays.reduce(0) { $0 + $1.expectedMinutes },
                completed: todays.filter { $0.status == .completed }.count, planned: todays.count,
                unplanned: (byGroup[.entertainment] ?? 0) + (byGroup[.socialMedia] ?? 0) + (byGroup[.gaming] ?? 0),
                score: summaries[f.string(from: day)]?.assessment?.score))
        }
        stats = out
    }
}
