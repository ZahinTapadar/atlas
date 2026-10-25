import AtlasCore
import SwiftUI

/// Today: the verdict leads, everything else is evidence.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    var goTo: (AppSection) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                PageHeader(title: "Today", subtitle: Fmt.longDay.string(from: Date())) {
                    HStack(spacing: 10) {
                        NowCapsule()
                        Button { model.runManualAnalysis() } label: {
                            Label(model.agentBusy ? "Analyzing…" : "Check in now", systemImage: "sparkles")
                        }
                        .buttonStyle(InkButtonStyle())
                        .disabled(model.agentBusy)
                        .help("Ask Claude for a check-in on today so far")
                    }
                }

                if !DemoData.isEnabled && model.setupStepsRemaining > 0 {
                    SetupNudge(remaining: model.setupStepsRemaining) { model.showOnboarding = true }
                }

                VerdictPanel(checkin: model.checkins.first) { goTo(.checkins) }

                if model.thingsProblem == "" {
                    ThingsToday()
                } else if let latest = model.checkins.first(where: { Calendar.current.isDateInToday($0.ts) && !$0.todos.isEmpty }) {
                    TodayTodos(checkin: latest)
                }

                DayRibbon(events: model.todayEvents)

                HStack(alignment: .top, spacing: 48) {
                    TimeByCategory()
                    VStack(spacing: 28) {
                        FocusFigures()
                        RecentActivity { goTo(.timeline) }
                    }
                    .frame(width: 340)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 38)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task { await model.refresh() }
        .task {
            // Things changes outside ATLAS; keep the list current while Today is open.
            while !Task.isCancelled {
                await model.refreshThings()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }
}

/// Shown on Today until the essential setup steps are done.
struct SetupNudge: View {
    var remaining: Int
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.mixed)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setting up check-ins").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(remaining) step\(remaining == 1 ? "" : "s") left: Claude, your check-in schedule and where to send them.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Open setup", action: open).buttonStyle(InkButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.mixed.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.mixed.opacity(0.25)))
    }
}

/// Live capsule: what is being tracked this minute.
struct NowCapsule: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            if let c = model.current, model.settings.trackingEnabled {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.live.opacity(0.5), lineWidth: 6).scaleEffect(pulse ? 1.6 : 0.6).opacity(pulse ? 0 : 1))
                    .onAppear { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true } }
                Text(c.displayLabel).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(c.classification.category.displayName).font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                Text(Fmt.duration(Date().timeIntervalSince(c.start))).font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                Circle().fill(Theme.inkTertiary).frame(width: 7, height: 7)
                Text(model.settings.trackingEnabled ? "Waiting for activity" : "Tracking paused")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .frame(maxWidth: 420, alignment: .trailing)
    }
}

/// The verdict: the one tinted field on the screen.
struct VerdictPanel: View {
    var checkin: AtlasStore.Checkin?
    var openAll: () -> Void

