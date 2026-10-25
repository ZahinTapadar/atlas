import Foundation

/// A read-only summary of tracked activity over any time range, for external consumers
/// (the `atlas` CLI and MCP server used by scheduled Claude check-ins). Same privacy rules as the
/// agent package: excluded activity appears only as "excluded", sensitive titles are dropped,
/// and full URLs are never included.
public struct ActivityDigest: Codable, Sendable {
    public struct Current: Codable, Sendable {
        public var since: String
        public var minutes: Double
        public var source: String
        public var title: String?
        public var category: String
        public var state: String
        public var confidence: Double
    }

    public struct SourceTotal: Codable, Sendable {
        public var source: String
        public var category: String
        public var minutes: Double
    }

    public struct GroupTotal: Codable, Sendable {
        public var group: String
        public var minutes: Double
    }

    public var from: String
    public var to: String
    public var timeZone: String
    public var generatedAt: String
    public var trackerRunning: Bool
    public var lastRecordedAt: String?
    public var current: Current?
    public var engagedMinutes: Double
    public var idleMinutes: Double
    public var uncertainMinutes: Double
    public var excludedMinutes: Double
    public var notTrackedMinutes: Double
    public var contextSwitches: Int
    public var switchesPerEngagedHour: Double
    public var longestFocusMinutes: Double
    public var byGroup: [GroupTotal]
    public var byCategory: [ActivityPackage.CategoryTotal]
    public var topSources: [SourceTotal]
    public var timeline: [ActivityPackage.TimelineEntry]?
    public var timelineTruncated: Bool
    public var rubric: RubricResult
    public var trackingHealth: [String]
    public var notes: [String]

    public static func build(events raw: [ActivityEvent], from: Date, to: Date, now: Date, includeTimeline: Bool,
                             sendTitles: Bool, maxTimeline: Int = 150, trackingHealth: [String] = [],
                             timeZone: TimeZone = .current) -> ActivityDigest {
        let events = TimeAccounting.normalized(raw, from: from, to: to)
        var window = AnalysisWindow(kind: .manual, start: from, end: to, status: .ready)
        window.id = "digest"
        window.awakeSeconds = events.filter { $0.state.countsAsAwake }.reduce(0) { $0 + $1.duration }
        let rubric = Rubric.evaluate(events: events, window: DateInterval(start: from, end: max(from, to)), plan: [],
                                     calendar: [], weights: RubricWeights())
        let pkg = PackageBuilder.build(window: window, events: events, plan: [], calendar: [], freeSlots: [],
                                       nextPeriod: DateInterval(start: to, duration: 1), rubric: rubric,
                                       options: PackageOptions(maxTimelineEntries: maxTimeline, sendTitles: sendTitles,
                                                               timeZone: timeZone, trackingHealth: trackingHealth),
                                       now: now)

        var groups: [AllocationGroup: TimeInterval] = [:]
        for (cat, v) in TimeAccounting.totals(events) { groups[cat.allocationGroup, default: 0] += v.observed }
        var sources: [String: (ActivityCategory, TimeInterval)] = [:]
        for e in events where e.state.isEngaged {
            let key = PackageBuilder.source(e)
            let cat = e.privacy == .excluded ? ActivityCategory.unknown : e.classification.category
            let prev = sources[key]?.1 ?? 0
            sources[key] = (prev >= e.duration ? sources[key]?.0 ?? cat : cat, prev + e.duration)
        }

        let last = raw.max { $0.end < $1.end }
        var current: Current?
        if let last, now.timeIntervalSince(last.end) < 120, to >= now.addingTimeInterval(-120) {
            current = Current(since: PackageBuilder.iso(last.start, timeZone), minutes: PackageBuilder.round1(last.duration / 60),
                              source: PackageBuilder.source(last),
                              title: sendTitles && last.privacy == .normal ? (last.browser?.title ?? last.windowTitle).map { String($0.prefix(120)) } : nil,
                              category: last.privacy == .excluded ? "excluded" : last.classification.category.rawValue,
                              state: last.state.rawValue, confidence: PackageBuilder.round2(last.classification.confidence))
        }

        var notes: [String] = []
        if pkg.uncertainMinutes + pkg.notObservedMinutes > pkg.wallMinutes * 0.3 {
            notes.append("Over 30% of this range is uncertain or untracked; treat conclusions cautiously.")
        }
        let unclassified = pkg.totals.first { $0.category == ActivityCategory.unknown.rawValue }?.observedMinutes ?? 0
        if unclassified > 0 { notes.append("\(Int(unclassified)) engaged minutes are unclassified (app/site not recognized).") }

        return ActivityDigest(
            from: pkg.windowStart, to: pkg.windowEnd, timeZone: timeZone.identifier, generatedAt: PackageBuilder.iso(now, timeZone),
            trackerRunning: last.map { now.timeIntervalSince($0.end) < 120 } ?? false,
            lastRecordedAt: last.map { PackageBuilder.iso($0.end, timeZone) }, current: current,
            engagedMinutes: pkg.engagedMinutes, idleMinutes: pkg.idleMinutes, uncertainMinutes: pkg.uncertainMinutes,
            excludedMinutes: pkg.excludedMinutes, notTrackedMinutes: pkg.notObservedMinutes,
            contextSwitches: pkg.contextSwitches,
            switchesPerEngagedHour: pkg.engagedMinutes > 0 ? PackageBuilder.round1(Double(pkg.contextSwitches) / (pkg.engagedMinutes / 60)) : 0,
            longestFocusMinutes: pkg.longestFocusMinutes,
            byGroup: groups.sorted { $0.value > $1.value }.map { GroupTotal(group: $0.key.rawValue, minutes: PackageBuilder.round1($0.value / 60)) },
            byCategory: pkg.totals,
            topSources: sources.sorted { $0.value.1 > $1.value.1 }.prefix(15)
                .map { SourceTotal(source: $0.key, category: $0.value.0.rawValue, minutes: PackageBuilder.round1($0.value.1 / 60)) },
            timeline: includeTimeline ? pkg.timeline : nil, timelineTruncated: pkg.timelineTruncated, rubric: rubric,
            trackingHealth: trackingHealth, notes: notes)
    }

