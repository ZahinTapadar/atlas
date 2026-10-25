import AtlasCore
import Charts
import SwiftUI

/// Reports: one sentence on the period, then the evidence: where the time went, when you focus,
/// how check-ins judged it, and which apps and sites took it. Every section follows the filter.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var period: ReportPeriod = .week
    @State private var filter: Set<AllocationGroup> = []
    @State private var report = Report.empty
    @State private var grow: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                PageHeader(title: "Reports", subtitle: report.rangeLabel) {
                    Picker("Period", selection: $period) {
                        ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }

                FilterBar(filter: $filter)

                VStack(alignment: .leading, spacing: 22) {
                    LeadLine(report: report, filter: filter)
                    BalanceBar(totals: report.groupTotals, filter: filter, grow: grow)
                }

                FigureStrip(report: report, filter: filter)

                TimeChart(report: report, period: period, filter: filter, grow: grow)

                HStack(alignment: .top, spacing: 48) {
                    RhythmMap(report: report, filter: filter)
                    CheckinRecord(days: report.days, checkins: model.checkins).frame(width: 380)
                }

                TopSources(report: report, filter: filter, grow: grow)
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 38).padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task(id: period) { await load() }
        .onChange(of: filter) { replayGrow() }
    }

    private func load() async {
        let r = await Report.build(period: period, store: model.store)
        withAnimation(.snappy(duration: 0.35)) { report = r }
        replayGrow()
    }

    /// The one authored motion: bars and the balance bar rise from the baseline when data or the filter changes.
    private func replayGrow() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { grow = 0 }
        withAnimation(.spring(duration: 0.9, bounce: 0.18).delay(0.05)) { grow = 1 }
    }
}

// MARK: - Filter

private struct FilterBar: View {
    @Binding var filter: Set<AllocationGroup>

