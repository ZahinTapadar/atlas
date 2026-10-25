import AtlasCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                let dayStart = Calendar.current.startOfDay(for: Date())
                Card(title: "Today", systemImage: "calendar.day.timeline.left") {
                    DayStrip(events: model.todayEvents, start: dayStart, end: max(Date(), dayStart.addingTimeInterval(3600)))
                    HStack { Text(Fmt.time.string(from: dayStart)); Spacer(); Text("now") }.font(.caption2).foregroundStyle(.secondary)
                    let st = model.todayStateTotals
                    HStack(spacing: 28) {
                        Metric(label: "Active", value: Fmt.duration(st.active))
                        Metric(label: "Passive (inferred)", value: Fmt.duration(st.passive), caption: "reading / watching, no input")
                        Metric(label: "Idle / away", value: Fmt.duration(st.idle))
                        Metric(label: "Uncertain", value: Fmt.duration(st.uncertain), caption: "low-confidence or untracked")
                        Metric(label: "Context switches", value: "\(model.todaySessions.reduce(0) { $0 + $1.contextSwitches })")
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Time by category", systemImage: "chart.pie") {
                        let totals = model.todayTotals
                        let sum = totals.reduce(0) { $0 + $1.1 }
                        if totals.isEmpty { Text("No engaged time recorded yet today.").foregroundStyle(.secondary) }
                        ForEach(totals, id: \.0) { CategoryLegendRow(category: $0.0, observed: $0.1, inferred: $0.2, total: sum) }
                    }
                    VStack(spacing: 14) {
                        nextWindowCard
                        checkinCard
                    }
                    .frame(width: 330)
                }
                HStack(alignment: .top, spacing: 14) {
                    latestAnalysisCard
                    healthCard.frame(width: 330)
                }
            }
            .padding(18)
        }
        .navigationTitle("Dashboard")
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let c = model.current, model.settings.trackingEnabled {
                Image(systemName: c.classification.category.icon).font(.title).foregroundStyle(c.classification.category.color)
                VStack(alignment: .leading) {
                    Text(c.displayLabel).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(c.classification.category.displayName)
                        Text("·")
                        Text(c.state.rawValue.capitalized)
                        Text("· since \(Fmt.time.string(from: c.start))")
                        ConfidenceBadge(classification: c.classification)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "pause.circle").font(.title).foregroundStyle(.secondary)
                Text(model.settings.trackingEnabled ? "Waiting for activity…" : "Tracking is paused").font(.title3)
            }
            Spacer()
        }
    }

    private var nextWindowCard: some View {
        Card(title: "Next analysis", systemImage: "hourglass") {
            let interval = model.settings.analysisIntervalSeconds
            let awake = model.openWindow?.awakeSeconds ?? 0
            ProgressView(value: min(awake, interval), total: interval)
            Text("\(Fmt.duration(model.awakeRemaining)) of awake time remaining")
                .font(.callout)
            Text("Window counts awake time only — sleep, lock and long absences don't advance it.")
                .font(.caption).foregroundStyle(.secondary)
            let queued = model.windows.filter { [.ready, .failed, .awaitingReview].contains($0.status) }
            if !queued.isEmpty && model.settings.automaticWindowAnalysis {
                Label("\(queued.count) window(s) queued\(model.agentReady ? "" : " — \(model.agentSetupHint)")", systemImage: "tray.full")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var checkinCard: some View {
        Card(title: "Latest check-in", systemImage: "bubble.left.and.text.bubble.right") {
            if let c = model.checkins.first {
                HStack {
                    VerdictChip(verdict: c.verdict)
                    Text(Fmt.dayTime.string(from: c.ts)).font(.caption).foregroundStyle(.secondary)
                }
                Text(c.body).font(.callout).lineLimit(8).textSelection(.enabled)
            } else {
                Text("Scheduled Claude check-ins will appear here. They read this tracker through the atlas MCP server and compare it with your calendar and daily briefing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var latestAnalysisCard: some View {
        Card(title: "Latest analysis", systemImage: "sparkles") {
            if let (w, a) = model.latestAnalyzed {
                Text("\(w.kind == .manual ? "Manual" : w.kind == .partial ? "Partial" : "Window") \(Fmt.range(w.start, w.end))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(a.result.summary).textSelection(.enabled)
                if !a.result.mostImportantUnfinishedTask.isEmpty {
                    Label(a.result.mostImportantUnfinishedTask, systemImage: "flag").font(.callout.weight(.medium))
                }
                ForEach(a.result.findings.prefix(3), id: \.self) { f in
                    Label(f.description, systemImage: f.kind == "positive" ? "hand.thumbsup" : "exclamationmark.circle").font(.callout)
                }
            } else {
                Text("No analysis yet. The first one runs after \(Fmt.duration(model.settings.analysisIntervalSeconds)) of awake time, or press Analyze Now.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthCard: some View {
        Card(title: "Tracking health", systemImage: "stethoscope") {
            if model.health.contains(where: { $0.level == .degraded }) {
                Button("Fix permissions…") { model.showOnboarding = true }.controlSize(.small)
            }
            ForEach(model.health) { h in
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(level: h.level)
                    Text(h.name).font(.callout.weight(.medium))
                    Spacer()
                    Text(h.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
    }
}