    var body: some View {
        let verdict = Verdict(checkin?.verdict)
        let parts = checkin.map { CheckinParts($0.body) }
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: verdict.symbol).font(.system(size: 30, weight: .semibold))
                    Text(verdict.title).font(.system(size: 44, weight: .bold)).tracking(-1.2)
                }
                .foregroundStyle(verdict.color)

                if let parts {
                    Text(parts.headline).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.ink)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 640, alignment: .leading)
                    if !parts.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(parts.evidence.prefix(3), id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(verdict.color.opacity(0.7)).frame(width: 4, height: 4).offset(y: -3)
                                    Text(line).font(.system(size: 13.5)).foregroundStyle(Theme.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                    }
                    if let next = parts.next {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(next.components(separatedBy: "\n").enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "arrow.forward").font(.system(size: 12, weight: .bold)).foregroundStyle(verdict.color)
                                    Text(step).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 4)
                    }
                } else {
                    Text("Your scheduled Claude check-in reads this tracker, your calendar and your daily briefing, then lands here.")
                        .font(.system(size: 15)).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 560, alignment: .leading)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 18) {
                if let checkin {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.time.string(from: checkin.ts)).font(.system(size: 20, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                        Text("check-in").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                if let next = CheckinSchedule.next() {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.time.string(from: next)).font(.system(size: 15, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                        Text("next").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                Button("All check-ins", action: openAll).buttonStyle(InkButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(verdict.color.opacity(0.10))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(verdict.color.opacity(0.22)))
    }
}

/// The day in ten-minute cells. Hover a cell to read it; the current cell breathes while tracking.
struct DayRibbon: View {
    @Environment(AppModel.self) private var model
    var events: [ActivityEvent]
    @State private var hovered: Int?
    @State private var breathe = false

    struct Cell { var start: Date; var category: ActivityCategory?; var engaged: Bool; var label: String? }

    private var range: (Date, Date) {
        let now = Date()
        let first = events.filter { $0.state.isEngaged }.map(\.start).min() ?? now.addingTimeInterval(-3 * 3600)
        let cal = Calendar.current
        let startHour = cal.dateInterval(of: .hour, for: first)?.start ?? first
        let endHour = cal.date(byAdding: .hour, value: 1, to: cal.dateInterval(of: .hour, for: now)?.start ?? now) ?? now
        return (startHour, max(endHour, startHour.addingTimeInterval(4 * 3600)))
    }

    private func cells() -> [Cell] {
        let (start, end) = range
        let step: TimeInterval = 600
        let normalized = TimeAccounting.normalized(events, from: start, to: end)
        var out: [Cell] = []
        var t = start
        while t < end {
            let iv = DateInterval(start: t, duration: step)
            var best: (ActivityCategory, TimeInterval, String)? = nil
            var engagedTime: TimeInterval = 0
            var byCat: [ActivityCategory: (TimeInterval, String)] = [:]
            for e in normalized where e.end > iv.start && e.start < iv.end {
                let overlap = min(e.end, iv.end).timeIntervalSince(max(e.start, iv.start))
                guard e.state.isEngaged else { continue }
                engagedTime += overlap
                let cat = e.privacy == .excluded ? ActivityCategory.unknown : e.classification.category
                let prev = byCat[cat]?.0 ?? 0
                byCat[cat] = (prev + overlap, prev >= overlap ? (byCat[cat]?.1 ?? e.displayLabel) : e.displayLabel)
            }
            for (cat, v) in byCat where v.0 > (best?.1 ?? 0) { best = (cat, v.0, v.1) }
            out.append(Cell(start: t, category: best?.0, engaged: engagedTime > step * 0.3, label: best?.2))
            t = t.addingTimeInterval(step)
        }
        return out
    }

    var body: some View {
        let cells = cells()
        let now = Date()
        let currentIndex = cells.lastIndex { $0.start <= now }
        OpenSection {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("The day so far").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    if let h = hovered, h < cells.count {
                        let c = cells[h]
                        HStack(spacing: 8) {
                            Text("\(Fmt.time.string(from: c.start))–\(Fmt.time.string(from: c.start.addingTimeInterval(600)))")
                                .monospacedDigit().foregroundStyle(Theme.inkTertiary)
                            if let cat = c.category, c.engaged {
                                Circle().fill(cat.color).frame(width: 7, height: 7)
                                Text(c.label ?? cat.displayName).foregroundStyle(Theme.ink)
                                Text(cat.displayName).foregroundStyle(Theme.inkSecondary)
                            } else {
                                Text(c.start > now ? "Later today" : "Away or idle").foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        .font(.system(size: 12.5))
                        .transition(.opacity)
                    } else {
                        Text("Hover to read a moment").font(.system(size: 12.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }

                GeometryReader { geo in
                    let gap: CGFloat = 3
                    let w = max(2, (geo.size.width - gap * CGFloat(cells.count - 1)) / CGFloat(max(cells.count, 1)))
                    HStack(spacing: gap) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                            let future = c.start > now
                            RoundedRectangle(cornerRadius: min(5, w / 2), style: .continuous)
                                .fill(future ? Theme.track.opacity(0.5) : (c.engaged ? (c.category?.color ?? Theme.track) : Theme.track))
                                .frame(width: w, height: hovered == i ? 50 : 42)
                                .opacity(i == currentIndex && model.settings.trackingEnabled ? (breathe ? 0.55 : 1) : 1)
                                .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside ? i : (hovered == i ? nil : hovered) } }
                        }
                    }
                    .frame(height: 50, alignment: .bottom)
                }
                .frame(height: 50)
                .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true } }

                // Hour guide words under the ribbon.
                GeometryReader { geo in
                    let hours = cells.indices.filter { Calendar.current.component(.minute, from: cells[$0].start) == 0 }
                    ZStack(alignment: .topLeading) {
                        ForEach(hours, id: \.self) { i in
                            Text(Fmt.hour.string(from: cells[i].start))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.inkTertiary)
                                .offset(x: geo.size.width * CGFloat(i) / CGFloat(max(cells.count, 1)))
                        }
                    }
                }
                .frame(height: 14)
            }
        }
    }
}

