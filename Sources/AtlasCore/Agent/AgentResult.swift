import Foundation

/// The structured analysis the model must return (spec §9 A–G). Enforced with a JSON schema
/// via structured outputs, then validated locally before anything is shown or acted on.
public struct AgentResult: Codable, Hashable, Sendable {
    public struct ChronologyItem: Codable, Hashable, Sendable {
        public var start: String
        public var end: String
        public var activity: String
        public var category: String
        /// "observed" | "inferred" | "uncertain"
        public var evidenceLevel: String
        public var note: String
    }

    public struct PlanAssessment: Codable, Hashable, Sendable {
        public var planItemID: String
        public var title: String
        /// "completed" | "partial" | "not_started" | "unknown"
        public var assessedStatus: String
        public var evidence: String
        public var confidence: Double
    }

    public struct Finding: Codable, Hashable, Sendable {
        /// "unfinished_work" | "context_switching" | "unplanned_activity" | "priority_mismatch" | "delay" |
        /// "conflict" | "positive" | "tracking_gap" | "other"
        public var kind: String
        public var description: String
        public var evidence: String
        /// "info" | "low" | "medium" | "high"
        public var severity: String
    }

    public struct Assessment: Codable, Hashable, Sendable {
        public var summary: String
        public var caveats: String
    }

    public struct NextTask: Codable, Hashable, Sendable {
        /// Existing plan item id, or "" for a new suggestion.
        public var planItemID: String
        public var title: String
        public var reason: String
        public var estimatedMinutes: Int
        public var deadline: String
        public var priority: Int
        public var dependencies: [String]
        public var suggestedStart: String
        public var suggestedEnd: String
        public var deferrable: Bool
        public var requiresApproval: Bool
    }

    public struct Correction: Codable, Hashable, Sendable {
        /// One of `AgentActionKind` raw values.
        public var action: String
        public var title: String
        public var reason: String
        public var planItemID: String
        public var targetEventID: String
        public var start: String
        public var end: String
    }

    public var summary: String
    public var chronology: [ChronologyItem]
    public var allocationNotes: String
    public var planAssessment: [PlanAssessment]
    public var findings: [Finding]
    public var assessment: Assessment
    public var nextPlan: [NextTask]
    public var corrections: [Correction]
    public var uncertainties: [String]
    public var mostImportantUnfinishedTask: String
    public var reasoning: String

    /// JSON schema for `output_config.format`. All fields required; absent values are "" or [].
    public static var jsonSchema: [String: Any] {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": Array(props.keys).sorted(), "additionalProperties": false]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let num: [String: Any] = ["type": "number"]
        let bool: [String: Any] = ["type": "boolean"]
        func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
        func en(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }

        return obj([
            "summary": str,
            "chronology": arr(obj(["start": str, "end": str, "activity": str, "category": str,
                                   "evidenceLevel": en(["observed", "inferred", "uncertain"]), "note": str])),
            "allocationNotes": str,
            "planAssessment": arr(obj(["planItemID": str, "title": str,
                                       "assessedStatus": en(["completed", "partial", "not_started", "unknown"]),
                                       "evidence": str, "confidence": num])),
            "findings": arr(obj(["kind": en(["unfinished_work", "context_switching", "unplanned_activity", "priority_mismatch",
                                             "delay", "conflict", "positive", "tracking_gap", "other"]),
                                 "description": str, "evidence": str, "severity": en(["info", "low", "medium", "high"])])),
            "assessment": obj(["summary": str, "caveats": str]),
            "nextPlan": arr(obj(["planItemID": str, "title": str, "reason": str, "estimatedMinutes": int, "deadline": str,
                                 "priority": int, "dependencies": arr(str), "suggestedStart": str, "suggestedEnd": str,
                                 "deferrable": bool, "requiresApproval": bool])),
            "corrections": arr(obj(["action": en(AgentActionKind.allCases.map(\.rawValue)), "title": str, "reason": str,
                                    "planItemID": str, "targetEventID": str, "start": str, "end": str])),
            "uncertainties": arr(str),
            "mostImportantUnfinishedTask": str,
            "reasoning": str,
        ])
    }
}

public struct ValidatedAnalysis: Codable, Hashable, Sendable {
    public var result: AgentResult
    /// Problems found and fixed/dropped during validation; shown to the user.
    public var validationNotes: [String]
}

