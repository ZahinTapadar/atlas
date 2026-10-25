import AtlasCore
import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var categoryFilter: ActivityCategory?
    @State private var uncertainOnly = false
    @State private var selection = Set<String>()
    @State private var day = Date()
    @State private var events: [ActivityEvent] = []
    @State private var splitting: ActivityEvent?

    var filtered: [ActivityEvent] {
        events.filter { e in
            (categoryFilter == nil || e.classification.category == categoryFilter) &&
            (!uncertainOnly || e.classification.isUncertain || e.state == .uncertain) &&
            (search.isEmpty || [e.displayLabel, e.windowTitle ?? "", e.browser?.title ?? "", e.classification.category.displayName]
                .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.start > $1.start }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Timeline", subtitle: "\(filtered.count) segments · right-click to recategorize, split or merge") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary)
                    TextField("Search apps, sites, titles", text: $search).textFieldStyle(.plain).frame(width: 200)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 38).padding(.bottom, 16)
            HStack(spacing: 12) {
                DatePicker("Day", selection: $day, displayedComponents: .date).labelsHidden().frame(width: 120)
                Picker("Category", selection: $categoryFilter) {
                    Text("All categories").tag(ActivityCategory?.none)
                    ForEach(ActivityCategory.allCases) { Text($0.displayName).tag(ActivityCategory?.some($0)) }
                }
                .labelsHidden().frame(width: 190)
                Toggle("Uncertain only", isOn: $uncertainOnly).toggleStyle(.checkbox)
                Spacer()
                if selection.count >= 2 {
                    Menu("Merge \(selection.count) as…") {
                        ForEach(ActivityCategory.allCases) { c in
                            Button(c.displayName) { model.merge(events.filter { selection.contains($0.id) }, as: c); selection.removeAll() }
                        }
                    }
                    .help("Merge adjacent segments into one")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, Theme.gutter).padding(.bottom, 14)
            Table(filtered, selection: $selection) {
                TableColumn("Time") { e in Text(Fmt.range(e.start, e.end)).monospacedDigit() }.width(min: 110, ideal: 120)
                TableColumn("Duration") { e in Text(Fmt.duration(e.duration)).monospacedDigit() }.width(60)
                TableColumn("Activity") { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.displayLabel)
                        if let t = e.browser?.title ?? e.windowTitle, e.privacy == .normal {
                            Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let note = e.stateNote { Text(note).font(.caption2).foregroundStyle(Theme.mixed) }
                    }
                }
                TableColumn("Category") { e in CategoryChip(category: e.classification.category) }.width(min: 150, ideal: 170)
                TableColumn("State") { e in Text(e.state.rawValue.replacingOccurrences(of: "_", with: " ")) }.width(70)
                TableColumn("Confidence") { e in ConfidenceBadge(classification: e.classification) }.width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let e = events.first(where: { $0.id == id }), ids.count == 1 {
                    Menu("Recategorize") {
                        ForEach(ActivityCategory.allCases) { c in Button(c.displayName) { model.recategorize(e, to: c, learn: nil) } }
                    }
                    Menu("Recategorize and remember for this \(e.browser?.domain != nil ? "site" : "app")") {
                        ForEach(ActivityCategory.allCases) { c in Button(c.displayName) { model.recategorize(e, to: c, learn: .appOrSite) } }
                    }
                    if (e.browser?.title ?? e.windowTitle) != nil {
                        Menu("Recategorize and remember for this title") {
                            ForEach(ActivityCategory.allCases) { c in Button(c.displayName) { model.recategorize(e, to: c, learn: .exactTitle) } }
                        }
                    }
                    Button("Split…") { splitting = e }.disabled(e.duration < 120)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous).strokeBorder(Theme.hairline))
            .padding(.horizontal, Theme.gutter).padding(.bottom, 24)
        }
        .task(id: day) { await load() }
        .onChange(of: model.todayEvents) { Task { await load() } }
        .sheet(item: $splitting) { e in SplitSheet(event: e) { d in model.split(e, at: d) } }
    }

    private func load() async {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        events = (try? await model.store.events(from: start, to: end)) ?? []
    }
}

struct SplitSheet: View {
    var event: ActivityEvent
    var onSplit: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fraction = 0.5

    var body: some View {
        let at = event.start.addingTimeInterval(event.duration * fraction)
        VStack(alignment: .leading, spacing: 14) {
            Text("Split “\(event.displayLabel)”").font(.headline)
            Text(Fmt.range(event.start, event.end)).foregroundStyle(.secondary)
            Slider(value: $fraction, in: 0.02...0.98)
            Text("Split at \(Fmt.time.string(from: at))").monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Split") { onSplit(at); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 380)
    }
}
