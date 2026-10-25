import Foundation

public enum CoordinatorEvent: Sendable {
    case analysisStarted(windowID: String)
    case analysisCompleted(windowID: String, headline: String, topTask: String, pendingApprovals: Int)
    case analysisFailed(windowID: String, error: String, willRetry: Bool)
    case awaitingReview(windowID: String)
    case actionsChanged
}

/// The event-driven agent (System B). Idle between windows; never streams raw events anywhere.
///
/// Retry safety: the model result is persisted *before* actions are derived from it, and actions are
/// derived deterministically with stable idempotency keys. A retry after a crash reuses the stored
/// result instead of calling the model again, so the same window can never produce duplicate actions.
public actor AnalysisCoordinator {
    let store: AtlasStore
    let provider: AnalysisProvider
    let connectors: [CalendarConnector]
    let clock: @Sendable () -> Date
    let health: @Sendable () async -> [String]
    private var handler: (@Sendable (CoordinatorEvent) -> Void)?
    private var inFlight: Set<String> = []
    public private(set) var isProcessing = false

    public init(store: AtlasStore, provider: AnalysisProvider, connectors: [CalendarConnector],
                clock: @escaping @Sendable () -> Date = { Date() },
                health: @escaping @Sendable () async -> [String] = { [] }) {
        self.store = store
        self.provider = provider
        self.connectors = connectors
        self.clock = clock
        self.health = health
    }

    public func setHandler(_ h: @escaping @Sendable (CoordinatorEvent) -> Void) { handler = h }

    /// After a crash or restart: anything left mid-send is retried (reusing any stored result).
    public func recoverAfterRestart() async throws {
        for var w in try await store.windows(status: [.sending]) {
            w.status = .failed
            w.nextAttemptAt = clock()
            w.lastError = "Interrupted (app quit or crashed during analysis)"
            try await store.saveWindow(w)
        }
    }

    // MARK: - Window processing

    public func processDueWindows() async {
        let settings = (try? await store.loadSettings()) ?? AtlasSettings()
        guard settings.agentEnabled else { return }
        guard let due = try? await store.dueWindows(now: clock()) else { return }
        for w in due { _ = await process(windowID: w.id, settings: settings, userApproved: false) }
    }

    public enum Outcome: Sendable, Equatable {
        case analyzed, awaitingReview, skippedNotConfigured, failed(String), alreadyRunning, notFound
    }

    /// Analyze one window. `userApproved` is set when the user reviewed the payload in the UI.
    public func process(windowID: String, settings override: AtlasSettings? = nil, userApproved: Bool) async -> Outcome {
        guard !inFlight.contains(windowID) else { return .alreadyRunning }
        inFlight.insert(windowID)
        isProcessing = true
        defer { inFlight.remove(windowID); isProcessing = !inFlight.isEmpty }

        let settings: AtlasSettings
        if let override { settings = override } else { settings = (try? await store.loadSettings()) ?? AtlasSettings() }
        guard var window = try? await store.window(id: windowID) else { return .notFound }
        if window.status == .analyzed { return .analyzed }

        if window.attempts >= settings.maxRetries {
            window.status = .abandoned
            try? await store.saveWindow(window)
            return .failed("Exceeded retry limit")
        }

        do {
            let ctx = try await context(for: window, settings: settings)
            // Freeze the payload on first preparation so retries send identical data.
            if window.requestPayload == nil {
                window.requestPayload = ctx.payloadJSON
                window.eventIDs = ctx.eventIDs
                try await store.saveWindow(window)
            }
            if settings.reviewBeforeSending && !userApproved && window.resultJSON == nil {
                window.status = .awaitingReview
                try await store.saveWindow(window)
                handler?(.awaitingReview(windowID: window.id))
                return .awaitingReview
            }
            if window.resultJSON == nil {
                guard await provider.isConfigured() else { return .skippedNotConfigured }
            }
            guard try await store.claimWindow(id: window.id) || window.status == .awaitingReview else { return .alreadyRunning }
            if window.status == .awaitingReview {
                window.status = .sending
                try await store.saveWindow(window)
            }
            handler?(.analysisStarted(windowID: window.id))

            let validated: ValidatedAnalysis
            if let stored = window.resultJSON, let v = try? AtlasJSON.decode(ValidatedAnalysis.self, from: stored) {
                validated = v
            } else {
                validated = try await callModel(window: window, payload: window.requestPayload ?? ctx.payloadJSON,
                                                ctx: ctx, settings: settings)
                window.resultJSON = try AtlasJSON.string(validated)
                window.status = .sending
                try await store.saveWindow(window) // durable before any action exists
            }

            let pending = try await deriveActions(from: validated.result, window: window, ctx: ctx, settings: settings)
            window.status = .analyzed
            window.completedAt = clock()
            window.lastError = nil
            try await store.saveWindow(window)
            try await updateDailySummary(window: window, analysis: validated, ctx: ctx)
            await executeApproved(settings: settings)

            handler?(.analysisCompleted(windowID: window.id, headline: validated.result.summary,
                                        topTask: validated.result.mostImportantUnfinishedTask, pendingApprovals: pending))
            return .analyzed
        } catch {
            let message = (error as? ProviderError)?.description ?? "\(error)"
            let retryable = (error as? ProviderError)?.isRetryable ?? true
            window.attempts += 1
            window.status = .failed
            window.lastError = message
            let delay = AwakeWindowManager.backoff(attempt: window.attempts, base: settings.retryBaseSeconds)
            // Permanent errors wait much longer (or until the user fixes config and retries manually).
            window.nextAttemptAt = clock().addingTimeInterval(retryable ? delay : max(delay, 6 * 3600))
            try? await store.saveWindow(window)
            handler?(.analysisFailed(windowID: window.id, error: message, willRetry: window.attempts < settings.maxRetries))
            return .failed(message)
        }
    }

    struct Context: Sendable {
        var package: ActivityPackage
        var payloadJSON: String
        var eventIDs: [String]
        var plan: [PlanItem]
        var calendar: [CalendarEvent]
        var planner: SlotPlanner
        var nextPeriod: DateInterval
        var events: [ActivityEvent]
    }

    func context(for window: AnalysisWindow, settings: AtlasSettings) async throws -> Context {
        let now = clock()
        let end = window.end ?? now
        let tz = TimeZone.current
        let events = try await store.events(from: window.start, to: end)
        let plan = try await store.planItems(includeClosed: true).filter { p in
            p.status != .dropped && (p.status != .completed || (p.plannedStart.map { $0 >= window.start } ?? false))
        }
        let nextStart = max(now, end)
        let nextPeriod = DateInterval(start: nextStart, duration: settings.analysisIntervalSeconds)
        let calRange = DateInterval(start: window.start, end: nextPeriod.end)
        var calendar: [CalendarEvent] = []
        var healthNotes = await health()
        for c in connectors where c.capabilities.contains(.readEvents) {
            do { calendar += try await c.events(in: calRange) } catch {
                healthNotes.append("Calendar \(c.displayName) unavailable; schedule may miss commitments")
            }
        }
        let planner = SlotPlanner(settings: settings, timeZone: tz)
        let free = planner.freeSlots(in: nextPeriod, busy: calendar)
        let rubric = Rubric.evaluate(events: events, window: DateInterval(start: window.start, end: max(window.start, end)),
                                     plan: plan, calendar: calendar, weights: settings.rubricWeights)
        var opts = PackageOptions(maxTimelineEntries: settings.maxTimelineEntries, sendTitles: settings.sendWindowTitles,
                                  timeZone: tz, trackingHealth: healthNotes)
        var package = PackageBuilder.build(window: window, events: events, plan: plan, calendar: calendar, freeSlots: free,
                                           nextPeriod: nextPeriod, rubric: rubric, options: opts, now: now)
        var json = try AtlasJSON.string(package)
        // Enforce the byte budget by shrinking the timeline, then dropping titles.
        while json.utf8.count > settings.maxRequestBytes && opts.maxTimelineEntries > 10 {
            opts.maxTimelineEntries = opts.maxTimelineEntries * 2 / 3
            if opts.maxTimelineEntries <= 40 { opts.sendTitles = false }
            package = PackageBuilder.build(window: window, events: events, plan: plan, calendar: calendar, freeSlots: free,
                                           nextPeriod: nextPeriod, rubric: rubric, options: opts, now: now)
            json = try AtlasJSON.string(package)
        }
        return Context(package: package, payloadJSON: json, eventIDs: events.map(\.id), plan: plan, calendar: calendar,
                       planner: planner, nextPeriod: nextPeriod, events: events)
    }

    /// What would be sent for a window, without sending it (transparency / review UI).
    public func preview(windowID: String) async throws -> String? {
        guard let w = try await store.window(id: windowID) else { return nil }
        if let p = w.requestPayload { return p }
        let s = try await store.loadSettings()
        return try await context(for: w, settings: s).payloadJSON
    }

    private func callModel(window: AnalysisWindow, payload: String, ctx: Context, settings: AtlasSettings) async throws -> ValidatedAnalysis {
        let schemaData = try JSONSerialization.data(withJSONObject: AgentResult.jsonSchema, options: [.sortedKeys])
        let request = AnalysisRequest(system: AgentPrompt.system, userContent: AgentPrompt.userContent(packageJSON: payload),
                                      schemaJSON: String(decoding: schemaData, as: UTF8.self), model: settings.model,
                                      effort: settings.effort)
        let started = clock()
        do {
            let resp = try await provider.analyze(request)
            try? await store.logRequest(.init(windowID: window.id, model: resp.model, requestBytes: payload.utf8.count,
                                              inputTokens: resp.inputTokens, outputTokens: resp.outputTokens,
                                              cacheReadTokens: resp.cacheReadTokens, outcome: "ok",
                                              durationMs: Int(clock().timeIntervalSince(started) * 1000)))
            guard let raw = try? AtlasJSON.decode(AgentResult.self, from: resp.json) else {
                throw ProviderError.invalidResponse("Output did not match the schema")
            }
            return AgentResultValidator.validate(raw, package: ctx.package, plan: ctx.plan, calendar: ctx.calendar,
                                                 planner: ctx.planner, nextPeriod: ctx.nextPeriod)
        } catch {
            try? await store.logRequest(.init(windowID: window.id, model: settings.model, requestBytes: payload.utf8.count,
                                              outcome: "error: \((error as? ProviderError).map { "\($0)" } ?? "unknown")",
                                              durationMs: Int(clock().timeIntervalSince(started) * 1000)))
            throw error
        }
    }

    /// Turn validated corrections into stored actions. Deterministic and idempotent. Returns pending count.
    func deriveActions(from result: AgentResult, window: AnalysisWindow, ctx: Context, settings: AtlasSettings) async throws -> Int {
        let writeConnector = connectors.first { $0.capabilities.contains(.writeEvents) }?.id ?? "none"
        var pending = 0
        for c in result.corrections {
            guard let kind = AgentActionKind(rawValue: c.action) else { continue }
            let start = AgentResultValidator.parseDate(c.start), end = AgentResultValidator.parseDate(c.end)
            var previous: ProposedChange?
            if kind == .moveEvent, let ev = ctx.calendar.first(where: { $0.id == c.targetEventID }) {
                previous = ProposedChange(title: ev.title, start: ev.start, end: ev.end)
            }
            if kind == .rescheduleTask || kind == .updatePlanItem, let item = ctx.plan.first(where: { $0.id == c.planItemID }) {
                previous = ProposedChange(title: item.title, start: item.plannedStart, planItemID: item.id, planStatus: item.status)
            }
            let local = kind == .updatePlanItem || kind == .splitTask
            var action = AgentAction(windowID: window.id, kind: kind, connectorID: local ? "local" : writeConnector,
                                     targetResourceID: c.targetEventID.isEmpty ? nil : c.targetEventID,
                                     previousState: previous,
                                     intendedState: ProposedChange(title: c.title, start: start, end: end, notes: c.reason,
                                                                   planItemID: c.planItemID.isEmpty ? nil : c.planItemID),
                                     rationale: c.reason,
                                     idempotencyKey: AuthorizationPolicy.idempotencyKey(windowKey: window.idempotencyKey, correction: c),
                                     createdAt: clock())
            action.authorization = AuthorizationPolicy.decide(action, level: settings.authorizationLevel, rules: settings.boundedRules,
                                                              planner: ctx.planner, calendar: ctx.calendar, now: clock())
            if !local && writeConnector == "none" && action.authorization != .blockedByPolicy {
                action.result = "No writable calendar connected"
            }
            let stored = try await store.insertActionIfNew(action)
            if stored.action.authorization == .pending { pending += 1 }
        }
        if pending > 0 || !result.corrections.isEmpty { handler?(.actionsChanged) }
        return pending
    }

    private func updateDailySummary(window: AnalysisWindow, analysis: ValidatedAnalysis, ctx: Context) async throws {
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let end = window.end ?? clock()
        let dayStart = cal.startOfDay(for: end.addingTimeInterval(-1))
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: dayStart)

        let dayEvents = TimeAccounting.normalized(try await store.events(from: dayStart, to: dayEnd), from: dayStart, to: dayEnd)
        var totals: [String: TimeInterval] = [:]
        for (k, v) in TimeAccounting.totals(dayEvents) { totals[k.rawValue] = v.observed }
        let plan = try await store.planItems(includeClosed: true)
        let todays = plan.filter { p in p.plannedStart.map { $0 >= dayStart && $0 < dayEnd } ?? false }
        var summary = try await store.dailySummary(day: day) ?? DailySummary(day: day, timeZoneID: tz.identifier)
        summary.totalsByCategory = totals
        summary.plannedItemIDs = todays.map(\.id)
        summary.completedItemIDs = todays.filter { $0.status == .completed }.map(\.id)
        summary.incompleteItemIDs = todays.filter { $0.status != .completed && $0.status != .dropped }.map(\.id)
        summary.assessment = ctx.package.rubric
        summary.recommendations = Array((summary.recommendations + analysis.result.findings
            .filter { $0.kind != "positive" }.map(\.description)).suffix(30))
        summary.scheduleChanges = Array((summary.scheduleChanges + analysis.result.corrections.map { "\($0.action): \($0.title)" }).suffix(30))
        try await store.saveDailySummary(summary)
    }

    // MARK: - User decisions on actions

    public func approve(actionID: String, edited: ProposedChange? = nil) async throws {
        guard var a = try await store.action(id: actionID), a.authorization == .pending else { return }
        if let edited { a.intendedState = edited }
        a.authorization = .approved
        try await store.saveAction(a)
        handler?(.actionsChanged)
        await executeApproved(settings: try await store.loadSettings())
    }

    public func reject(actionID: String) async throws {
        guard var a = try await store.action(id: actionID), a.authorization == .pending else { return }
        a.authorization = .rejected
        a.result = "Rejected by you"
        try await store.saveAction(a)
        handler?(.actionsChanged)
    }

    /// Retry an approved action whose execution failed (e.g. the calendar was offline).
    public func retry(actionID: String) async throws {
        guard var a = try await store.action(id: actionID), a.execution == .failed,
              a.authorization == .approved || a.authorization == .autoApproved else { return }
        a.execution = .notStarted
        try await store.saveAction(a)
        await executeApproved(settings: try await store.loadSettings())
    }

    public func rollback(actionID: String) async throws {
        guard let a = try await store.action(id: actionID) else { return }
        await ActionExecutor(store: store, connectors: connectors).rollback(a)
        handler?(.actionsChanged)
    }

    /// Run every approved action that has not completed (also resumes ones interrupted mid-execution).
    public func executeApproved(settings: AtlasSettings) async {
        guard let list = try? await store.executableActions(), !list.isEmpty else { return }
        let executor = ActionExecutor(store: store, connectors: connectors)
        let planner = SlotPlanner(settings: settings)
        for a in list { await executor.execute(a, settings: settings, planner: planner) }
        handler?(.actionsChanged)
    }

    // MARK: - Manual analysis

    /// Analyze [open window start, now] now. Creates a separate manual window, leaving scheduled boundaries untouched.
    public func requestManualAnalysis(from: Date? = nil) async throws -> String {
        let now = clock()
        let open = try await store.openWindow()
        let start = from ?? open?.start ?? now.addingTimeInterval(-3600)
        let events = try await store.events(from: start, to: now)
        let manual = AwakeWindowManager.manualWindow(from: start, to: now, events: events)
        try await store.saveWindow(manual)
        _ = await process(windowID: manual.id, userApproved: false)
        return manual.id
    }

    /// Explicit user-requested reanalysis of a past window: new manual window over the same range.
    public func reanalyze(windowID: String) async throws -> String? {
        guard let w = try await store.window(id: windowID), let end = w.end else { return nil }
        let events = try await store.events(from: w.start, to: end)
        let copy = AwakeWindowManager.manualWindow(from: w.start, to: end, events: events)
        try await store.saveWindow(copy)
        _ = await process(windowID: copy.id, userApproved: false)
        return copy.id
    }

    public func discard(windowID: String) async throws {
        guard var w = try await store.window(id: windowID), w.status != .open else { return }
        w.status = .abandoned
        w.lastError = "Discarded by you"
        try await store.saveWindow(w)
    }
}