/// Local checks on model output. The model proposes; this decides what is admissible.
public enum AgentResultValidator {
    public static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func validate(_ raw: AgentResult, package: ActivityPackage, plan: [PlanItem], calendar: [CalendarEvent],
                                planner: SlotPlanner, nextPeriod: DateInterval) -> ValidatedAnalysis {
        var r = raw
        var notes: [String] = []
        let planByID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
        let busy = calendar

        // Completion claims need evidence: a model "completed" is only a suggestion unless the user already confirmed.
        r.planAssessment = r.planAssessment.compactMap { a in
            guard let item = planByID[a.planItemID] else {
                notes.append("Dropped assessment for unknown task “\(a.title)”.")
                return nil
            }
            var a = a
            a.confidence = min(max(a.confidence, 0), 1)
            if a.assessedStatus == "completed" && item.status != .completed && a.confidence < 0.8 {
                a.assessedStatus = "partial"
                notes.append("Downgraded completion claim for “\(item.title)” (confidence \(Int(a.confidence * 100))%); confirm it yourself if done.")
            }
            return a
        }

        // Next plan: must fit in the next period, avoid fixed commitments, and not exceed free time.
        let freeMinutes = package.freeSlotsNextPeriod.reduce(0) { $0 + $1.minutes }
        var scheduled = 0.0
        var occupied: [DateInterval] = []
        r.nextPlan = r.nextPlan.compactMap { t in
            var t = t
            t.estimatedMinutes = max(5, min(t.estimatedMinutes, 8 * 60))
            t.priority = min(max(t.priority, 1), 4)
            if !t.planItemID.isEmpty, planByID[t.planItemID] == nil { t.planItemID = "" }
            guard let s = parseDate(t.suggestedStart), let e = parseDate(t.suggestedEnd) else {
                // Unscheduled suggestion is fine — keep it without a time.
                t.suggestedStart = ""; t.suggestedEnd = ""
                return t
            }
            if e <= s || s < nextPeriod.start.addingTimeInterval(-60) || e > nextPeriod.end.addingTimeInterval(60) {
                notes.append("Removed time for “\(t.title)”: outside the next period.")
                t.suggestedStart = ""; t.suggestedEnd = ""
                return t
            }
            let iv = DateInterval(start: s, end: e)
            if let why = planner.validate(start: s, end: e, against: busy, requireWorkingHours: false) {
                notes.append("Removed time for “\(t.title)”: \(why).")
                t.suggestedStart = ""; t.suggestedEnd = ""
                return t
            }
            if occupied.contains(where: { ($0.intersection(with: iv)?.duration ?? 0) > 0 }) {
                notes.append("Removed time for “\(t.title)”: overlaps another suggested task.")
                t.suggestedStart = ""; t.suggestedEnd = ""
                return t
            }
            if scheduled + iv.duration / 60 > freeMinutes + 1 {
                notes.append("Removed time for “\(t.title)”: would exceed available free time.")
                t.suggestedStart = ""; t.suggestedEnd = ""
                return t
            }
            scheduled += iv.duration / 60
            occupied.append(iv)
            return t
        }

        // Corrections must be well-formed; scheduling ones must respect fixed commitments.
        r.corrections = r.corrections.compactMap { c in
            guard let kind = AgentActionKind(rawValue: c.action) else {
                notes.append("Dropped unknown action “\(c.action)”."); return nil
            }
            switch kind {
            case .createFocusBlock, .createBreak, .rescheduleTask, .moveEvent:
                guard let s = parseDate(c.start), let e = parseDate(c.end), e > s else {
                    notes.append("Dropped “\(c.title)”: missing or invalid time."); return nil
                }
                if let why = planner.validate(start: s, end: e, against: busy.filter { $0.id != c.targetEventID },
                                              requireWorkingHours: false) {
                    notes.append("Dropped “\(c.title)”: \(why)."); return nil
                }
                if kind == .moveEvent {
                    guard let target = calendar.first(where: { $0.id == c.targetEventID }) else {
                        notes.append("Dropped move of unknown event."); return nil
                    }
                    if target.isFixed {
                        notes.append("Dropped move of “\(target.title)”: fixed or shared events are never moved."); return nil
                    }
                }
                if kind == .rescheduleTask, planByID[c.planItemID] == nil {
                    notes.append("Dropped reschedule of unknown task."); return nil
                }
            case .updatePlanItem, .splitTask:
                guard planByID[c.planItemID] != nil else { notes.append("Dropped change to unknown task."); return nil }
            case .createReminder:
                break
            }
            return c
        }

        r.chronology = r.chronology.filter { parseDate($0.start) != nil && parseDate($0.end) != nil }
        return ValidatedAnalysis(result: r, validationNotes: notes)
    }
}
