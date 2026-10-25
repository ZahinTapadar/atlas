import Foundation

/// Groups timeline events into sessions: stretches of engagement separated by breaks.
public enum SessionBuilder {
    /// Non-engaged time at least this long ends a session.
    public static let breakThreshold: TimeInterval = 300

    public static func build(_ events: [ActivityEvent]) -> (sessions: [ActivitySession], assignments: [String: String]) {
        let sorted = events.sorted { $0.start < $1.start }
        var sessions: [ActivitySession] = []
        var assignments: [String: String] = [:]
        var bucket: [ActivityEvent] = []
        var pendingBreak: [ActivityEvent] = []

        func flush() {
            guard !bucket.isEmpty else { return }
            let s = summarize(bucket)
            sessions.append(s)
            for e in bucket { assignments[e.id] = s.id }
            bucket.removeAll()
        }

        for e in sorted {
            let hardStop = e.state == .systemSleep || e.state == .locked || e.state == .away
            if e.state.isEngaged {
                let breakLength = pendingBreak.reduce(0) { $0 + $1.duration }
                if breakLength >= breakThreshold { flush() } else { bucket += pendingBreak }
                pendingBreak.removeAll()
                bucket.append(e)
            } else if hardStop {
                // Idle time immediately before sleep/lock belongs to no session.
                pendingBreak.removeAll()
                flush()
            } else {
                pendingBreak.append(e)
            }
        }
        if pendingBreak.reduce(0, { $0 + $1.duration }) < breakThreshold { bucket += pendingBreak }
        flush()
        return (sessions, assignments)
    }

    static func summarize(_ events: [ActivityEvent]) -> ActivitySession {
        var byCategory: [ActivityCategory: TimeInterval] = [:]
        var active: TimeInterval = 0, idle: TimeInterval = 0
        var switches = 0
        var lastKey: String?
        for e in events {
            if e.state.isEngaged {
                active += e.duration
                byCategory[e.classification.category, default: 0] += e.duration
                let key = e.browser?.domain ?? e.appBundleID ?? e.privacy.rawValue
                if let lastKey, lastKey != key { switches += 1 }
                lastKey = key
            } else {
                idle += e.duration
            }
        }
        let primary = byCategory.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .idle
        return ActivitySession(start: events.first!.start, end: events.map(\.end).max()!, primaryCategory: primary,
                               activeSeconds: active, idleSeconds: idle, contextSwitches: switches, eventCount: events.count)
    }
}

/// Turns a user's recategorization into a reusable rule.
public enum CorrectionLearner {
    public enum Scope: String, CaseIterable, Sendable {
        /// Same app/site and the same title (e.g. this specific video or document).
        case exactTitle
        /// Everything from this app or site.
        case appOrSite
    }

    public static func rule(for event: ActivityEvent, category: ActivityCategory, scope: Scope) -> ClassificationRule? {
        guard event.privacy != .excluded else { return nil }
        let title = (event.browser?.title ?? event.windowTitle)?.lowercased()
        let titleCond = scope == .exactTitle ? title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } : nil
        if let domain = event.browser?.domain {
            return ClassificationRule(field: .domain, pattern: domain, titleContains: titleCond, category: category,
                                      confidence: 0.95, source: .correction)
        }
        if let bundle = event.appBundleID {
            return ClassificationRule(field: .bundleID, pattern: bundle, titleContains: titleCond, category: category,
                                      confidence: 0.95, source: .correction)
        }
        return nil
    }
}