    var body: some View {
        HStack(spacing: 8) {
            Chip(title: "Everything", selected: filter.isEmpty) { set([]) }
            Chip(title: "Productive", selected: filter == AllocationGroup.productive) { set(AllocationGroup.productive) }
            Chip(title: "Distractions", selected: filter == AllocationGroup.distractions) { set(AllocationGroup.distractions) }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 6)
            ForEach(AllocationGroup.charted, id: \.self) { g in
                Chip(title: g.shortName, dot: g.color, selected: filter.contains(g)) {
                    var next = filter
                    if next.contains(g) { next.remove(g) } else { next.insert(g) }
                    set(next)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func set(_ s: Set<AllocationGroup>) { withAnimation(.snappy(duration: 0.3)) { filter = s } }
}

private struct Chip: View {
    var title: String
    var dot: Color? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(selected ? Theme.window : (hover ? Theme.ink : Theme.inkSecondary))
            .background(selected ? Theme.ink : (hover ? Theme.surfaceRaised : Theme.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The groups a section should count: the filter, or every charted group when nothing is picked.
private func active(_ filter: Set<AllocationGroup>) -> Set<AllocationGroup> { filter.isEmpty ? Set(AllocationGroup.charted) : filter }

// MARK: - Lead

/// The period in one sentence: how much, how much of it was work, learning and reading, and the trend.
private struct LeadLine: View {
    var report: Report
    var filter: Set<AllocationGroup>

    var body: some View {
        let all = report.total(Set(AllocationGroup.charted))
        let prevAll = report.total(Set(AllocationGroup.charted), previous: true)
        let groups = filter.isEmpty ? AllocationGroup.productive : filter
        let share = all > 0 ? report.total(groups) / all : 0
        let prevShare = prevAll > 0 ? report.total(groups, previous: true) / prevAll : 0
        let delta = Int(((share - prevShare) * 100).rounded())
        let subject = filter.isEmpty ? "on work, learning and reading" : "on \(names(filter))"
        let good = filter.isDisjoint(with: AllocationGroup.distractions) ? delta >= 0 : delta <= 0
        let tone = prevAll < 60 || delta == 0 ? Theme.inkSecondary : (good ? Theme.onTrack : Theme.offTrack)

        if !report.loaded || all < 60 {
            Text(report.loaded ? "Nothing tracked in this period yet." : " ")
                .font(.system(size: 26, weight: .semibold)).tracking(-0.5).foregroundStyle(Theme.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                (Text(Fmt.duration(all)).foregroundColor(Theme.ink)
                 + Text(" engaged, ").foregroundColor(Theme.inkSecondary)
                 + Text("\(Int((share * 100).rounded()))%").foregroundColor(Theme.ink)
                 + Text(" of it \(subject).").foregroundColor(Theme.inkSecondary))
                    .font(.system(size: 30, weight: .bold)).tracking(-0.8)
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if prevAll >= 60 && delta != 0 {
                        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 12, weight: .bold))
                        Text("\(abs(delta)) points \(delta > 0 ? "more" : "less") than \(report.hourly ? "yesterday" : "the period before")")
                    } else if prevAll >= 60 {
                        Text("The same share as the period before")
                    } else {
                        Text("No earlier period to compare yet")
                    }
                    if report.uncertain >= 60 {
                        Text("·").foregroundStyle(Theme.inkTertiary)
                        Text("\(Fmt.duration(report.uncertain)) uncertain, not counted").foregroundStyle(Theme.inkTertiary)
                    }
                }
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(tone)
            }
        }
    }

    private func names(_ s: Set<AllocationGroup>) -> String {
        if s == AllocationGroup.distractions { return "video, games and social media" }
        let list = AllocationGroup.charted.filter { s.contains($0) }.map { $0.displayName.lowercased() }
        return list.count <= 2 ? list.joined(separator: " and ") : list.dropLast().joined(separator: ", ") + " and " + list.last!
    }
}

/// Where the time went, as one proportional bar. Hover a segment to read it; filtered-out groups recede.
private struct BalanceBar: View {
    var totals: [AllocationGroup: TimeInterval]
    var filter: Set<AllocationGroup>
    var grow: Double
    @State private var hovered: AllocationGroup?

    var body: some View {
        let groups = AllocationGroup.charted.filter { (totals[$0] ?? 0) > 0 }
        let sum = groups.reduce(0) { $0 + (totals[$1] ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let gap: CGFloat = 3
                let usable = geo.size.width - gap * CGFloat(max(groups.count - 1, 0))
                HStack(spacing: gap) {
                    ForEach(groups, id: \.self) { g in
                        let on = active(filter).contains(g)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(g.color.opacity(on ? (hovered == g ? 0.95 : 0.68) : 0.16))
                            .frame(width: max(4, usable * (totals[g] ?? 0) / max(sum, 1)))
                            .scaleEffect(x: 1, y: hovered == g ? 1.25 : 1, anchor: .bottom)
                            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? g : (hovered == g ? nil : hovered) } }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * grow) }
            }
            .frame(height: 22)

            HStack(spacing: 18) {
                ForEach(groups, id: \.self) { g in
                    let on = active(filter).contains(g)
                    HStack(spacing: 6) {
                        Circle().fill(g.color).frame(width: 7, height: 7)
                        Text(g.displayName).foregroundStyle(hovered == g || on ? Theme.ink : Theme.inkTertiary)
                        Text(Fmt.duration(totals[g] ?? 0)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
                    }
                    .font(.system(size: 12, weight: hovered == g ? .semibold : .medium))
                    .opacity(on || hovered == g ? 1 : 0.6)
                }
            }
        }
    }
}

// MARK: - Figures

private struct FigureStrip: View {
    var report: Report
    var filter: Set<AllocationGroup>

    var body: some View {
        let groups = active(filter)
        let f = report.figures, p = report.previous
        let hours = f.engaged / 3600, prevHours = p.engaged / 3600
        OpenSection {
            HStack(alignment: .top, spacing: 0) {
                Figure(label: filter.isEmpty ? "Engaged" : "Filtered time", value: Fmt.duration(report.total(groups)),
                       delta: change(report.total(groups), report.total(groups, previous: true)), better: higherIsBetter(groups))
                divider
                Figure(label: "Longest focus", value: Fmt.duration(f.longestFocus), delta: change(f.longestFocus, p.longestFocus), better: true)
                divider
                Figure(label: "Focus sessions", value: "\(f.sessions)", note: "25 min or more", delta: change(Double(f.sessions), Double(p.sessions)), better: true)
                divider
                Figure(label: "Switches per hour", value: hours > 0 ? String(format: "%.0f", Double(f.switches) / hours) : "–",
                       delta: hours > 0 && prevHours > 0 ? change(Double(f.switches) / hours, Double(p.switches) / prevHours) : nil, better: false)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 64).padding(.horizontal, 28) }

    private func higherIsBetter(_ g: Set<AllocationGroup>) -> Bool { g.isDisjoint(with: AllocationGroup.distractions) }

    private func change(_ now: Double, _ before: Double) -> Double? {
        guard before > 0.0001, report.previous.engaged >= 60 else { return nil }
        return (now - before) / before
    }
}

private struct Figure: View {
    var label: String
    var value: String
    var note: String? = nil
    var delta: Double?
    var better: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            Text(value).font(.system(size: 30, weight: .bold).monospacedDigit()).tracking(-0.6).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                if let delta, abs(delta) >= 0.01 {
                    let up = delta > 0
                    let tone = up == better ? Theme.onTrack : Theme.offTrack
                    HStack(spacing: 3) {
                        Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 9.5, weight: .heavy))
                        Text("\(Int((abs(delta) * 100).rounded()))%").monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .bold)).foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tone.opacity(0.12), in: Capsule())
                }
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary) }
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Time chart

