import Foundation

public struct RubricComponent: Codable, Hashable, Sendable {
    public var name: String
    /// Weight after redistributing weights of non-applicable components.
    public var effectiveWeight: Double
    /// 0...1, nil when not applicable (e.g. no planned tasks in the window).
    public var value: Double?
    public var explanation: String
}

public struct RubricResult: Codable, Hashable, Sendable {
    /// 0...100, nil when there is insufficient evidence. Never fabricated.
    public var score: Double?
    public var insufficientData: Bool
    public var components: [RubricComponent]
    public var notes: [String]
    public var consideredMinutes: Double
}

/// Transparent, deterministic, user-weighted rubric (spec §9E). Same input → same output.
public enum Rubric {
    public static let minimumEngagedMinutes = 30.0
    public static let minimumCoverage = 0.4

    public static func evaluate(events rawEvents: [ActivityEvent], window: DateInterval, plan: [PlanItem],
                                calendar: [CalendarEvent], weights: RubricWeights) -> RubricResult {
        let events = TimeAccounting.normalized(rawEvents, from: window.start, to: window.end)
        var notes: [String] = []

        // Time inside fixed calendar commitments is outside the user's control: exclude it.
        let fixed = calendar.filter { $0.isFixed && !$0.isAllDay }
            .compactMap { DateInterval(start: $0.start, end: max($0.start, $0.end)).intersection(with: window) }
        func outsideFixed(_ e: ActivityEvent) -> TimeInterval {
            let iv = DateInterval(start: e.start, end: e.end)
            let blocked = fixed.reduce(0.0) { $0 + (iv.intersection(with: $1)?.duration ?? 0) }
            return max(0, e.duration - blocked)
        }
        if !fixed.isEmpty { notes.append("Time in fixed calendar commitments is excluded from scoring.") }

        // Breaks and idle are excluded, not penalized. Excluded/private activity is not judged.
        let judged = events.filter { $0.state.isEngaged && $0.privacy != .excluded && $0.classification.category != .breakTime }
        let engagedMinutes = judged.reduce(0) { $0 + outsideFixed($1) } / 60
        let covered = events.filter { $0.state != .uncertain }.reduce(0) { $0 + $1.duration }
        let coverage = window.duration > 0 ? covered / window.duration : 0
        let uncertainShare = judged.isEmpty ? 1 : judged.filter { $0.classification.isUncertain }
            .reduce(0) { $0 + $1.duration } / max(1, judged.reduce(0) { $0 + $1.duration })

        // --- Priority alignment
        let hints = Set(plan.filter { $0.priority <= 2 && $0.status != .completed && $0.status != .dropped }
            .compactMap(\.categoryHint))
        let alignment: (Double?, String)
        let productive: Set<AllocationGroup> = [.activeWork, .learning, .reading]
        if engagedMinutes > 0 {
            let aligned = judged.filter { e in
                !e.classification.isUncertain &&
                    (hints.isEmpty ? productive.contains(e.classification.category.allocationGroup)
                                   : hints.contains(e.classification.category))
            }.reduce(0) { $0 + outsideFixed($1) } / 60
            let v = aligned / engagedMinutes
            alignment = (v, hints.isEmpty
                ? "No high-priority tasks carry a category, so productive categories were used as a proxy: \(fmt(aligned)) of \(fmt(engagedMinutes)) min."
                : "\(fmt(aligned)) of \(fmt(engagedMinutes)) engaged min matched high-priority task categories.")
        } else {
            alignment = (nil, "No engaged time to evaluate.")
        }

        // --- Planned task completion (tasks planned to start inside this window)
        let planned = plan.filter { p in p.plannedStart.map { window.contains($0) } ?? false }
        let completion: (Double?, String)
        if planned.isEmpty {
            completion = (nil, "No tasks were planned for this window.")
        } else {
            let credit = planned.reduce(0.0) { acc, p in
                acc + (p.status == .completed ? 1 : p.status == .partial ? 0.5 : p.status == .inProgress ? 0.25 : 0)
            }
            let done = planned.filter { $0.status == .completed }.count
            completion = (credit / Double(planned.count), "\(done) of \(planned.count) planned tasks completed (partial credit for partial/in-progress; only confirmed statuses count).")
        }

        // --- Focus & continuity
        let focus = FocusMetrics.compute(events)
        let focus_: (Double?, String)
        if engagedMinutes > 0 {
            let perHour = Double(focus.switches) / max(engagedMinutes / 60, 0.25)
            let longestScore = min(1, focus.longestFocus / (45 * 60))
            let switchScore = max(0, 1 - perHour / 30)
            focus_ = (0.5 * longestScore + 0.5 * switchScore,
                      "Longest focus block \(fmt(focus.longestFocus / 60)) min; \(String(format: "%.1f", perHour)) app/site switches per engaged hour.")
        } else {
            focus_ = (nil, "No engaged time to evaluate.")
        }

        // --- Schedule adherence: during planned slots, was the user doing the planned kind of thing?
        let slotted = planned.filter { $0.categoryHint != nil }
        let adherence: (Double?, String)
        if slotted.isEmpty {
            adherence = (nil, "No planned time slots with a category to compare against.")
        } else {
            var plannedSecs = 0.0, matched = 0.0
            for p in slotted {
                let slot = DateInterval(start: p.plannedStart!, duration: Double(p.expectedMinutes) * 60)
                guard let inWindow = slot.intersection(with: window) else { continue }
                plannedSecs += inWindow.duration
                matched += events.filter { $0.state.isEngaged && $0.classification.category == p.categoryHint }
                    .reduce(0) { $0 + (DateInterval(start: $1.start, end: $1.end).intersection(with: inWindow)?.duration ?? 0) }
            }
            adherence = plannedSecs > 0 ? (matched / plannedSecs, "\(fmt(matched / 60)) of \(fmt(plannedSecs / 60)) planned min were spent on the planned kind of activity.")
                                        : (nil, "Planned slots fall outside this window.")
        }

        let raw: [(String, Double, (Double?, String))] = [
            ("Priority alignment", weights.priorityAlignment, alignment),
            ("Planned task completion", weights.taskCompletion, completion),
            ("Focus & continuity", weights.focusContinuity, focus_),
            ("Schedule adherence", weights.scheduleAdherence, adherence),
        ]
        let applicableWeight = raw.filter { $0.2.0 != nil }.reduce(0) { $0 + $1.1 }
        let components = raw.map { name, w, r in
            RubricComponent(name: name, effectiveWeight: r.0 == nil || applicableWeight == 0 ? 0 : w / applicableWeight,
                            value: r.0.map { (min(max($0, 0), 1) * 1000).rounded() / 1000 }, explanation: r.1)
        }

        var insufficient = false
        if engagedMinutes < minimumEngagedMinutes {
            insufficient = true
            notes.append("Only \(fmt(engagedMinutes)) engaged minutes observed (minimum \(Int(minimumEngagedMinutes))).")
        }
        if coverage < minimumCoverage {
            insufficient = true
            notes.append("Tracking covered \(Int(coverage * 100))% of the window (minimum \(Int(minimumCoverage * 100))%).")
        }
        if uncertainShare > 0.5 {
            insufficient = true
            notes.append("More than half of engaged time has uncertain classification.")
        }
        if applicableWeight == 0 { insufficient = true }

        let score: Double? = insufficient ? nil :
            (components.reduce(0) { $0 + ($1.value ?? 0) * $1.effectiveWeight } * 1000).rounded() / 10
        return RubricResult(score: score, insufficientData: insufficient, components: components, notes: notes,
                            consideredMinutes: (engagedMinutes * 10).rounded() / 10)
    }

    private static func fmt(_ m: Double) -> String { String(Int(m.rounded())) }
}
