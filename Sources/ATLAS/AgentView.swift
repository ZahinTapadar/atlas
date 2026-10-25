import AtlasCore
import SwiftUI

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedWindow: String?
    @State private var payload: PayloadSheet.Item?
    @State private var editingAction: AgentAction?

    var body: some View {
        HSplitView {
            windowList.frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            ScrollView { detail.padding(18) }.frame(minWidth: 520)
        }
        .navigationTitle("Agent")
        .sheet(item: $payload) { PayloadSheet(item: $0) }
        .sheet(item: $editingAction) { a in ActionEditor(action: a) { model.approve(a, edited: $0) } }
        .onAppear {
            if selectedWindow == nil {
                selectedWindow = model.checkins.isEmpty ? (model.latestAnalyzed?.window.id ?? model.windows.first?.id) : "checkins"
            }
        }
    }

    private var windowList: some View {
        List(selection: $selectedWindow) {
            if !model.checkins.isEmpty {
                Text("Check-ins").tag("checkins").font(.headline)
            }
            if !model.pendingActions.isEmpty {
                Label("\(model.pendingActions.count) change(s) awaiting approval", systemImage: "hand.raised").foregroundStyle(.orange)
            }
            ForEach(model.windows.filter { $0.status != .open }) { w in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.dayTime.string(from: w.start)).font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        Text(w.kind.rawValue.capitalized)
                        Text("· \(Fmt.duration(w.awakeSeconds)) awake")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    StatusChip(status: w.status)
                }
                .tag(w.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if selectedWindow == "checkins" || (selectedWindow == nil && !model.checkins.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Scheduled check-ins").font(.title2.weight(.semibold))
                Text("Written by your scheduled Claude task after reading this tracker, your calendar and your daily briefing.")
                    .foregroundStyle(.secondary)
                ForEach(model.checkins) { c in
                    Card(title: Fmt.dayTime.string(from: c.ts), systemImage: "bubble.left.and.text.bubble.right") {
                        VerdictChip(verdict: c.verdict)
                        Text((try? AttributedString(markdown: c.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(c.body))
                            .textSelection(.enabled)
                    }
                }
            }
        } else if let id = selectedWindow, let w = model.windows.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(w.kind.rawValue.capitalized) window").font(.title2.weight(.semibold))
                        Text("\(Fmt.dayTime.string(from: w.start)) – \(w.end.map { Fmt.time.string(from: $0) } ?? "now") · \(Fmt.duration(w.awakeSeconds)) awake")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("What was sent") { Task { payload = .init(id: w.id, text: await model.payloadPreview(windowID: w.id) ?? "Nothing prepared yet") } }
                    switch w.status {
                    case .awaitingReview:
                        Button("Approve & Send") { model.approveSend(windowID: w.id) }.buttonStyle(.borderedProminent)
                        Button("Discard") { model.discard(windowID: w.id) }
                    case .failed, .abandoned:
                        Button("Retry now") { model.retryWindow(w.id) }
                    case .analyzed:
                        Button("Reanalyze") { model.reanalyze(windowID: w.id) }.help("Sends this window again (new request)")
                    default: EmptyView()
                    }
                }
                if let err = w.lastError, w.status != .analyzed {
                    Label("\(err)\(w.nextAttemptAt.map { " · next attempt \(Fmt.time.string(from: $0))" } ?? "")",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let json = w.resultJSON, let a = try? AtlasJSON.decode(ValidatedAnalysis.self, from: json) {
                    AnalysisDetail(window: w, analysis: a, actions: model.recentActions.filter { $0.windowID == w.id },
                                   onEdit: { editingAction = $0 })
                } else if w.status == .skipped {
                    Text("Skipped: too little awake time to analyze meaningfully.").foregroundStyle(.secondary)
                } else {
                    Text(model.agentReady ? "Not analyzed yet." : "Not analyzed yet — \(model.agentSetupHint). Activity is kept locally until then.")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ContentUnavailableView("No analyses yet", systemImage: "sparkles",
                                   description: Text("Windows appear here after each \(Fmt.duration(model.settings.analysisIntervalSeconds)) of awake time."))
        }
    }
}

struct StatusChip: View {
    var status: WindowStatus
    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .analyzed: ("Analyzed", .green)
        case .ready: ("Queued", .blue)
        case .awaitingReview: ("Needs review", .orange)
        case .sending: ("Analyzing…", .purple)
        case .failed: ("Retrying", .orange)
        case .abandoned: ("Abandoned", .secondary)
        case .skipped: ("Skipped", .secondary)
        case .open: ("Open", .secondary)
        }
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct AnalysisDetail: View {
    @Environment(AppModel.self) private var model
    var window: AnalysisWindow
    var analysis: ValidatedAnalysis
    var actions: [AgentAction]
    var onEdit: (AgentAction) -> Void

    var body: some View {
        let r = analysis.result
        Card(title: "What happened", systemImage: "text.alignleft") {
            Text(r.summary).textSelection(.enabled)
            ForEach(r.chronology, id: \.self) { c in
                HStack(alignment: .firstTextBaseline) {
                    Text(shortTime(c.start) + "–" + shortTime(c.end)).font(.caption.monospacedDigit()).frame(width: 96, alignment: .leading)
                    Text(c.activity)
                    if c.evidenceLevel != "observed" {
                        Text(c.evidenceLevel).font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    if !c.note.isEmpty { Text(c.note).font(.caption).foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
            if !r.allocationNotes.isEmpty { Text(r.allocationNotes).font(.callout).foregroundStyle(.secondary) }
        }
        rubricCard
        if !r.findings.isEmpty {
            Card(title: "Findings", systemImage: "lightbulb") {
                ForEach(r.findings, id: \.self) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(f.description, systemImage: f.kind == "positive" ? "hand.thumbsup" : "exclamationmark.circle")
                        Text("\(f.kind.replacingOccurrences(of: "_", with: " ")) · \(f.severity) · \(f.evidence)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !r.planAssessment.isEmpty {
            Card(title: "Plan vs. actual", systemImage: "checklist") {
                ForEach(r.planAssessment, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.title)
                        Spacer()
                        Text("\(p.assessedStatus.replacingOccurrences(of: "_", with: " ")) (\(Int(p.confidence * 100))%)")
                            .foregroundStyle(.secondary)
                        if p.assessedStatus == "completed" || p.assessedStatus == "partial",
                           let item = model.planItems.first(where: { $0.id == p.planItemID }), item.status != .completed {
                            Button("Confirm done") {
                                var q = item; q.status = .completed; q.userConfirmed = true; model.savePlan(q)
                            }.controlSize(.small)
                        }
                    }
                    .font(.callout)
                    Text(p.evidence).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !r.nextPlan.isEmpty {
            Card(title: "Suggested next period", systemImage: "calendar.badge.clock") {
                ForEach(r.nextPlan, id: \.self) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(t.suggestedStart.isEmpty ? "Unscheduled" : shortTime(t.suggestedStart) + "–" + shortTime(t.suggestedEnd))
                                .font(.caption.monospacedDigit()).frame(width: 96, alignment: .leading)
                            Text(t.title).font(.callout.weight(.medium))
                            Text("P\(t.priority) · \(t.estimatedMinutes)m").font(.caption).foregroundStyle(.secondary)
                            if t.deferrable { Text("deferrable").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(t.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Card(title: "Proposed changes", systemImage: "arrow.triangle.2.circlepath") {
            if actions.isEmpty { Text("No changes proposed.").foregroundStyle(.secondary) }
            ForEach(actions) { a in ActionRow(action: a, onEdit: onEdit) }
        }
        if !r.uncertainties.isEmpty || !analysis.validationNotes.isEmpty || !r.assessment.caveats.isEmpty {
            Card(title: "Uncertainty & validation", systemImage: "questionmark.diamond") {
                ForEach(r.uncertainties, id: \.self) { Text("• \($0)").font(.callout) }
                if !r.assessment.caveats.isEmpty { Text(r.assessment.caveats).font(.callout) }
                ForEach(analysis.validationNotes, id: \.self) { Label($0, systemImage: "shield.lefthalf.filled").font(.caption) }
            }
        }
        if !r.reasoning.isEmpty {
            DisclosureGroup("Agent reasoning") { Text(r.reasoning).font(.callout).textSelection(.enabled) }
        }
    }

    private var rubricCard: some View {
        Card(title: "How the time was used", systemImage: "gauge") {
            let rubric = (try? window.requestPayload.map { try AtlasJSON.decode(ActivityPackage.self, from: $0) })??.rubric
            if let rubric {
                if let score = rubric.score {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%.0f", score)).font(.system(size: 34, weight: .semibold).monospacedDigit())
                        Text("/ 100 · computed locally from your weights").foregroundStyle(.secondary)
                    }
                } else {
                    Label("Insufficient data for a score", systemImage: "chart.bar.xaxis").font(.headline)
                }
                ForEach(rubric.components, id: \.name) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.name).frame(width: 170, alignment: .leading)
                        Text(c.value.map { "\(Int($0 * 100))%" } ?? "n/a").monospacedDigit().frame(width: 44)
                        Text("w \(Int(c.effectiveWeight * 100))%").font(.caption).foregroundStyle(.secondary).frame(width: 50)
                        Text(c.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                ForEach(rubric.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            Text(analysis.result.assessment.summary).font(.callout)
        }
    }

    private func shortTime(_ iso: String) -> String {
        AgentResultValidator.parseDate(iso).map { Fmt.time.string(from: $0) } ?? iso
    }
}

struct ActionRow: View {
    @Environment(AppModel.self) private var model
    var action: AgentAction
    var onEdit: (AgentAction) -> Void

    var body: some View {
        let a = action
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon(a.kind))
                Text(a.intendedState.title).font(.callout.weight(.medium))
                Spacer()
                Text(statusText(a)).font(.caption).foregroundStyle(statusColor(a))
            }
            // Clear diff: before → after
            if let prev = a.previousState, prev.start != nil || prev.planStatus != nil {
                Text("Before: \(describe(prev))").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(a.previousState == nil ? "Create" : "After"): \(describe(a.intendedState))").font(.caption)
            Text(a.rationale).font(.caption).foregroundStyle(.secondary)
            if let res = a.result { Text(res).font(.caption2).foregroundStyle(.secondary) }
            HStack {
                if a.authorization == .pending {
                    Button("Approve") { model.approve(a) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Edit…") { onEdit(a) }.controlSize(.small)
                    Button("Reject", role: .destructive) { model.reject(a) }.controlSize(.small)
                }
                if a.execution == .failed { Button("Retry") { model.retry(a) }.controlSize(.small) }
                if a.execution == .succeeded && a.kind != .createReminder {
                    Button("Undo") { model.rollback(a) }.controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func describe(_ c: ProposedChange) -> String {
        var parts: [String] = []
        if let s = c.start { parts.append(Fmt.dayTime.string(from: s) + (c.end.map { "–" + Fmt.time.string(from: $0) } ?? "")) }
        if let st = c.planStatus { parts.append(st.rawValue) }
        if parts.isEmpty { parts.append(c.title) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ k: AgentActionKind) -> String {
        switch k {
        case .createFocusBlock: "scope"
        case .createBreak: "cup.and.saucer"
        case .rescheduleTask: "calendar.badge.clock"
        case .createReminder: "bell"
        case .moveEvent: "arrow.left.and.right"
        case .updatePlanItem: "pencil"
        case .splitTask: "square.split.2x1"
        }
    }

    private func statusText(_ a: AgentAction) -> String {
        switch a.authorization {
        case .pending: return "Awaiting approval"
        case .rejected: return "Rejected"
        case .blockedByPolicy: return "Blocked by policy"
        case .approved, .autoApproved:
            let who = a.authorization == .autoApproved ? "Auto" : "Approved"
            return "\(who) · \(a.execution.rawValue.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func statusColor(_ a: AgentAction) -> Color {
        if a.authorization == .pending { return .orange }
        if a.execution == .succeeded { return .green }
        if a.execution == .failed { return .red }
        return .secondary
    }
}

struct ActionEditor: View {
    @State var action: AgentAction
    var onApprove: (ProposedChange) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Title", text: $action.intendedState.title)
            if action.intendedState.start != nil {
                DatePicker("Start", selection: Binding(get: { action.intendedState.start ?? Date() }, set: { action.intendedState.start = $0 }))
                DatePicker("End", selection: Binding(get: { action.intendedState.end ?? Date() }, set: { action.intendedState.end = $0 }))
            }
            Text(action.rationale).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Approve Edited") { onApprove(action.intendedState); dismiss() } }
        }
        .frame(width: 420, height: 300)
    }
}

struct PayloadSheet: View {
    struct Item: Identifiable { var id: String; var text: String }
    var item: Item
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text("Exactly what is (or will be) sent to Claude for this window").font(.headline)
            Text("\(item.text.utf8.count) bytes. Excluded apps/sites appear only as “excluded”; full URLs and document contents are never included unless you enabled them.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(prettify(item.text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Color(nsColor: .textBackgroundColor))
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 720, height: 560)
    }
    private func prettify(_ s: String) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return s }
        return String(decoding: d, as: UTF8.self)
    }
}
