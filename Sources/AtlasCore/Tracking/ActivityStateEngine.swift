import Foundation

public struct AppInfo: Sendable, Hashable {
    public var bundleID: String?
    public var name: String?
    public var pid: Int32?
    public init(bundleID: String?, name: String?, pid: Int32? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

public struct BrowserTabInfo: Sendable, Hashable, Codable {
    /// Browser family as reported by the extension: "chrome", "edge", "brave", "arc", "firefox", ...
    public var family: String
    public var url: String?
    public var title: String?
    public var incognito: Bool
    public var audible: Bool
    public var windowFocused: Bool

    public init(family: String, url: String?, title: String?, incognito: Bool = false, audible: Bool = false,
                windowFocused: Bool = true) {
        self.family = family
        self.url = url
        self.title = title
        self.incognito = incognito
        self.audible = audible
        self.windowFocused = windowFocused
    }

    public var domain: String? {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return Classifier.normalizeDomain(host)
    }
}

/// Raw signals from the platform layer. All are timestamped by the caller.
public enum ActivitySignal: Sendable, Hashable {
    case appActivated(AppInfo)
    /// `available == false` means the title could not be read (no Accessibility permission, app refuses).
    case windowTitle(String?, available: Bool)
    case browserTab(BrowserTabInfo)
    /// The idle monitor detected that the last input happened at `lastInput`.
    case inputIdle(lastInput: Date)
    case inputResumed
    case systemWillSleep
    case systemDidWake
    case screenLocked
    case screenUnlocked
    case displaySlept
    case displayWoke
}

public struct TrackingPolicy: Sendable {
    public var idleThreshold: TimeInterval
    public var passiveGrace: TimeInterval
    public var awayThreshold: TimeInterval
    public var captureWindowTitles: Bool
    public var captureFullURLs: Bool
    public var trackIncognito: Bool
    public var privateMode: Bool
    public var excludedBundleIDs: Set<String>
    public var sensitiveBundleIDs: Set<String>
    public var excludedDomains: [String]
    public var sensitiveDomains: [String]

    public init(settings s: AtlasSettings) {
        idleThreshold = s.idleThresholdSeconds
        passiveGrace = max(s.passiveGraceSeconds, s.idleThresholdSeconds)
        awayThreshold = max(s.awayThresholdSeconds, s.idleThresholdSeconds)
        captureWindowTitles = s.captureWindowTitles
        captureFullURLs = s.captureFullURLs
        trackIncognito = s.trackIncognito
        privateMode = s.privateMode
        excludedBundleIDs = Set(s.excludedBundleIDs.map { $0.lowercased() })
        sensitiveBundleIDs = Set(s.sensitiveBundleIDs.map { $0.lowercased() })
        excludedDomains = s.excludedDomains.map { $0.lowercased() }
        sensitiveDomains = s.sensitiveDomains.map { $0.lowercased() }
    }

    func isExcluded(bundle: String?) -> Bool { bundle.map { excludedBundleIDs.contains($0.lowercased()) } ?? false }
    func isSensitive(bundle: String?) -> Bool { bundle.map { sensitiveBundleIDs.contains($0.lowercased()) } ?? false }
    /// Domain patterns match the domain, its subdomains, or (for bare words like "bank") any label containing them.
    static func domainHit(_ domain: String, _ patterns: [String]) -> Bool {
        patterns.contains { p in
            p.contains(".") ? Classifier.domainMatches(domain, p) : domain.split(separator: ".").contains { $0.contains(p) }
        }
    }
}

/// Deterministic state machine that turns platform observations into contiguous, non-overlapping
/// timeline segments. It never polls: the host calls `advance(to:)` at `nextDeadline`.
///
/// Invariants (tested):
/// - Segments emitted are contiguous and never overlap; total emitted time == wall time observed.
/// - Background apps never produce segments; only the foreground context does.
/// - Idle is not sleep: only system sleep events produce `systemSleep`.
/// - Excluded apps/domains produce segments with no identifying metadata.
public struct ActivityStateEngine: Sendable {
    public var policy: TrackingPolicy
    public var classifier: Classifier

    struct Context: Sendable {
        var id = UUID().uuidString
        var start: Date
        var app: AppInfo?
        var windowTitle: String?
        var titleAvailable = true
        var tab: BrowserTabInfo?
        var state: ActivityState
        var rawType: RawActivityType
        var note: String?
    }

    private var current: Context?
    private var lastApp: AppInfo?
    private var lastWindowTitle: String?
    private var lastTitleAvailable = true
    private var latestTabs: [String: BrowserTabInfo] = [:]
    /// When input stopped, while idle/passive. nil while active.
    private var idleSince: Date?
    private var sleeping = false
    private var locked = false
    private var displayAsleep = false

    public init(policy: TrackingPolicy, classifier: Classifier = Classifier()) {
        self.policy = policy
        self.classifier = classifier
    }

    public var isRunning: Bool { current != nil }
    public var currentState: ActivityState? { current?.state }

    /// Start tracking at `at` (app launch / wake from recovery).
    public mutating func start(at: Date, frontmost: AppInfo?) {
        lastApp = frontmost
        current = makeContext(at: at, state: .active)
    }

    /// Stop tracking; returns the final segment.
    public mutating func stop(at: Date) -> [ActivityEvent] {
        guard let c = current else { return [] }
        current = nil
        return emit(c, end: at).map { [$0] } ?? []
    }

    /// The in-progress segment, closed provisionally at `at`. It keeps a stable id, so upserting it
    /// repeatedly checkpoints the open segment without fragmenting the timeline.
    public func snapshot(at: Date) -> ActivityEvent? {
        guard let c = current else { return nil }
        return emit(c, end: max(at, c.start))
    }

    /// The next instant at which a time-based transition (passive→idle, idle→away) is due.
    public var nextDeadline: Date? {
        guard let idleSince, let c = current else { return nil }
        switch c.state {
        case .passive: return idleSince.addingTimeInterval(policy.passiveGrace)
        case .idle: return idleSince.addingTimeInterval(policy.awayThreshold)
        default: return nil
        }
    }

    /// Apply any time-based transitions that are due at `now`.
    public mutating func advance(to now: Date) -> [ActivityEvent] {
        var out: [ActivityEvent] = []
        while let deadline = nextDeadline, deadline <= now, let c = current {
            let next: ActivityState = c.state == .passive ? .idle : .away
            out += transition(at: deadline, to: next, rawType: .idle)
        }
        return out
    }

    public mutating func handle(_ obs: ActivitySignal, at rawAt: Date) -> [ActivityEvent] {
        guard current != nil else {
            // Not started yet: remember context only.
            absorb(obs)
            return []
        }
        // Wall clock moved backwards (manual change / NTP step): never emit negative or overlapping time.
        let at = max(rawAt, current!.start)
        var out = advance(to: at)

        switch obs {
        case .appActivated, .windowTitle, .browserTab:
            absorb(obs)
            guard !sleeping, !locked else { return out }
            // A foreground change is evidence of interaction.
            if idleSince != nil, case .appActivated = obs { idleSince = nil }
            let state: ActivityState = idleSince == nil ? .active : current!.state
            let candidate = makeContext(at: at, state: state)
            if differs(candidate, current!) { out += replace(with: candidate, at: at) }

        case .inputIdle(let lastInput):
            guard !sleeping, !locked, idleSince == nil else { return out }
            // Input stopped at lastInput; the time since then was not active. Never go before the segment start.
            let since = min(max(lastInput, current!.start), at)
            idleSince = since
            let passive = passiveEligible()
            out += transition(at: since, to: passive ? .passive : .idle, rawType: passive ? current!.rawType : .idle)
            out += advance(to: at)

        case .inputResumed:
            guard !sleeping, !locked, idleSince != nil else { return out }
            idleSince = nil
            out += replace(with: makeContext(at: at, state: displayAsleep ? .away : .active), at: at)

        case .systemWillSleep:
            guard !sleeping else { return out }
            sleeping = true
            idleSince = nil
            out += replace(with: Context(start: at, state: .systemSleep, rawType: .systemSleep, note: "System sleep"), at: at)

        case .systemDidWake:
            guard sleeping else { return out }
            sleeping = false
            displayAsleep = false
            out += replace(with: locked ? lockedContext(at) : makeContext(at: at, state: .active), at: at)

        case .screenLocked:
            guard !locked else { return out }
            locked = true
            idleSince = nil
            if !sleeping { out += replace(with: lockedContext(at), at: at) }

        case .screenUnlocked:
            guard locked else { return out }
            locked = false
            if !sleeping { out += replace(with: makeContext(at: at, state: .active), at: at) }

        case .displaySlept:
            displayAsleep = true
            guard !sleeping, !locked else { return out }
            if !(current!.tab?.audible ?? false) {
                out += replace(with: Context(start: at, app: nil, state: .away, rawType: .idle, note: "Display asleep"), at: at)
            }

        case .displayWoke:
            displayAsleep = false
            guard !sleeping, !locked else { return out }
            if current!.state == .away && idleSince == nil {
                out += replace(with: makeContext(at: at, state: .active), at: at)
            }
        }
        return out
    }

    // MARK: - Internals

    private mutating func absorb(_ obs: ActivitySignal) {
        switch obs {
        case .appActivated(let app):
            if app.bundleID != lastApp?.bundleID {
                lastWindowTitle = nil
                lastTitleAvailable = true
            }
            lastApp = app
        case .windowTitle(let t, let available):
            lastWindowTitle = t
            lastTitleAvailable = available
        case .browserTab(let tab):
            latestTabs[tab.family] = tab
        default: break
        }
    }

    private func lockedContext(_ at: Date) -> Context {
        Context(start: at, state: .locked, rawType: .locked, note: "Screen locked")
    }

    private func makeContext(at: Date, state: ActivityState) -> Context {
        var c = Context(start: at, app: lastApp, windowTitle: policy.captureWindowTitles ? lastWindowTitle : nil,
                        titleAvailable: lastTitleAvailable, state: state, rawType: .foregroundApp)
        if let bundle = lastApp?.bundleID, let family = BrowserFamily.family(forBundle: bundle) {
            if let tab = latestTabs[family] {
                c.tab = tab
                c.rawType = .browserTab
            } else {
                c.note = "Browser tab data unavailable"
            }
        }
        if !lastTitleAvailable, c.note == nil { c.note = "Window title unavailable (Accessibility not granted or app refused)" }
        return c
    }

    private func differs(_ a: Context, _ b: Context) -> Bool {
        a.app?.bundleID != b.app?.bundleID || a.app?.pid != b.app?.pid || a.windowTitle != b.windowTitle
            || a.tab?.url != b.tab?.url || a.tab?.title != b.tab?.title || a.tab?.audible != b.tab?.audible
            || a.state != b.state || a.rawType != b.rawType || a.titleAvailable != b.titleAvailable
    }

    private mutating func replace(with next: Context, at: Date) -> [ActivityEvent] {
        guard let c = current else { current = next; return [] }
        var n = next
        n.start = at
        // Signals often arrive in bursts (app switch, then its window title). A segment shorter than a
        // second is folded into its successor, reusing its id so any checkpointed copy is overwritten.
        if at.timeIntervalSince(c.start) < 1 {
            n.start = c.start
            n.id = c.id
            current = n
            return []
        }
        current = n
        return emit(c, end: at).map { [$0] } ?? []
    }

    /// Change only the activity state of the current context (keeping app/tab), effective at `at`.
    private mutating func transition(at: Date, to state: ActivityState, rawType: RawActivityType) -> [ActivityEvent] {
        guard var next = current else { return [] }
        next.id = UUID().uuidString
        next.state = state
        if state == .idle || state == .away {
            next.rawType = .idle
        } else {
            next.rawType = rawType
        }
        return replace(with: next, at: at)
    }

    /// Whether no-input time in the current context can plausibly be passive engagement.
    private func passiveEligible() -> Bool {
        guard let c = current else { return false }
        if c.tab?.audible == true { return true }
        let cls = classifier.classify(input(for: c, state: .active))
        let passiveCats: Set<ActivityCategory> = [.reading, .educationalVideo, .entertainmentVideo, .research, .gaming]
        return passiveCats.contains(cls.category) && cls.confidence >= 0.4
    }

    private func input(for c: Context, state: ActivityState) -> ClassificationInput {
        ClassificationInput(bundleID: c.app?.bundleID, appName: c.app?.name, windowTitle: c.windowTitle,
                            domain: c.tab?.domain, pageTitle: c.tab?.title, state: state)
    }

    private func emit(_ c: Context, end: Date) -> ActivityEvent? {
        guard end > c.start else { return nil }
        let tz = TimeZone.current.identifier

        // Private mode / exclusions: keep timing and state only. Nothing identifying is retained.
        let domain = c.tab?.domain
        let excluded = policy.privateMode || policy.isExcluded(bundle: c.app?.bundleID)
            || (domain.map { TrackingPolicy.domainHit($0, policy.excludedDomains) } ?? false)
            || (c.tab?.incognito == true && !policy.trackIncognito)
        if excluded {
            let cls = Classification(category: c.state.isEngaged ? .unknown : .idle, confidence: c.state.isEngaged ? 0 : 0.85,
                                     evidence: [.none], explanation: "Excluded by your privacy settings")
            return ActivityEvent(id: c.id, start: c.start, end: end, rawType: c.rawType == .browserTab ? .foregroundApp : c.rawType,
                                 state: c.state, classification: cls, privacy: .excluded, timeZoneID: tz,
                                 stateNote: policy.privateMode ? "Private mode" : "Excluded")
        }

        let sensitive = policy.isSensitive(bundle: c.app?.bundleID)
            || (domain.map { TrackingPolicy.domainHit($0, policy.sensitiveDomains) } ?? false)
        let browser = c.tab.map {
            BrowserContext(browser: BrowserFamily.displayName($0.family), domain: $0.domain, title: $0.title,
                           url: policy.captureFullURLs ? $0.url : nil, isIncognito: $0.incognito, isAudible: $0.audible)
        }
        var cls = classifier.classify(input(for: c, state: c.state))
        if c.tab?.audible == true, c.state == .passive { cls.evidence.append(.mediaState) }
        return ActivityEvent(id: c.id, start: c.start, end: end, appBundleID: c.app?.bundleID, appName: c.app?.name,
                             pid: c.app?.pid, windowTitle: c.windowTitle, browser: browser, rawType: c.rawType,
                             state: c.state, classification: cls, privacy: sensitive ? .sensitive : .normal,
                             timeZoneID: tz, stateNote: c.note)
    }
}

public enum BrowserFamily {
    static let bundles: [String: String] = [
        "com.google.chrome": "chrome", "com.google.chrome.canary": "chrome", "org.chromium.chromium": "chrome",
        "com.microsoft.edgemac": "edge", "com.brave.browser": "brave", "company.thebrowser.browser": "arc",
        "com.vivaldi.vivaldi": "vivaldi", "com.operasoftware.opera": "opera", "org.mozilla.firefox": "firefox",
        "app.zen-browser.zen": "zen", "com.apple.safari": "safari",
    ]

    public static func family(forBundle bundle: String) -> String? { bundles[bundle.lowercased()] }

    public static func displayName(_ family: String) -> String {
        switch family {
        case "chrome": "Chrome"
        case "edge": "Edge"
        case "brave": "Brave"
        case "arc": "Arc"
        case "vivaldi": "Vivaldi"
        case "opera": "Opera"
        case "firefox": "Firefox"
        case "zen": "Zen"
        case "safari": "Safari"
        default: family.capitalized
        }
    }
}
