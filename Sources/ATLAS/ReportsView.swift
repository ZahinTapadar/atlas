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
            VStack(alignment: .leading, spacing: 32) {
                PageHeader(title: "Reports", subtitle: "Where your time went, how focused it was, and how check-ins judged it") {
                    Picker("Range", selection: $range) {
                        Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }

                let engaged = stats.reduce(0) { $0 + $1.engaged }
                let switches = stats.reduce(0) { $0 + $1.switches }
                FigureLine(parts: [
                    (Fmt.duration(engaged), "engaged"),
                    (Fmt.duration(stats.map(\.longestFocus).max() ?? 0), "longest focus"),
                    (engaged > 0 ? String(format: "%.1f", Double(switches) / (engaged / 3600)) : "–", "switches per hour"),
                    (Fmt.duration(stats.reduce(0) { $0 + $1.unplanned }), "on video, social and games"),
                    (Fmt.duration(stats.reduce(0) { $0 + $1.uncertain }), "uncertain"),
                ])

                Card(title: "Time allocation") {
                    Chart {
                        ForEach(stats) { d in
                            ForEach(AllocationGroup.allCases, id: \.self) { g in
                                if let v = d.byGroup[g], v > 0 {
                                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", v / 3600), width: .ratio(0.6))
                                        .foregroundStyle(by: .value("Group", g.displayName))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: AllocationGroup.allCases.map(\.displayName),
                                               range: AllocationGroup.allCases.map(\.color))
                    .chartXScale(domain: chartDomain)
                    .chartYAxisLabel("hours")
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                    .frame(height: 230)
                }

                HStack(alignment: .top, spacing: 48) {
                    Card(title: "Check-in verdicts") {
                        let verdicts = verdictCounts
                        if verdicts.isEmpty {
                            Text("No check-ins in this range yet.").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                        } else {
                            Chart(verdicts, id: \.id) { v in
                                BarMark(x: .value("Day", v.day, unit: .day), y: .value("Check-ins", v.count), width: .ratio(0.5))
                                    .foregroundStyle(by: .value("Verdict", v.verdict.title))
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                            .chartForegroundStyleScale(domain: [Verdict.onTrack, .mixed, .offTrack].map(\.title),
                                                       range: [Theme.onTrack, Theme.mixed, Theme.offTrack])
                            .chartXScale(domain: chartDomain)
                            .chartLegend(position: .bottom, alignment: .leading)
                            .frame(height: 180)
                        }
                    }
                    Card(title: "Focus sessions") {
                        Chart(stats) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Sessions", d.focusSessions), width: .ratio(0.5))
                                .foregroundStyle(Theme.inkTertiary.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .chartXScale(domain: chartDomain)
                        .frame(height: 180)
                        Text("Sessions of 25 minutes or more spent on work, learning or reading.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }

                if let today = model.dailySummaries.first {
                    Card(title: "Recommendations from \(today.day)") {
                        ForEach(today.recommendations.suffix(8), id: \.self) { Text("• \($0)").font(.callout) }
                        if !today.scheduleChanges.isEmpty {
                            Text("Schedule changes proposed").font(.subheadline.weight(.semibold)).padding(.top, 4)
                            ForEach(today.scheduleChanges.suffix(8), id: \.self) { Text("• \($0)").font(.caption) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 38).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task(id: range) { await load() }
    }

    private var chartDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let start = cal.date(byAdding: .day, value: -range, to: end)!
        return start...end
    }

    private struct VerdictCount { var id: String; var day: Date; var verdict: Verdict; var count: Int }

    private var verdictCounts: [VerdictCount] {
        let cal = Calendar.current
        let start = chartDomain.lowerBound
        var out: [String: VerdictCount] = [:]
        for c in model.checkins where c.ts >= start {
            let v = Verdict(c.verdict)
            guard v == .onTrack || v == .mixed || v == .offTrack else { continue }
            let day = cal.startOfDay(for: c.ts)
            let key = "\(day.timeIntervalSince1970)-\(v.rawValue)"
            out[key, default: VerdictCount(id: key, day: day, verdict: v, count: 0)].count += 1
        }
        return out.values.sorted { $0.day < $1.day }
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

/// Summary figures set as one line of type: value in ink, label in secondary.
struct FigureLine: View {
    var parts: [(String, String)]
    var body: some View {
        parts.enumerated().reduce(Text("")) { acc, item in
            let (i, p) = item
            let sep = i == 0 ? Text("") : Text("   ·   ").foregroundColor(Theme.inkTertiary)
            return acc + sep + Text(p.0).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundColor(Theme.ink)
                + Text(" " + p.1).font(.system(size: 15)).foregroundColor(Theme.inkSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
