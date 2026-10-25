import Foundation

public struct BrowserContext: Codable, Hashable, Sendable {
    public var browser: String
    public var domain: String?
    public var title: String?
    /// Only populated when the user enabled full-URL capture.
    public var url: String?
    public var isIncognito: Bool
    public var isAudible: Bool

    public init(browser: String, domain: String?, title: String?, url: String? = nil,
                isIncognito: Bool = false, isAudible: Bool = false) {
        self.browser = browser
        self.domain = domain
        self.title = title
        self.url = url
        self.isIncognito = isIncognito
        self.isAudible = isAudible
    }
}

/// One contiguous, non-overlapping slice of the timeline.
public struct ActivityEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var appBundleID: String?
    public var appName: String?
    public var pid: Int32?
    public var windowTitle: String?
    public var browser: BrowserContext?
    public var rawType: RawActivityType
    public var state: ActivityState
    public var classification: Classification
    public var sessionID: String?
    public var privacy: PrivacyClass
    /// TimeZone identifier in effect when recorded, for local-day reporting.
    public var timeZoneID: String
    /// Free-form, non-sensitive notes about why the state is what it is (e.g. "no AX permission").
    public var stateNote: String?

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public init(id: String = UUID().uuidString, start: Date, end: Date, appBundleID: String? = nil,
                appName: String? = nil, pid: Int32? = nil, windowTitle: String? = nil,
                browser: BrowserContext? = nil, rawType: RawActivityType, state: ActivityState,
                classification: Classification = .unknown, sessionID: String? = nil,
                privacy: PrivacyClass = .normal, timeZoneID: String = TimeZone.current.identifier,
                stateNote: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.appBundleID = appBundleID
        self.appName = appName
        self.pid = pid
        self.windowTitle = windowTitle
        self.browser = browser
        self.rawType = rawType
        self.state = state
        self.classification = classification
        self.sessionID = sessionID
        self.privacy = privacy
        self.timeZoneID = timeZoneID
        self.stateNote = stateNote
    }

    /// A human label that never includes excluded metadata.
    public var displayLabel: String {
        if privacy == .excluded { return "Excluded activity" }
        switch rawType {
        case .systemSleep: return "Mac asleep"
        case .locked: return "Screen locked"
        case .gap: return "Not tracked"
        case .idle: return state == .away ? "Away" : "Idle"
        default: break
        }
        if let b = browser, let d = b.domain { return "\(b.browser) — \(d)" }
        return appName ?? appBundleID ?? "Unknown app"
    }

    /// Return a copy clipped to [from, to). Returns nil if no overlap.
    public func clipped(from: Date, to: Date) -> ActivityEvent? {
        let s = max(start, from), e = min(end, to)
        guard e > s else { return nil }
        var copy = self
        copy.start = s
        copy.end = e
        return copy
    }
}

public struct ActivitySession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var primaryCategory: ActivityCategory
    public var activeSeconds: TimeInterval
    public var idleSeconds: TimeInterval
    public var contextSwitches: Int
    public var eventCount: Int
    public var summary: String?

    public init(id: String = UUID().uuidString, start: Date, end: Date, primaryCategory: ActivityCategory,
                activeSeconds: TimeInterval, idleSeconds: TimeInterval, contextSwitches: Int,
                eventCount: Int, summary: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.primaryCategory = primaryCategory
        self.activeSeconds = activeSeconds
        self.idleSeconds = idleSeconds
        self.contextSwitches = contextSwitches
        self.eventCount = eventCount
        self.summary = summary
    }
}

public enum WindowKind: String, Codable, Sendable {
    /// Closed because the awake-time threshold was reached.
    case scheduled
    /// Closed early at the end of a day (long sleep / day boundary).
    case partial
    /// Ad-hoc analysis requested by the user. Does not move scheduled boundaries.
    case manual
}

public enum WindowStatus: String, Codable, Sendable {
    case open           // accumulating
    case ready          // closed, waiting to be analyzed
    case awaitingReview // waiting for the user to approve what will be sent
    case sending
    case analyzed
    case failed         // will retry at nextAttemptAt
    case abandoned      // exceeded retries or user discarded
    case skipped        // not enough observed time to analyze
}

