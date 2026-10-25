import Foundation

/// The minimized, privacy-filtered package sent to the model for one window.
/// This is the *only* activity data that ever leaves the machine.
public struct ActivityPackage: Codable, Sendable, Hashable {
    public struct TimelineEntry: Codable, Sendable, Hashable {
        public var start: String
        public var end: String
        public var minutes: Double
        public var category: String
        public var state: String
        public var confidence: Double
        public var uncertain: Bool
        public var userConfirmed: Bool
        /// App name, or browser + domain. Never a full URL unless the user enabled it.
        public var source: String
        public var title: String?
        public var contextSwitches: Int
    }

    public struct CategoryTotal: Codable, Sendable, Hashable {
        public var category: String
        public var observedMinutes: Double
        /// Minutes credited from passive (no-input) inference rather than direct interaction.
        public var inferredMinutes: Double
    }

    public struct PlanEntry: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var expectedMinutes: Int
        public var priority: Int
        public var deadline: String?
        public var plannedStart: String?
        public var status: String
        public var flexible: Bool
        public var categoryHint: String?
    }

    public struct CalendarEntry: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var start: String
        public var end: String
        public var fixed: Bool
        public var createdByAtlas: Bool
    }

    public struct FreeSlot: Codable, Sendable, Hashable {
        public var start: String
        public var end: String
        public var minutes: Double
    }

    public var windowID: String
    public var windowKind: String
    public var windowStart: String
    public var windowEnd: String
    public var timeZone: String
    public var now: String
    public var wallMinutes: Double
    public var awakeMinutes: Double
    public var engagedMinutes: Double
    public var idleMinutes: Double
    public var uncertainMinutes: Double
    public var excludedMinutes: Double
    public var notObservedMinutes: Double
    public var contextSwitches: Int
    public var longestFocusMinutes: Double
    public var trackingHealth: [String]
    public var timeline: [TimelineEntry]
    public var timelineTruncated: Bool
    public var totals: [CategoryTotal]
    public var plan: [PlanEntry]
    public var calendar: [CalendarEntry]
    public var freeSlotsNextPeriod: [FreeSlot]
    public var nextPeriodStart: String
    public var nextPeriodEnd: String
    public var rubric: RubricResult
}

public struct PackageOptions: Sendable {
    public var maxTimelineEntries: Int
    public var sendTitles: Bool
    public var timeZone: TimeZone
    public var trackingHealth: [String]

    public init(maxTimelineEntries: Int = 120, sendTitles: Bool = true, timeZone: TimeZone = .current,
                trackingHealth: [String] = []) {
        self.maxTimelineEntries = maxTimelineEntries
        self.sendTitles = sendTitles
        self.timeZone = timeZone
        self.trackingHealth = trackingHealth
    }
}

/// Non-overlapping time accounting. Events are clipped to the window and, should any overlap
/// exist (e.g. after manual edits), later-starting events win the contested time.
public enum TimeAccounting {
    public static func normalized(_ events: [ActivityEvent], from: Date, to: Date) -> [ActivityEvent] {
        var out: [ActivityEvent] = []
        for e in events.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            guard let c = e.clipped(from: from, to: to) else { continue }
            if let last = out.last, last.end > c.start {
                // Overlap: trim the earlier event; drop it if nothing remains.
                if c.start <= last.start { out.removeLast() } else { out[out.count - 1].end = c.start }
            }
            out.append(c)
        }
        return out
    }

    public static func totals(_ normalized: [ActivityEvent]) -> [ActivityCategory: (observed: TimeInterval, inferred: TimeInterval)] {
        var t: [ActivityCategory: (observed: TimeInterval, inferred: TimeInterval)] = [:]
        for e in normalized where e.state.isEngaged {
            let cat = e.privacy == .excluded ? ActivityCategory.unknown : e.classification.category
            var v = t[cat] ?? (0, 0)
            v.observed += e.duration
            if e.state == .passive { v.inferred += e.duration }
            t[cat] = v
        }
        return t
    }
}

