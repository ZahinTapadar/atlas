import AtlasCore
import SwiftUI

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PlanItem?
    @State private var showClosed = false

    var body: some View {
        let items = model.planItems.filter { showClosed || ($0.status != .completed && $0.status != .dropped) }
        List {
            ForEach(items) { p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        var q = p
                        q.status = p.status == .completed ? .notStarted : .completed
                        q.userConfirmed = true
                        model.savePlan(q)
                    } label: {
                        Image(systemName: p.status == .completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(p.status == .completed ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mark complete (only you can confirm completion)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).strikethrough(p.status == .completed)
                        HStack(spacing: 8) {
                            Text("P\(p.priority)")
                            Text(Fmt.duration(TimeInterval(p.expectedMinutes * 60)))
                            if let d = p.deadline { Text("due \(Fmt.dayTime.string(from: d))") }
                            if let s = p.plannedStart { Text("planned \(Fmt.dayTime.string(from: s))") }
                            if let c = p.categoryHint { Label(c.displayName, systemImage: c.icon) }
                            if !p.isFlexible { Label("Fixed", systemImage: "lock") }
                            Text(p.status.rawValue.replacingOccurrences(of: "_", with: " "))
                            if p.source == .agent { Label("Suggested by agent", systemImage: "sparkles") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = p }.buttonStyle(.borderless)
                }
                .contextMenu {
                    Button("Edit…") { editing = p }
                    Button("Delete", role: .destructive) { model.deletePlan(p) }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No planned tasks", systemImage: "checklist",
                                       description: Text("Add what you intend to work on. The agent compares it with what actually happened."))
            }
        }
        .toolbar {
            Toggle("Show closed", isOn: $showClosed)
            Button { editing = PlanItem(title: "", expectedMinutes: 30) } label: { Label("Add Task", systemImage: "plus") }
        }
        .navigationTitle("Plan")
        .sheet(item: $editing) { p in PlanEditor(item: p) { model.savePlan($0) } }
    }
}

struct PlanEditor: View {
    @State var item: PlanItem
    var onSave: (PlanItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasDeadline = false
    @State private var hasPlanned = false

    var body: some View {
        Form {
            TextField("Task", text: $item.title)
            TextField("Notes", text: Binding(get: { item.notes ?? "" }, set: { item.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
            Stepper("Expected: \(item.expectedMinutes) min", value: $item.expectedMinutes, in: 5...600, step: 5)
            Picker("Priority", selection: $item.priority) { ForEach(1...4, id: \.self) { Text("P\($0)").tag($0) } }
            Picker("Kind of work", selection: $item.categoryHint) {
                Text("Unspecified").tag(ActivityCategory?.none)
                ForEach(ActivityCategory.allCases.filter { $0 != .idle && $0 != .unknown }) { Text($0.displayName).tag(ActivityCategory?.some($0)) }
            }
            Picker("Status", selection: $item.status) {
                ForEach(PlanStatus.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ")).tag($0) }
            }
            Toggle("Agent may reschedule", isOn: $item.isFlexible)
            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Due", selection: Binding(get: { item.deadline ?? Date().addingTimeInterval(86400) }, set: { item.deadline = $0 }))
            }
            Toggle("Planned time", isOn: $hasPlanned)
            if hasPlanned {
                DatePicker("Starts", selection: Binding(get: { item.plannedStart ?? Date() }, set: { item.plannedStart = $0 }))
            }
        }
        .formStyle(.grouped)
        .onAppear { hasDeadline = item.deadline != nil; hasPlanned = item.plannedStart != nil }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if !hasDeadline { item.deadline = nil }
                    if !hasPlanned { item.plannedStart = nil }
                    if item.status == .completed { item.userConfirmed = true }
                    onSave(item)
                    dismiss()
                }
                .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 460, height: 520)
    }
}
