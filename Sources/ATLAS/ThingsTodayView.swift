import AtlasCore
import SwiftUI

/// Today's to-dos, read live from Things. Open a row to see what's inside it (its checklist, or a project's
/// to-dos), tick things off, and say why something didn't happen. The latest check-in's judgement
/// (in progress, minutes spent) is shown alongside.
struct ThingsToday: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = DemoData.isEnabled ? ["demo-lab4", "demo-revision"] : []

    var body: some View {
        let items = model.thingsItems
        let checkin = model.checkins.first { Calendar.current.isDateInToday($0.ts) && !$0.todos.isEmpty }
        let done = items.filter(\.isDone).count
        let half = (items.count + 1) / 2
        OpenSection {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Today's to-dos", detail: detail(done: done, total: items.count, checkin: checkin))
                if items.isEmpty {
                    Text("Nothing in Things' Today list.").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                } else {
                    HStack(alignment: .top, spacing: 32) {
                        column(Array(items.prefix(half)), checkin: checkin)
                        column(Array(items.dropFirst(half)), checkin: checkin)
                    }
                }
            }
        }
    }

    private func column(_ items: [Things.Item], checkin: AtlasStore.Checkin?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                TodoRow(item: item, judged: checkin?.todos.first { $0.thingsID == item.id || $0.title == item.title },
                        expanded: expanded.contains(item.id)) {
                    withAnimation(.snappy(duration: 0.28)) {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func detail(done: Int, total: Int, checkin: AtlasStore.Checkin?) -> String {
        var s = "\(done) of \(total) done · live from Things"
        if let checkin { s += " · judged at \(Fmt.time.string(from: checkin.ts))" }
        return s
    }
}

private struct TodoRow: View {
    @Environment(AppModel.self) private var model
    var item: Things.Item
    var judged: AtlasStore.CheckinTodo?
    var expanded: Bool
    var toggle: () -> Void
    @State private var hover = false
    @State private var editingReason = false
    @State private var draft = ""

    private var hasInside: Bool { !item.notes.isEmpty || !item.children.isEmpty || !(item.checklist ?? []).isEmpty || item.checklist == nil }
    private var inProgress: Bool { !item.isDone && judged?.status == "in_progress" }
    private var progress: (Int, Int)? {
        let parts = item.isProject ? item.children.map(\.done) : (item.checklist ?? []).map(\.done)
        return parts.isEmpty ? nil : (parts.filter { $0 }.count, parts.count)
    }

    var body: some View {
        let reason = model.reason(for: item)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusButton(done: item.isDone, inProgress: inProgress, project: item.isProject) {
                    Task { await model.setThingsDone(item.id, !item.isDone) }
                }
                .disabled(item.isProject)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(item.isDone ? Theme.inkSecondary : Theme.ink)
                        .strikethrough(item.isDone, color: Theme.inkTertiary)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption = caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let (d, n) = progress {
                    Text("\(d)/\(n)").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(d == n ? Theme.onTrack : Theme.inkSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((d == n ? Theme.onTrack : Theme.inkTertiary).opacity(0.12), in: Capsule())
                }
                if let m = judged?.minutes, m > 0 {
                    Text(Fmt.duration(TimeInterval(m * 60))).font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                }
                if hasInside {
                    Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(hover || expanded ? Theme.ink : Theme.inkTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(hover || expanded ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if hasInside { toggle() } }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }

            if let reason, !editingReason {
                Button { draft = reason; editingReason = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "text.bubble.fill").font(.system(size: 10.5))
                        Text(reason).font(.system(size: 12)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.mixed)
                }
                .buttonStyle(.plain)
                .help("Your reason. The next check-in reads it. Click to edit.")
                .padding(.leading, 34).padding(.trailing, 8).padding(.bottom, 6)
            }

            if editingReason {
                ReasonEditor(draft: $draft) { text in
                    editingReason = false
                    Task { await model.setReason(for: item, text) }
                } cancel: { editingReason = false }
                .padding(.leading, 34).padding(.trailing, 8).padding(.bottom, 8)
            }

            if expanded {
                Inside(item: item, judgedNote: judged?.note, canAddReason: !item.isDone && reason == nil && !editingReason) {
                    draft = ""; editingReason = true
                }
                .padding(.leading, 34).padding(.trailing, 8).padding(.top, 2).padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if hover && !item.isDone && reason == nil && !editingReason {
                Button { draft = ""; editingReason = true } label: {
                    Label("Didn't happen? Add a reason", systemImage: "text.bubble").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkSecondary)
                .padding(.leading, 34).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    private var caption: String? {
        var parts: [String] = []
        if let p = item.project { parts.append(p) }
        if item.isProject { parts.append("Project") }
        if let due = item.due { parts.append("Due \(due)") }
        if let note = judged?.note, !note.isEmpty, !expanded { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct StatusButton: View {
    var done: Bool
    var inProgress: Bool
    var project: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: project ? "list.bullet.circle" : (done ? "checkmark.circle.fill" : (inProgress ? "circle.lefthalf.filled" : "circle")))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(done ? Theme.onTrack : (inProgress ? Theme.mixed : Theme.inkTertiary))
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(project ? "A Things project. Open it to see its to-dos." : (done ? "Mark as not done in Things" : "Mark as done in Things"))
    }
}

/// What a to-do holds: notes, its checklist or a project's to-dos.
private struct Inside: View {
    @Environment(AppModel.self) private var model
    var item: Things.Item
    var judgedNote: String?
    var canAddReason: Bool
    var addReason: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let judgedNote, !judgedNote.isEmpty {
                Label(judgedNote, systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
            }
            if !item.notes.isEmpty {
                Text(item.notes).font(.system(size: 12.5)).foregroundStyle(Theme.inkSecondary).lineSpacing(1.5)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if item.isProject {
                ForEach(Array(item.children.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button { if let id = c.id { Task { await model.setThingsDone(id, !c.done) } } } label: {
                            Image(systemName: c.done ? "checkmark.circle.fill" : "circle").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(c.done ? Theme.onTrack : Theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                        Text(c.title).font(.system(size: 12.5)).foregroundStyle(c.done ? Theme.inkTertiary : Theme.ink)
                            .strikethrough(c.done, color: Theme.inkTertiary)
                    }
                }
                if item.children.isEmpty { Text("No open to-dos in this project.").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary) }
            } else if let list = item.checklist {
                ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: c.done ? "checkmark.square.fill" : "square").font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(c.done ? Theme.onTrack : Theme.inkTertiary)
                        Text(c.title).font(.system(size: 12.5)).foregroundStyle(c.done ? Theme.inkTertiary : Theme.ink)
                            .strikethrough(c.done, color: Theme.inkTertiary)
                    }
                }
            } else {
                Text("Checklists appear here once ATLAS may read Things' data (macOS asks the first time).")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button("Open in Things") { Things.reveal(id: item.id) }
                if canAddReason { Button("Add a reason", action: addReason) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            .padding(.top, 2)
        }
    }
}

private struct ReasonEditor: View {
    @Binding var draft: String
    var save: (String) -> Void
    var cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Why didn't this happen today?", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...4)
                .focused($focused)
                .onSubmit { save(draft) }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.mixed.opacity(0.5)))
            HStack(spacing: 8) {
                Button("Save reason") { save(draft) }.buttonStyle(InkButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel).buttonStyle(InkButtonStyle()).keyboardShortcut(.cancelAction)
                Text("Your next check-in reads this.").font(.system(size: 11.5)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .onAppear { focused = true }
    }
}