public enum PackageBuilder {
    static func iso(_ d: Date, _ tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public static func build(window: AnalysisWindow, events rawEvents: [ActivityEvent], plan: [PlanItem],
                             calendar: [CalendarEvent], freeSlots: [DateInterval], nextPeriod: DateInterval,
                             rubric: RubricResult, options: PackageOptions, now: Date) -> ActivityPackage {
        let end = window.end ?? now
        let tz = options.timeZone
        let events = TimeAccounting.normalized(rawEvents, from: window.start, to: end)

        var engaged: TimeInterval = 0, idle: TimeInterval = 0, uncertain: TimeInterval = 0, excluded: TimeInterval = 0
        for e in events {
            if e.privacy == .excluded { excluded += e.duration }
            switch e.state {
            case .active, .passive: engaged += e.duration
            case .idle, .away, .locked, .systemSleep: idle += e.duration
            case .uncertain: uncertain += e.duration
            }
        }
        let covered = events.reduce(0) { $0 + $1.duration }
        let wall = end.timeIntervalSince(window.start)

        // Merge consecutive entries with the same source/category/state into readable timeline rows.
        struct Acc { var first: ActivityEvent; var end: Date; var conf: Double; var weight: Double; var switches: Int; var confirmed: Bool }
        var rows: [Acc] = []
        func key(_ e: ActivityEvent) -> String {
            "\(source(e))|\(e.classification.category.rawValue)|\(e.state.rawValue)|\(e.classification.isUncertain)"
        }
        for e in events {
            if var last = rows.last, key(last.first) == key(e), last.end == e.start,
               (last.first.browser?.title ?? last.first.windowTitle) == (e.browser?.title ?? e.windowTitle) || !options.sendTitles {
                last.end = e.end
                last.conf += e.classification.confidence * e.duration
                last.weight += e.duration
                last.confirmed = last.confirmed && e.classification.origin != .inferred
                rows[rows.count - 1] = last
            } else {
                rows.append(Acc(first: e, end: e.end, conf: e.classification.confidence * e.duration, weight: e.duration,
                                switches: 0, confirmed: e.classification.origin != .inferred))
            }
        }

        var timeline = rows.map { r -> ActivityPackage.TimelineEntry in
            let e = r.first
            let conf = r.weight > 0 ? r.conf / r.weight : e.classification.confidence
            let title: String? = {
                guard options.sendTitles, e.privacy == .normal else { return nil }
                return (e.browser?.title ?? e.windowTitle).map { String($0.prefix(120)) }
            }()
            return .init(start: iso(e.start, tz), end: iso(r.end, tz), minutes: round1(r.end.timeIntervalSince(e.start) / 60),
                         category: e.privacy == .excluded ? "excluded" : e.classification.category.rawValue,
                         state: e.state.rawValue, confidence: round2(conf),
                         uncertain: e.privacy != .excluded && r.first.classification.isUncertain,
                         userConfirmed: r.confirmed, source: source(e), title: title, contextSwitches: r.switches)
        }

        // Keep within budget: drop the shortest rows first, preserving chronology, and say so.
        var truncated = false
        if timeline.count > options.maxTimelineEntries {
            truncated = true
            let keep = Set(timeline.enumerated().sorted { $0.element.minutes > $1.element.minutes }
                .prefix(options.maxTimelineEntries).map(\.offset))
            timeline = timeline.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }

        var totals: [ActivityPackage.CategoryTotal] = []
        for (cat, v) in TimeAccounting.totals(events) {
            totals.append(.init(category: cat.rawValue, observedMinutes: round1(v.observed / 60),
                                inferredMinutes: round1(v.inferred / 60)))
        }
        totals.sort { a, b in
            a.observedMinutes != b.observedMinutes ? a.observedMinutes > b.observedMinutes : a.category < b.category
        }

        let focus = FocusMetrics.compute(events)
        let planEntries: [ActivityPackage.PlanEntry] = plan.map { p in
            ActivityPackage.PlanEntry(id: p.id, title: p.title, expectedMinutes: p.expectedMinutes, priority: p.priority,
                                      deadline: p.deadline.map { iso($0, tz) }, plannedStart: p.plannedStart.map { iso($0, tz) },
                                      status: p.status.rawValue, flexible: p.isFlexible, categoryHint: p.categoryHint?.rawValue)
        }
        let calendarEntries: [ActivityPackage.CalendarEntry] = calendar.filter { !$0.isAllDay }.map { c in
            ActivityPackage.CalendarEntry(id: c.id, title: String(c.title.prefix(100)), start: iso(c.start, tz),
                                          end: iso(c.end, tz), fixed: c.isFixed, createdByAtlas: c.createdByAtlas)
        }
        let slots: [ActivityPackage.FreeSlot] = freeSlots.map { f in
            ActivityPackage.FreeSlot(start: iso(f.start, tz), end: iso(f.end, tz), minutes: round1(f.duration / 60))
        }
        let notObserved: Double = round1(max(0, wall - covered) / 60)

        return ActivityPackage(
            windowID: window.id, windowKind: window.kind.rawValue, windowStart: iso(window.start, tz), windowEnd: iso(end, tz),
            timeZone: tz.identifier, now: iso(now, tz), wallMinutes: round1(wall / 60),
            awakeMinutes: round1(window.awakeSeconds / 60), engagedMinutes: round1(engaged / 60), idleMinutes: round1(idle / 60),
            uncertainMinutes: round1(uncertain / 60), excludedMinutes: round1(excluded / 60),
            notObservedMinutes: notObserved, contextSwitches: focus.switches,
            longestFocusMinutes: round1(focus.longestFocus / 60), trackingHealth: options.trackingHealth,
            timeline: timeline, timelineTruncated: truncated, totals: totals,
            plan: planEntries, calendar: calendarEntries, freeSlotsNextPeriod: slots,
            nextPeriodStart: iso(nextPeriod.start, tz), nextPeriodEnd: iso(nextPeriod.end, tz), rubric: rubric)
    }

    static func source(_ e: ActivityEvent) -> String {
        if e.privacy == .excluded { return "excluded" }
        switch e.rawType {
        case .systemSleep: return "system sleep"
        case .locked: return "screen locked"
        case .gap: return "not tracked"
        default: break
        }
        if let b = e.browser, let d = b.domain { return "\(b.browser): \(e.privacy == .sensitive ? "(sensitive site)" : d)" }
        return e.appName ?? e.appBundleID ?? (e.state.isEngaged ? "unknown app" : e.state.rawValue)
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

public enum FocusMetrics {
    /// Context switches between distinct apps/sites while engaged, and the longest stretch of a single
    /// productive category with no non-engaged gap over 2 minutes.
    public static func compute(_ events: [ActivityEvent]) -> (switches: Int, longestFocus: TimeInterval) {
        var switches = 0
        var lastKey: String?
        var longest: TimeInterval = 0
        var runCat: ActivityCategory?
        var runLen: TimeInterval = 0
        var gap: TimeInterval = 0
        let focusGroups: Set<AllocationGroup> = [.activeWork, .learning, .reading]
        for e in events {
            if e.state.isEngaged {
                let key = e.browser?.domain ?? e.appBundleID ?? "?"
                if let lastKey, key != lastKey { switches += 1 }
                lastKey = key
                let cat = e.classification.category
                if focusGroups.contains(cat.allocationGroup), cat == runCat || runCat == nil {
                    runCat = cat
                    runLen += e.duration
                    gap = 0
                } else if focusGroups.contains(cat.allocationGroup) {
                    runCat = cat
                    runLen = e.duration
                    gap = 0
                } else {
                    runCat = nil
                    runLen = 0
                }
            } else {
                gap += e.duration
                if gap > 120 { runCat = nil; runLen = 0 }
            }
            longest = max(longest, runLen)
        }
        return (switches, longest)
    }
}
