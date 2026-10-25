import Foundation

public enum AuthorizationLevel: Int, Codable, CaseIterable, Sendable {
    /// Level 1: agent reads calendars/tasks, never writes.
    case readOnly = 1
    /// Level 2: agent proposes a diff; each write waits for user approval.
    case approvalRequired = 2
    /// Level 3: narrowly defined actions run automatically; everything else needs approval.
    case boundedAutomation = 3

    public var displayName: String {
        switch self {
        case .readOnly: "Read-only"
        case .approvalRequired: "Approval required"
        case .boundedAutomation: "Bounded automation"
        }
    }
}

public struct RubricWeights: Codable, Hashable, Sendable {
    public var priorityAlignment: Double
    public var taskCompletion: Double
    public var focusContinuity: Double
    public var scheduleAdherence: Double

    public init(priorityAlignment: Double = 0.35, taskCompletion: Double = 0.30,
                focusContinuity: Double = 0.20, scheduleAdherence: Double = 0.15) {
        self.priorityAlignment = priorityAlignment
        self.taskCompletion = taskCompletion
        self.focusContinuity = focusContinuity
        self.scheduleAdherence = scheduleAdherence
    }

    public var total: Double { priorityAlignment + taskCompletion + focusContinuity + scheduleAdherence }
}

/// Clock times expressed as minutes after local midnight.
public struct DailyHours: Codable, Hashable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

public struct BoundedAutomationRules: Codable, Hashable, Sendable {
    /// Action kinds that may execute without approval at Level 3.
    public var autoKinds: Set<AgentActionKind>
    /// Auto actions must land within this many hours from now.
    public var horizonHours: Double
    /// Auto actions must fall inside working hours.
    public var requireWorkingHours: Bool

    public init(autoKinds: Set<AgentActionKind> = [.createFocusBlock, .createBreak, .rescheduleTask],
                horizonHours: Double = 8, requireWorkingHours: Bool = true) {
        self.autoKinds = autoKinds
        self.horizonHours = horizonHours
        self.requireWorkingHours = requireWorkingHours
    }
}

public struct AtlasSettings: Codable, Hashable, Sendable {
    // Tracking
    public var trackingEnabled = true
    public var privateMode = false
    public var launchAtLogin = false
    public var captureWindowTitles = true
    public var idleThresholdSeconds: TimeInterval = 120
    /// For reading/video foregrounds, how long without input still counts as passive engagement.
    public var passiveGraceSeconds: TimeInterval = 900
    /// Idle beyond this is classified as "away" (still not sleep).
    public var awayThresholdSeconds: TimeInterval = 1800
    public var excludedBundleIDs: [String] = ["com.1password.1password", "com.agilebits.onepassword7",
                                              "com.apple.keychainaccess"]
    public var sensitiveBundleIDs: [String] = []
    public var excludedDomains: [String] = []
    public var sensitiveDomains: [String] = ["bank", "health", "mychart"]

    // Browser
    public var browserExtensionEnabled = true
    public var browserAutomationEnabled = false
    public var captureFullURLs = false
    public var trackIncognito = false

    // Windows
    public var analysisIntervalHours: Double = 3
    /// A sleep at least this long ends the day and closes a partial window.
    public var dayBreakSleepHours: Double = 4
    /// Partial windows shorter than this are skipped rather than analyzed.
    public var minimumPartialMinutes: Double = 20
    public var sleepSchedule = DailyHours(startMinute: 23 * 60, endMinute: 7 * 60)
    public var workingHours = DailyHours(startMinute: 9 * 60, endMinute: 18 * 60)
    public var quietHours: DailyHours? = DailyHours(startMinute: 22 * 60, endMinute: 8 * 60)

    // Agent
    public var agentEnabled = true
    /// Subscription by default. The API backend is used only if the user selects it; never as a fallback.
    public var agentBackend: AgentBackend = .claudeSubscription
    /// Optional explicit path to the `claude` CLI (otherwise common install locations are searched).
    public var claudeExecutablePath: String?
    public var model = "claude-opus-5-5"
    public var effort = "medium"
    public var maxTimelineEntries = 120
    public var maxRequestBytes = 60_000
    public var reviewBeforeSending = false
    public var sendWindowTitles = true
    public var maxRetries = 6
    public var retryBaseSeconds: TimeInterval = 60
    public var rubricWeights = RubricWeights()

    // Calendar / authorization
    public var authorizationLevel: AuthorizationLevel = .approvalRequired
    public var boundedRules = BoundedAutomationRules()
    public var targetCalendarID: String?
    public var breakEveryMinutes = 90
    public var bufferMinutes = 10

    // Notifications
    public var notificationsEnabled = true
    public var notificationDetail: NotificationDetail = .summary

    // Retention
    public var retentionDays = 90
    public var requestLogRetentionDays = 30

    public init() {}

    public var analysisIntervalSeconds: TimeInterval { analysisIntervalHours * 3600 }
}

public enum NotificationDetail: String, Codable, CaseIterable, Sendable {
    /// "A new report is ready." Nothing else, safe for the lock screen.
    case minimal
    /// Category-level summary and top unfinished task title.
    case summary
}