private struct TimeChart: View {
    var report: Report
    var period: ReportPeriod
    var filter: Set<AllocationGroup>
    var grow: Double
    @State private var selected: Date?

    private struct Point: Identifiable { var id: String; var start: Date; var group: AllocationGroup; var hours: Double }

    var body: some View {
        let groups = AllocationGroup.charted.filter { active(filter).contains($0) }
        let points = report.buckets.flatMap { b in
            groups.compactMap { g -> Point? in
                guard let v = b.byGroup[g], v > 0 else { return nil }
                return Point(id: "\(b.start.timeIntervalSince1970)-\(g.rawValue)", start: b.start, group: g, hours: v / 3600 * grow)
            }
        }
        let unit: Calendar.Component = report.hourly ? .hour : .day
        let bucket = selected.flatMap { s in report.buckets.last { $0.start <= s } }

        OpenSection {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(report.hourly ? "Hour by hour" : "Day by day").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    if let bucket {
                        BucketReadout(bucket: bucket, groups: groups, hourly: report.hourly).transition(.opacity)
                    } else {
                        Text("Hover a bar to read it").font(.system(size: 12.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                if points.isEmpty && report.loaded {
                    Text("No time in the selected groups for this period.")
                        .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary).frame(height: 240)
                } else {
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("Time", p.start, unit: unit), y: .value("Hours", p.hours), width: .ratio(period == .month ? 0.7 : 0.55))
                                .foregroundStyle(by: .value("Group", p.group.displayName))
                                .clipShape(RoundedRectangle(cornerRadius: period == .month ? 3 : 5, style: .continuous))
                                .opacity(bucket == nil ? 0.62 : (bucket?.start == p.start ? 0.95 : 0.28))
                        }
                    }
                    .chartForegroundStyleScale(domain: AllocationGroup.charted.map(\.displayName), range: AllocationGroup.charted.map(\.color))
                    .chartLegend(.hidden)
                    .chartXSelection(value: $selected)
                    .chartXScale(domain: report.start...(report.hourly ? (report.buckets.last?.start.addingTimeInterval(3600) ?? report.end) : report.end))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hairline)
                            AxisValueLabel { if let h = v.as(Double.self) { Text("\(h, specifier: "%.0f")h") } }
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: unit, count: period == .month ? 5 : (report.hourly ? 2 : 1))) { _ in
                            AxisValueLabel(format: report.hourly ? .dateTime.hour() : (period == .month ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.abbreviated)),
                                           centered: true)
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .frame(height: 240)
                    .animation(.easeOut(duration: 0.15), value: selected)
                }
            }
        }
    }
}

private struct BucketReadout: View {
    var bucket: Report.Bucket
    var groups: [AllocationGroup]
    var hourly: Bool

