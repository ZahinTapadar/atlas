import Foundation

/// The numbers behind the Reports screen and the check-in email: buckets, figures with the previous
/// period for comparison, a weekday × hour map, and apps and sites ranked by time.

public enum ReportPeriod: String, CaseIterable, Sendable {
    case today, week, month
    public var title: String { switch self { case .today: "Today"; case .week: "7 days"; case .month: "30 days" } }
    public var days: Int { switch self { case .today: 1; case .week: 7; case .month: 30 } }
    public var previousName: String { switch self { case .today: "yesterday"; case .week: "the week before"; case .month: "the 30 days before" } }
}

extension AllocationGroup {
    public static let charted: [AllocationGroup] = allCases.filter { $0 != .idleOrUncertain }
    public static let productive: Set<AllocationGroup> = [.activeWork, .learning, .reading]
    public static let distractions: Set<AllocationGroup> = [.entertainment, .gaming, .socialMedia]

    /// Short label for filter chips.
    public var shortName: String {
        switch self {
        case .activeWork: "Work"
        case .learning: "Learning"
        case .reading: "Reading"
        case .entertainment: "Video"
        case .gaming: "Games"
        case .socialMedia: "Social"
        case .communication: "Messages"
        case .breaks: "Breaks"
        case .idleOrUncertain: "Uncertain"
        }
    }

    public var icon: String {
        switch self {
        case .activeWork: "hammer"
        case .learning: "graduationcap"
        case .reading: "book"
        case .entertainment: "play.rectangle"
        case .gaming: "gamecontroller"
        case .socialMedia: "bubble.left.and.bubble.right"
        case .communication: "envelope"
        case .breaks: "cup.and.saucer"
        case .idleOrUncertain: "questionmark.circle"
        }
    }
}

public struct Report: Sendable {
    public init() {}
    public struct Bucket: Identifiable, Sendable { public var id: Date { start }; public var start: Date; public var byGroup: [AllocationGroup: TimeInterval] }
    public struct Source: Identifiable, Sendable { public var id: String; public var label: String; public var category: ActivityCategory; public var time: TimeInterval }
    public struct Figures: Sendable { public var engaged: TimeInterval = 0; public var longestFocus: TimeInterval = 0; public var sessions = 0; public var switches = 0 }

    public var start = Date(), end = Date()
    public var hourly = false
    public var buckets: [Bucket] = []
    public var days: [Date] = []
    public var groupTotals: [AllocationGroup: TimeInterval] = [:]
    public var previousTotals: [AllocationGroup: TimeInterval] = [:]
    public var figures = Figures()
    public var previous = Figures()
    public var uncertain: TimeInterval = 0
    /// Engaged seconds per [weekday (Mon = 0)][hour], per group.
    public var heat: [AllocationGroup: [[TimeInterval]]] = [:]
    public var sources: [Source] = []
    public var loaded = false

    public static let empty = Report()

    public var rangeLabel: String {
        guard loaded else { return " " }
        if hourly { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEdMMMM"); return f.string(from: start) }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }

    public func total(_ groups: Set<AllocationGroup>, previous prev: Bool = false) -> TimeInterval {
        (prev ? previousTotals : groupTotals).filter { groups.contains($0.key) }.reduce(0) { $0 + $1.value }
    }

    public static func build(period: ReportPeriod, store: AtlasStore, now: Date = Date()) async -> Report {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(period.days - 1), to: todayStart)!
        let prevStart = cal.date(byAdding: .day, value: -period.days, to: start)!
        let raw = (try? await store.events(from: prevStart, to: now)) ?? []

        var r = Report()
        r.start = start
        r.end = cal.date(byAdding: .day, value: 1, to: todayStart)!
        r.hourly = period == .today
        r.days = (0..<period.days).compactMap { cal.date(byAdding: .day, value: $0, to: start) }

        let current = TimeAccounting.normalized(raw.filter { $0.end > start }, from: start, to: now)
        let before = TimeAccounting.normalized(raw.filter { $0.start < start }, from: prevStart, to: start)
        r.figures = figures(current)
        r.previous = figures(before)
        r.groupTotals = groupTotals(current)
        r.previousTotals = groupTotals(before)
        r.uncertain = current.filter { $0.state == .uncertain || ($0.state.isEngaged && $0.classification.isUncertain) }.reduce(0) { $0 + $1.duration }

        // Buckets: hours for today (from the first engaged hour), days otherwise.
        var edges: [Date] = []
        if r.hourly {
            let first = current.filter { $0.state.isEngaged }.map(\.start).min() ?? now.addingTimeInterval(-4 * 3600)
            var t = cal.dateInterval(of: .hour, for: min(first, now.addingTimeInterval(-4 * 3600)))?.start ?? first
            while t <= now { edges.append(t); t = t.addingTimeInterval(3600) }
        } else {
            edges = r.days
        }
        r.buckets = edges.map { b in
            let e = r.hourly ? b.addingTimeInterval(3600) : cal.date(byAdding: .day, value: 1, to: b)!
            return Bucket(start: b, byGroup: groupTotals(clip(current, b, e)))
        }

        // Rhythm: split engaged time across hour boundaries.
        var heat: [AllocationGroup: [[TimeInterval]]] = [:]
        for ev in current where ev.state.isEngaged {
            let g = ev.classification.category.allocationGroup
            guard g != .idleOrUncertain else { continue }
            var t = ev.start
            while t < ev.end {
                let hourEnd = cal.dateInterval(of: .hour, for: t)?.end ?? ev.end
                let slice = min(hourEnd, ev.end).timeIntervalSince(t)
                let wd = (cal.component(.weekday, from: t) + 5) % 7
                if heat[g] == nil { heat[g] = Array(repeating: Array(repeating: 0, count: 24), count: 7) }
                heat[g]![wd][cal.component(.hour, from: t)] += slice
                t = min(hourEnd, ev.end)
            }
        }
        r.heat = heat

        // Top apps and sites.
        var src: [String: Source] = [:]
        for ev in current where ev.state.isEngaged && ev.classification.category.allocationGroup != .idleOrUncertain {
            let label = ev.privacy == .excluded ? "Private" : (ev.browser?.domain ?? ev.appName ?? "Unknown")
            let key = "\(label)|\(ev.classification.category.rawValue)"
            src[key, default: Source(id: key, label: label, category: ev.classification.category, time: 0)].time += ev.duration
        }
        r.sources = src.values.sorted { $0.time > $1.time }
        r.loaded = true
        return r
    }

    private static func clip(_ events: [ActivityEvent], _ a: Date, _ b: Date) -> [ActivityEvent] {
        events.compactMap { e in
            guard e.end > a, e.start < b else { return nil }
            var c = e; c.start = max(e.start, a); c.end = min(e.end, b); return c
        }
    }

    private static func groupTotals(_ events: [ActivityEvent]) -> [AllocationGroup: TimeInterval] {
        var out: [AllocationGroup: TimeInterval] = [:]
        for (cat, v) in TimeAccounting.totals(events) where cat.allocationGroup != .idleOrUncertain {
            out[cat.allocationGroup, default: 0] += v.observed
        }
        return out
    }

    private static func figures(_ events: [ActivityEvent]) -> Figures {
        let m = FocusMetrics.compute(events)
        let sessions = SessionBuilder.build(events).sessions.filter {
            AllocationGroup.productive.contains($0.primaryCategory.allocationGroup) && $0.activeSeconds >= 25 * 60
        }
        return Figures(engaged: events.filter { $0.state.isEngaged }.reduce(0) { $0 + $1.duration },
                       longestFocus: m.longestFocus, sessions: sessions.count, switches: m.switches)
    }
}
