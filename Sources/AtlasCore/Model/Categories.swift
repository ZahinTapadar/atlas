import Foundation

/// The fourteen activity categories ATLAS classifies into.
public enum ActivityCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case focusedWork = "focused_work"
    case coding
    case research
    case reading
    case educationalVideo = "educational_video"
    case entertainmentVideo = "entertainment_video"
    case socialMedia = "social_media"
    case gaming
    case communication
    case administrative
    case personalOrganization = "personal_organization"
    case breakTime = "break"
    case idle
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .focusedWork: "Focused work"
        case .coding: "Coding & development"
        case .research: "Research & learning"
        case .reading: "Reading"
        case .educationalVideo: "Educational video"
        case .entertainmentVideo: "Entertainment video"
        case .socialMedia: "Social media"
        case .gaming: "Gaming"
        case .communication: "Communication"
        case .administrative: "Administrative"
        case .personalOrganization: "Personal organization"
        case .breakTime: "Break"
        case .idle: "Idle"
        case .unknown: "Unclassified"
        }
    }

    /// Coarse buckets used for time-allocation reporting (spec §9B).
    public var allocationGroup: AllocationGroup {
        switch self {
        case .focusedWork, .coding, .administrative, .personalOrganization: .activeWork
        case .research, .educationalVideo: .learning
        case .reading: .reading
        case .entertainmentVideo: .entertainment
        case .gaming: .gaming
        case .socialMedia: .socialMedia
        case .communication: .communication
        case .breakTime: .breaks
        case .idle, .unknown: .idleOrUncertain
        }
    }
}

public enum AllocationGroup: String, Codable, CaseIterable, Sendable {
    case activeWork = "active_work"
    case learning
    case reading
    case entertainment
    case gaming
    case socialMedia = "social_media"
    case communication
    case breaks
    case idleOrUncertain = "idle_or_uncertain"

    public var displayName: String {
        switch self {
        case .activeWork: "Active work"
        case .learning: "Learning & research"
        case .reading: "Reading"
        case .entertainment: "Entertainment"
        case .gaming: "Gaming"
        case .socialMedia: "Social media"
        case .communication: "Communication"
        case .breaks: "Breaks"
        case .idleOrUncertain: "Idle / uncertain"
        }
    }
}

/// What the user was doing with the machine during a segment, independent of category.
public enum ActivityState: String, Codable, CaseIterable, Sendable {
    /// Recent keyboard/mouse/controller input.
    case active
    /// No recent input, but the foreground activity plausibly involves passive
    /// engagement (reading, watching). Counted as awake time, flagged as inferred.
    case passive
    /// No input past the idle threshold.
    case idle
    /// Idle long enough that the user has very likely left. Not the same as sleep.
    case away
    case locked
    case systemSleep = "system_sleep"
    /// We could not determine what was happening (missing permission, gap, crash).
    case uncertain

    /// Whether this time advances the awake-time counter for analysis windows.
    public var countsAsAwake: Bool {
        switch self {
        case .active, .passive, .idle, .uncertain: true
        case .away, .locked, .systemSleep: false
        }
    }

    /// Whether this is time the user was observably engaged with the Mac.
    public var isEngaged: Bool { self == .active || self == .passive }
}

public enum EvidenceSource: String, Codable, CaseIterable, Sendable {
    case appIdentity = "app_identity"
    case windowTitle = "window_title"
    case browserExtension = "browser_extension"
    case browserAutomation = "browser_automation"
    case builtinRule = "builtin_rule"
    case userRule = "user_rule"
    case userCorrection = "user_correction"
    case idleTimer = "idle_timer"
    case systemEvent = "system_event"
    case mediaState = "media_state"
    case none
}

public enum ClassificationOrigin: String, Codable, Sendable {
    case inferred
    case userRule = "user_rule"
    case userConfirmed = "user_confirmed"
}

public struct Classification: Codable, Hashable, Sendable {
    public var category: ActivityCategory
    /// 0...1. Below `Classification.uncertainThreshold` the UI and the agent treat it as uncertain.
    public var confidence: Double
    public var evidence: [EvidenceSource]
    public var explanation: String?
    public var origin: ClassificationOrigin

    public static let uncertainThreshold = 0.5

    public var isUncertain: Bool { origin == .inferred && confidence < Self.uncertainThreshold }

    public init(category: ActivityCategory, confidence: Double, evidence: [EvidenceSource],
                explanation: String? = nil, origin: ClassificationOrigin = .inferred) {
        self.category = category
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
        self.explanation = explanation
        self.origin = origin
    }

    public static let unknown = Classification(category: .unknown, confidence: 0, evidence: [.none],
                                               explanation: "No usable evidence")
}

public enum PrivacyClass: String, Codable, Sendable {
    case normal
    /// Metadata kept locally but titles redacted before any transmission.
    case sensitive
    /// Excluded by user policy: only timing and a placeholder are stored.
    case excluded
}

public enum RawActivityType: String, Codable, Sendable {
    case foregroundApp = "foreground_app"
    case browserTab = "browser_tab"
    case idle
    case systemSleep = "system_sleep"
    case locked
    case gap
}