    var body: some View {
        let parts = groups.compactMap { g in bucket.byGroup[g].flatMap { $0 >= 60 ? (g, $0) : nil } }.sorted { $0.1 > $1.1 }
        HStack(spacing: 12) {
            Text(hourly ? Fmt.range(bucket.start, bucket.start.addingTimeInterval(3600)) : Fmt.longDay.string(from: bucket.start))
                .foregroundStyle(Theme.ink).fontWeight(.semibold)
            if parts.isEmpty { Text("Nothing tracked").foregroundStyle(Theme.inkTertiary) }
            ForEach(parts.prefix(4), id: \.0) { g, v in
                HStack(spacing: 5) {
                    Circle().fill(g.color).frame(width: 7, height: 7)
                    Text(Fmt.duration(v)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .font(.system(size: 12.5))
    }
}

// MARK: - Rhythm

/// Weekday × hour: when the filtered time happens. Shaded in ink, or in the group's colour when one is picked.
private struct RhythmMap: View {
    var report: Report
    var filter: Set<AllocationGroup>
    @State private var hovered: (Int, Int)?

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let groups = filter.isEmpty ? AllocationGroup.productive : filter
        let grid = (0..<7).map { d in (0..<24).map { h in groups.reduce(0) { $0 + (report.heat[$1]?[d][h] ?? 0) } } }
        let peak = grid.flatMap { $0 }.max() ?? 0
        let tint = groups.count == 1 ? groups.first!.color : Theme.ink
        let hours = activeHours(grid)

        OpenSection {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(filter.isEmpty ? "When you focus" : "When it happens").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(readout(grid, peak: peak)).foregroundStyle(hovered == nil ? Theme.inkSecondary : Theme.ink)
                        .contentTransition(.identity)
                    .font(.system(size: 12.5).monospacedDigit())
                }

                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        GridRow {
                            Text(Self.weekdays[d]).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                .frame(width: 30, alignment: .leading)
                            ForEach(hours, id: \.self) { h in
                                let v = grid[d][h]
                                let level = peak > 0 ? v / peak : 0
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(v > 0 ? tint.opacity(0.14 + 0.86 * level) : Theme.track)
                                    .frame(height: 22)
                                    .overlay {
                                        if hovered.map({ $0 == (d, h) }) ?? false {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.5)
                                        }
                                    }
                                    .onHover { inside in
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            if inside { hovered = (d, h) } else if hovered.map({ $0 == (d, h) }) ?? false { hovered = nil }
                                        }
                                    }
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 30, height: 1)
                        ForEach(hours, id: \.self) { h in
                            Text(h % 3 == 0 ? hourName(h) : "").font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.inkTertiary).fixedSize()
                        }
                    }
                }
                .animation(.easeOut(duration: 0.4), value: filter)
            }
        }
    }

    private func readout(_ grid: [[TimeInterval]], peak: TimeInterval) -> String {
        if let (d, h) = hovered { return "\(Self.weekdays[d]) \(hourName(h)) · \(Fmt.duration(grid[d][h]))" }
        if peak > 0, let best = bestCell(grid) { return "Peak: \(Self.weekdays[best.0]) around \(hourName(best.1))" }
        return "Not enough data yet"
    }

    /// The waking span worth showing: 7 to 23, widened to include any tracked hour.
    private func activeHours(_ grid: [[TimeInterval]]) -> [Int] {
        let used = (0..<24).filter { h in grid.contains { $0[h] > 0 } }
        return Array(min(7, used.min() ?? 7)...max(23, used.max() ?? 23))
    }

    private func bestCell(_ grid: [[TimeInterval]]) -> (Int, Int)? {
        var best: (Int, Int, TimeInterval)?
        for d in 0..<7 { for h in 0..<24 where grid[d][h] > (best?.2 ?? 0) { best = (d, h, grid[d][h]) } }
        return best.map { ($0.0, $0.1) }
    }

    private func hourName(_ h: Int) -> String {
        Fmt.hour.string(from: Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date())
    }
}

// MARK: - Check-in record

/// Every scheduled check-in slot in the period, coloured by its verdict.
private struct CheckinRecord: View {
    @Environment(AppModel.self) private var model
    var days: [Date]
    var checkins: [AtlasStore.Checkin]
    @State private var hovered: AtlasStore.Checkin.ID?

    /// Rows: the scheduled hours, plus any hour a recorded check-in fell in.
    private var slotHours: [Int] {
        let chosen = model.settings.checkinPlan.hours
        return chosen.isEmpty ? CheckinPlan().hours : chosen.sorted()
    }

