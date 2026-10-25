import Foundation

/// Platform-independent tracker: feeds observations into the state engine, batches writes,
/// checkpoints the open segment, recovers from crashes, and advances analysis windows.
/// The macOS layer only translates system notifications into `observe(_:at:)` calls.
public actor TrackerCore {
    public let store: AtlasStore
    private var engine: ActivityStateEngine
    private var settings: AtlasSettings
    private var buffer: [String: ActivityEvent] = [:]
    private var lastFlush: Date = .distantPast
    public private(set) var lastSessionRebuild: Date = .distantPast
    public static let flushInterval: TimeInterval = 30
    private var running = false

    public init(store: AtlasStore, settings: AtlasSettings, rules: [ClassificationRule]) {
        self.store = store
        self.settings = settings
        self.engine = ActivityStateEngine(policy: TrackingPolicy(settings: settings), classifier: Classifier(userRules: rules))
    }

    public var isRunning: Bool { running }

    public func updateSettings(_ s: AtlasSettings) {
        settings = s
        engine.policy = TrackingPolicy(settings: s)
    }

    public func updateRules(_ rules: [ClassificationRule]) {
        engine.classifier = Classifier(userRules: rules)
    }

    /// Start tracking. Records an explicit "not tracked" gap for any time since the last heartbeat.
    public func start(at now: Date, frontmost: AppInfo?) async throws {
        guard !running else { return }
        if let gap = try await recoveryGap(now: now) { try await store.upsertEvents([gap]) }
        engine.start(at: now, frontmost: frontmost)
        running = true
        if try await store.openWindow() == nil {
            try await store.saveWindow(AwakeWindowManager.newWindow(at: now))
        }
        try await store.heartbeat(at: now, clean: false)
    }

    func recoveryGap(now: Date) async throws -> ActivityEvent? {
        guard let lastEnd = try await store.latestEventEnd(), now.timeIntervalSince(lastEnd) > 5 else { return nil }
        let length = now.timeIntervalSince(lastEnd)
        let clean = try await store.lastHeartbeat()?.clean ?? false
        // We don't know what happened while ATLAS wasn't running. Long gaps are treated as away (not awake,
        // not sleep) so they don't inflate awake time; short gaps stay uncertain.
        let state: ActivityState = length > settings.awayThresholdSeconds ? .away : .uncertain
        return ActivityEvent(start: lastEnd, end: now, rawType: .gap, state: state,
                             classification: Classification(category: .unknown, confidence: 0, evidence: [.none],
                                                            explanation: "ATLAS was not running"),
                             stateNote: clean ? "ATLAS was quit" : "ATLAS stopped unexpectedly or the Mac shut down")
    }

    public func stop(at now: Date) async {
        guard running else { return }
        for e in engine.stop(at: now) { buffer[e.id] = e }
        running = false
        try? await flush(now: now)
        try? await store.heartbeat(at: now, clean: true)
    }

    public func observe(_ obs: ActivitySignal, at now: Date) async {
        guard settings.trackingEnabled else { return }
        let closed = engine.handle(obs, at: now)
        for e in closed { buffer[e.id] = e }
        // Sleep is the moment we're most likely to lose power: persist immediately.
        if obs == .systemWillSleep || obs == .screenLocked || buffer.count >= 25 {
            try? await flush(now: now)
        }
    }

    /// Called by the host on a coarse timer and at `nextDeadline`. Returns windows that just became ready.
    @discardableResult
    public func tick(now: Date) async throws -> [AnalysisWindow] {
        for e in engine.advance(to: now) { buffer[e.id] = e }
        if now.timeIntervalSince(lastFlush) >= Self.flushInterval || !buffer.isEmpty {
            try await flush(now: now)
        }
        return try await accrueWindows(now: now)
    }

    public var nextDeadline: Date? { engine.nextDeadline }
    public var currentState: ActivityState? { engine.currentState }
    public func currentSnapshot(at now: Date) -> ActivityEvent? { engine.snapshot(at: now) }

    private func flush(now: Date) async throws {
        var batch = Array(buffer.values)
        if running, let snap = engine.snapshot(at: now) { batch.append(snap) }
        try await store.upsertEvents(batch)
        buffer.removeAll()
        lastFlush = now
        try await store.heartbeat(at: now, clean: !running)
    }

    private func accrueWindows(now: Date) async throws -> [AnalysisWindow] {
        guard var open = try await store.openWindow() else {
            try await store.saveWindow(AwakeWindowManager.newWindow(at: now))
            return []
        }
        let policy = WindowPolicy(settings: settings)
        var ready: [AnalysisWindow] = []
        // Loop guards against multiple closures in one long catch-up (e.g. after a restart).
        for _ in 0..<64 {
            let events = try await store.events(from: open.start, to: now)
            let r = AwakeWindowManager.accrue(window: open, events: events, through: now, policy: policy)
            if r.closed.isEmpty {
                try await store.saveWindow(r.open)
                break
            }
            for (i, c) in r.closed.enumerated() {
                var closed = c
                closed.eventIDs = try await store.events(from: c.start, to: c.end ?? now).map(\.id)
                let next = i == r.closed.count - 1 ? r.open : nil
                // Closing and opening happen in one transaction (unique index forbids two open windows).
                try await store.rollWindow(closing: closed, opening: next)
                if closed.status == .ready { ready.append(closed) }
            }
            open = r.open
            if r.open.accruedThrough >= now { break }
        }
        return ready
    }

    /// Re-run the classifier over stored, still-inferred events (after rule or classifier improvements).
    /// User-confirmed classifications and excluded events are never touched.
    @discardableResult
    public func reclassify(from: Date, to: Date) async throws -> Int {
        let classifier = engine.classifier
        var changed: [ActivityEvent] = []
        for var e in try await store.events(from: from, to: to)
        where e.classification.origin == .inferred && e.privacy != .excluded && e.state.isEngaged {
            let c = classifier.classify(ClassificationInput(event: e))
            if c.category != e.classification.category || abs(c.confidence - e.classification.confidence) > 0.01 {
                e.classification = c
                changed.append(e)
            }
        }
        try await store.upsertEvents(changed)
        return changed.count
    }

    /// Rebuild sessions for a range (called periodically and after manual edits).
    public func rebuildSessions(from: Date, to: Date) async throws {
        let events = try await store.events(from: from, to: to)
        let (sessions, assignments) = SessionBuilder.build(events)
        try await store.replaceSessions(from: from, to: to, sessions: sessions, assignments: assignments)
        lastSessionRebuild = Date()
    }

    /// Recategorize an event, optionally learning a rule from it.
    public func recategorize(eventID: String, to category: ActivityCategory, learn scope: CorrectionLearner.Scope?) async throws {
        guard var e = try await store.event(id: eventID) else { return }
        e.classification = Classification(category: category, confidence: 1, evidence: [.userCorrection],
                                          explanation: "Set by you", origin: .userConfirmed)
        try await store.upsertEvents([e])
        if let scope, let rule = CorrectionLearner.rule(for: e, category: category, scope: scope) {
            try await store.saveRule(rule)
            updateRules(try await store.rules())
        }
    }
}