    /// Compact human-readable rendering.
    public var markdown: String {
        var out = ["# ATLAS activity \(from) → \(to)", ""]
        out.append(trackerRunning ? "Tracker: running" : "Tracker: NOT running (last record \(lastRecordedAt ?? "never"))")
        if let c = current { out.append("Now: \(c.source) — \(c.category) (\(c.state)) for \(Int(c.minutes)) min") }
        out.append("")
        out.append("Engaged \(Int(engagedMinutes))m · idle/away \(Int(idleMinutes))m · uncertain \(Int(uncertainMinutes))m · not tracked \(Int(notTrackedMinutes))m")
        out.append("Longest focus \(Int(longestFocusMinutes))m · \(contextSwitches) switches (\(switchesPerEngagedHour)/h)")
        out.append("")
        out.append("## By category")
        for t in byCategory { out.append("- \(t.category): \(Int(t.observedMinutes))m" + (t.inferredMinutes > 1 ? " (\(Int(t.inferredMinutes))m inferred)" : "")) }
        out.append("")
        out.append("## Top apps & sites")
        for s in topSources { out.append("- \(s.source) [\(s.category)]: \(Int(s.minutes))m") }
        if let tl = timeline, !tl.isEmpty {
            out.append("")
            out.append("## Timeline")
            for e in tl where e.minutes >= 1 {
                out.append("- \(e.start.suffix(14).prefix(5))–\(e.end.suffix(14).prefix(5)) \(e.source) [\(e.category), \(e.state)\(e.uncertain ? ", uncertain" : "")]\(e.title.map { " — \($0)" } ?? "")")
            }
        }
        if !notes.isEmpty { out.append(""); out += notes.map { "Note: \($0)" } }
        return out.joined(separator: "\n")
    }
}

/// Parses ranges like "today", "yesterday", "last_3h", "-90m", or ISO-8601 timestamps.
public enum DigestRange {
    public static func parse(from: String?, to: String?, now: Date = Date(), calendar: Calendar = .current) -> (Date, Date)? {
        let start = calendar.startOfDay(for: now)
        func point(_ s: String) -> Date? {
            let v = s.trimmingCharacters(in: .whitespaces).lowercased()
            switch v {
            case "now": return now
            case "today", "start_of_day": return start
            case "yesterday": return calendar.date(byAdding: .day, value: -1, to: start)
            default: break
            }
            var rel = v
            if rel.hasPrefix("last_") { rel = "-" + rel.dropFirst(5) }
            if rel.hasPrefix("-"), let unit = rel.last, let n = Double(rel.dropFirst().dropLast()) {
                let secs: Double? = unit == "m" ? n * 60 : unit == "h" ? n * 3600 : unit == "d" ? n * 86400 : nil
                if let secs { return now.addingTimeInterval(-secs) }
            }
            return AgentResultValidator.parseDate(s)
        }
        let f = from.flatMap(point) ?? start
        var t = to.flatMap(point) ?? now
        if from?.lowercased() == "yesterday" && to == nil { t = start }
        guard t > f else { return nil }
        return (f, min(t, now))
    }
}