/// Where the time went: categories ranked by engaged minutes.
struct TimeByCategory: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let totals = model.todayTotals.filter { $0.0 != .idle }
        let sum = totals.reduce(0) { $0 + $1.1 }
        OpenSection {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Where the time went", detail: sum > 0 ? "\(Fmt.duration(sum)) engaged" : nil)
                if totals.isEmpty {
                    Text("Nothing tracked yet today. Activity appears here as you work.")
                        .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(totals, id: \.0) { CategoryLegendRow(category: $0.0, observed: $0.1, inferred: $0.2, total: totals.first?.1 ?? sum) }
                    }
                }
            }
        }
    }
}

/// Focus figures, set as a definition list rather than tiles.
struct FocusFigures: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let st = model.todayStateTotals
        let start = Calendar.current.startOfDay(for: Date())
        let focus = FocusMetrics.compute(TimeAccounting.normalized(model.todayEvents, from: start, to: Date()))
        let perHour = st.active > 0 ? Double(focus.switches) / (st.active / 3600) : 0
        let unclassified = model.todayTotals.first { $0.0 == .unknown }?.1 ?? 0
        OpenSection {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeading(title: "Focus").padding(.bottom, 8)
                FigureRow(label: "Active", value: Fmt.duration(st.active))
                FigureRow(label: "Longest focus", value: Fmt.duration(focus.longestFocus))
                FigureRow(label: "Switches", value: "\(focus.switches)", note: st.active > 0 ? String(format: "%.0f per hour", perHour) : nil)
                FigureRow(label: "Passive (inferred)", value: Fmt.duration(st.passive))
                FigureRow(label: "Unclassified", value: Fmt.duration(unclassified), dim: unclassified < 60)
                FigureRow(label: "Idle or away", value: Fmt.duration(st.idle), last: true)
            }
        }
    }
}

private struct FigureRow: View {
    var label: String
    var value: String
    var note: String? = nil
    var dim = false
    var last = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary) }
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(dim ? Theme.inkTertiary : Theme.ink)
            }
            .padding(.vertical, 8)
            if !last { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

/// The last few things, newest first.
struct RecentActivity: View {
    @Environment(AppModel.self) private var model
    var openTimeline: () -> Void
    var body: some View {
        let recent = model.todayEvents.filter { $0.state.isEngaged && $0.duration >= 60 }
            .sorted { $0.start > $1.start }.prefix(5)
        OpenSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Timeline", action: openTimeline).buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                if recent.isEmpty {
                    Text("No activity yet.").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(Array(recent)) { e in
                    HStack(spacing: 10) {
                        Image(systemName: e.classification.category.icon).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(e.classification.category.color)
                            .frame(width: 26, height: 26)
                            .background(e.classification.category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.displayLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(Fmt.time.string(from: e.start)) · \(e.classification.category.displayName)")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.duration(e.duration)).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
    }
}

/// What was supposed to happen today and what did, as judged by the latest check-in (mirrors Things).
struct TodayTodos: View {
    var checkin: AtlasStore.Checkin

    var body: some View {
        let done = checkin.todos.filter { $0.status == "done" }.count
        OpenSection {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Today's to-dos",
                               detail: "\(done) of \(checkin.todos.count) done · as of \(Fmt.time.string(from: checkin.ts)) · synced with Things")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible(), spacing: 32)], alignment: .leading, spacing: 10) {
                    ForEach(Array(checkin.todos.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: symbol(t.status)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(color(t.status)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(t.status == "done" ? Theme.inkSecondary : Theme.ink)
                                    .strikethrough(t.status == "done", color: Theme.inkTertiary)
                                    .lineLimit(2)
                                if let note = t.note, !note.isEmpty {
                                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.inkTertiary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            if let m = t.minutes, m > 0 {
                                Text(Fmt.duration(TimeInterval(m * 60))).font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func symbol(_ s: String) -> String {
        switch s {
        case "done": "checkmark.circle.fill"
        case "in_progress": "circle.lefthalf.filled"
        case "dropped": "minus.circle"
        default: "circle"
        }
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "done": Theme.onTrack
        case "in_progress": Theme.mixed
        default: Theme.inkTertiary
        }
    }
}