public struct AnalysisWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: WindowKind
    public var start: Date
    public var end: Date?
    public var awakeSeconds: TimeInterval
    /// Wall-clock instant up to which awake time has been accrued (open windows only).
    public var accruedThrough: Date
    public var status: WindowStatus
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    /// Stable per-window key; also sent to connectors so retries never duplicate writes.
    public var idempotencyKey: String
    public var eventIDs: [String]
    /// The exact JSON sent to the model, kept for the "what was sent" transparency view.
    public var requestPayload: String?
    public var resultJSON: String?
    public var createdAt: Date
    public var completedAt: Date?

    public init(id: String = UUID().uuidString, kind: WindowKind, start: Date, end: Date? = nil,
                awakeSeconds: TimeInterval = 0, accruedThrough: Date? = nil, status: WindowStatus = .open,
                attempts: Int = 0, nextAttemptAt: Date? = nil, lastError: String? = nil,
                idempotencyKey: String? = nil, eventIDs: [String] = [], requestPayload: String? = nil,
                resultJSON: String? = nil, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.awakeSeconds = awakeSeconds
        self.accruedThrough = accruedThrough ?? start
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.idempotencyKey = idempotencyKey ?? "atlas-window-\(id)"
        self.eventIDs = eventIDs
        self.requestPayload = requestPayload
        self.resultJSON = resultJSON
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case partial
    case completed
    case deferred
    case dropped
}

public enum PlanSource: String, Codable, Sendable {
    case user, calendar, reminders, agent
}

public struct PlanItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    public var expectedMinutes: Int
    /// 1 = highest.
    public var priority: Int
    public var deadline: Date?
    public var plannedStart: Date?
    public var status: PlanStatus
    public var source: PlanSource
    public var userConfirmed: Bool
    /// Fixed items (e.g. meetings) are never moved by the agent.
    public var isFlexible: Bool
    public var categoryHint: ActivityCategory?
    public var externalID: String?

    public init(id: String = UUID().uuidString, title: String, notes: String? = nil, expectedMinutes: Int,
                priority: Int = 2, deadline: Date? = nil, plannedStart: Date? = nil,
                status: PlanStatus = .notStarted, source: PlanSource = .user, userConfirmed: Bool = true,
                isFlexible: Bool = true, categoryHint: ActivityCategory? = nil, externalID: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.expectedMinutes = expectedMinutes
        self.priority = priority
        self.deadline = deadline
        self.plannedStart = plannedStart
        self.status = status
        self.source = source
        self.userConfirmed = userConfirmed
        self.isFlexible = isFlexible
        self.categoryHint = categoryHint
        self.externalID = externalID
    }
}

public enum AgentActionKind: String, Codable, CaseIterable, Sendable {
    case createFocusBlock = "create_focus_block"
    case createBreak = "create_break"
    case rescheduleTask = "reschedule_task"
    case createReminder = "create_reminder"
    case moveEvent = "move_event"
    case updatePlanItem = "update_plan_item"
    case splitTask = "split_task"
}

public enum AuthorizationStatus: String, Codable, Sendable {
    case pending
    case approved
    case autoApproved = "auto_approved"
    case rejected
    case blockedByPolicy = "blocked_by_policy"
}

public enum ExecutionStatus: String, Codable, Sendable {
    case notStarted = "not_started"
    case executing
    case succeeded
    case failed
    case skippedDuplicate = "skipped_duplicate"
    case skippedConflict = "skipped_conflict"
    case rolledBack = "rolled_back"
}

public struct ProposedChange: Codable, Hashable, Sendable {
    public var title: String
    public var start: Date?
    public var end: Date?
    public var notes: String?
    public var planItemID: String?
    public var planStatus: PlanStatus?

    public init(title: String, start: Date? = nil, end: Date? = nil, notes: String? = nil,
                planItemID: String? = nil, planStatus: PlanStatus? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
        self.planItemID = planItemID
        self.planStatus = planStatus
    }
}