    var body: some View {
        let cal = Calendar.current
        let inRange = checkins.filter { c in days.contains { cal.isDate($0, inSameDayAs: c.ts) } }
        let counts = Dictionary(grouping: inRange) { Verdict($0.verdict) }.mapValues(\.count)
        let judged = [Verdict.onTrack, .mixed, .offTrack].reduce(0) { $0 + (counts[$1] ?? 0) }
        let hoveredCheckin = inRange.first { $0.id == hovered }

        OpenSection {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Check-in record").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    if judged > 0 {
                        Text("\(counts[.onTrack] ?? 0) of \(judged) on track").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                    }
                }

                if inRange.isEmpty {
                    Text("No check-ins in this period. Choose when they happen in Settings → Check-ins.")
                        .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    // Proportion of verdicts.
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            ForEach([Verdict.onTrack, .mixed, .offTrack], id: \.self) { v in
                                if let n = counts[v], n > 0 {
                                    Capsule().fill(v.color).frame(width: max(6, (geo.size.width - 6) * Double(n) / Double(max(judged, 1))))
                                }
                            }
                        }
                    }
                    .frame(height: 8)

                    // Slots: one column per day, one row per scheduled hour.
                    let size: CGFloat = days.count > 7 ? 9 : 26
                    let spacing: CGFloat = days.count > 7 ? 3 : 6
                    HStack(alignment: .top, spacing: spacing) {
                        VStack(alignment: .trailing, spacing: spacing) {
                            ForEach(slotHours, id: \.self) { h in
                                Text("\(h)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                                    .frame(height: size)
                            }
                        }
                        .frame(width: 18)
                        ForEach(days, id: \.self) { day in
                            VStack(spacing: spacing) {
                                ForEach(slotHours, id: \.self) { h in
                                    let c = inRange.first { cal.isDate($0.ts, inSameDayAs: day) && nearestSlot($0.ts) == h }
                                    let v = Verdict(c?.verdict)
                                    RoundedRectangle(cornerRadius: size > 12 ? 7 : 2.5, style: .continuous)
                                        .fill(c == nil ? Theme.track : v.color.opacity(hovered == nil || hovered == c?.id ? 1 : 0.45))
                                        .frame(width: size, height: size)
                                        .overlay {
                                            if c != nil && size > 12 {
                                                Image(systemName: v.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.window.opacity(0.9))
                                            }
                                        }
                                        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { if inside { hovered = c?.id } else if hovered == c?.id { hovered = nil } } }
                                }
                            }
                        }
                    }

                    Group {
                        if let c = hoveredCheckin {
                            let parts = CheckinParts(c.body)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(Verdict(c.verdict).title) · \(Fmt.dayTime.string(from: c.ts))")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Verdict(c.verdict).color)
                                Text(parts.headline).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(3)
                            }
                        } else {
                            HStack(spacing: 14) {
                                ForEach([Verdict.onTrack, .mixed, .offTrack], id: \.self) { v in
                                    HStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 2.5).fill(v.color).frame(width: 9, height: 9)
                                        Text("\(v.title) \(counts[v] ?? 0)").monospacedDigit()
                                    }
                                }
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .frame(minHeight: 44, alignment: .topLeading)
                }
            }
        }
    }

    private func nearestSlot(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let t = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return slotHours.min { abs(Double($0) - t) < abs(Double($1) - t) } ?? 9
    }
}

// MARK: - Top sources

/// Apps and sites ranked by time, within the filter.
private struct TopSources: View {
    var report: Report
    var filter: Set<AllocationGroup>
    var grow: Double

    var body: some View {
        let groups = active(filter)
        let rows = Array(report.sources.filter { groups.contains($0.category.allocationGroup) }.prefix(8))
        let top = rows.first?.time ?? 1
        OpenSection {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Top apps and sites", detail: rows.isEmpty ? nil : "\(rows.count) of \(report.sources.filter { groups.contains($0.category.allocationGroup) }.count)")
                if rows.isEmpty {
                    Text("Nothing in the selected groups yet.").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 48), GridItem(.flexible(), spacing: 48)], alignment: .leading, spacing: 14) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 12) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.inkTertiary).frame(width: 16, alignment: .trailing)
                            Image(systemName: s.category.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(s.category.color)
                                .frame(width: 28, height: 28)
                                .background(s.category.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(s.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(s.category.displayName).font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.duration(s.time)).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                                }
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.track)
                                        Capsule().fill(s.category.color).frame(width: max(4, g.size.width * s.time / top * grow))
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                }
            }
        }
    }
}