public struct AgentAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var windowID: String?
    public var kind: AgentActionKind
    public var connectorID: String
    /// External resource being modified (event id, reminder id); nil for creations.
    public var targetResourceID: String?
    public var previousState: ProposedChange?
    public var intendedState: ProposedChange
    public var rationale: String
    public var authorization: AuthorizationStatus
    public var execution: ExecutionStatus
    public var result: String?
    /// Derived from window key + action content: identical proposals map to the same key.
    public var idempotencyKey: String
    public var createdAt: Date
    public var executedAt: Date?
    /// Resource created by execution, used to roll back.
    public var createdResourceID: String?

    public init(id: String = UUID().uuidString, windowID: String?, kind: AgentActionKind, connectorID: String,
                targetResourceID: String? = nil, previousState: ProposedChange? = nil,
                intendedState: ProposedChange, rationale: String, authorization: AuthorizationStatus = .pending,
                execution: ExecutionStatus = .notStarted, result: String? = nil, idempotencyKey: String,
                createdAt: Date = Date(), executedAt: Date? = nil, createdResourceID: String? = nil) {
        self.id = id
        self.windowID = windowID
        self.kind = kind
        self.connectorID = connectorID
        self.targetResourceID = targetResourceID
        self.previousState = previousState
        self.intendedState = intendedState
        self.rationale = rationale
        self.authorization = authorization
        self.execution = execution
        self.result = result
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.executedAt = executedAt
        self.createdResourceID = createdResourceID
    }
}

public struct DailySummary: Codable, Hashable, Sendable {
    /// Local calendar day, "yyyy-MM-dd" in `timeZoneID`.
    public var day: String
    public var timeZoneID: String
    public var plannedItemIDs: [String]
    public var totalsByCategory: [String: TimeInterval]
    public var completedItemIDs: [String]
    public var incompleteItemIDs: [String]
    public var assessment: RubricResult?
    public var recommendations: [String]
    public var scheduleChanges: [String]
    public var userFeedback: String?

    public init(day: String, timeZoneID: String, plannedItemIDs: [String] = [],
                totalsByCategory: [String: TimeInterval] = [:], completedItemIDs: [String] = [],
                incompleteItemIDs: [String] = [], assessment: RubricResult? = nil,
                recommendations: [String] = [], scheduleChanges: [String] = [], userFeedback: String? = nil) {
        self.day = day
        self.timeZoneID = timeZoneID
        self.plannedItemIDs = plannedItemIDs
        self.totalsByCategory = totalsByCategory
        self.completedItemIDs = completedItemIDs
        self.incompleteItemIDs = incompleteItemIDs
        self.assessment = assessment
        self.recommendations = recommendations
        self.scheduleChanges = scheduleChanges
        self.userFeedback = userFeedback
    }
}

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case bundleID = "bundle_id"
    case appName = "app_name"
    case domain
    case titleContains = "title_contains"
}

public enum RuleSource: String, Codable, Sendable {
    case builtin, user, correction
}

public struct ClassificationRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var field: RuleField
    /// Lowercased match pattern. Domain rules match the domain and its subdomains.
    public var pattern: String
    /// Optional second condition: window/page title must contain this (lowercased).
    public var titleContains: String?
    public var category: ActivityCategory
    public var confidence: Double
    public var source: RuleSource
    public var createdAt: Date

    public init(id: String = UUID().uuidString, field: RuleField, pattern: String, titleContains: String? = nil,
                category: ActivityCategory, confidence: Double, source: RuleSource, createdAt: Date = Date()) {
        self.id = id
        self.field = field
        self.pattern = pattern.lowercased()
        self.titleContains = titleContains?.lowercased()
        self.category = category
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}

public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Has other attendees: never moved or edited by the agent.
    public var hasAttendees: Bool
    /// Created by ATLAS (carries our marker); only these can be moved under bounded automation.
    public var createdByAtlas: Bool
    public var atlasKey: String?
    public var notes: String?

    public init(id: String, calendarID: String = "default", title: String, start: Date, end: Date,
                isAllDay: Bool = false, hasAttendees: Bool = false, createdByAtlas: Bool = false,
                atlasKey: String? = nil, notes: String? = nil) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.hasAttendees = hasAttendees
        self.createdByAtlas = createdByAtlas
        self.atlasKey = atlasKey
        self.notes = notes
    }

    /// Fixed commitments block scheduling and are never modified.
    public var isFixed: Bool { !createdByAtlas || hasAttendees }
}
