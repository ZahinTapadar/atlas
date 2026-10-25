import XCTest
@testable import AtlasCore

final class AgentTests: XCTestCase {
    var store: AtlasStore!
    var calendar: InMemoryCalendarConnector!
    var provider: MockProvider!
    let now = at(200)

    override func setUp() async throws {
        store = try AtlasStore.inMemory()
        calendar = InMemoryCalendarConnector(events: [
            CalendarEvent(id: "m1", title: "Team sync", start: at(260), end: at(290), hasAttendees: true),
        ])
        provider = MockProvider()
        var s = makeSettings()
        s.workingHours = DailyHours(startMinute: 0, endMinute: 1440)
        s.boundedRules = BoundedAutomationRules(horizonHours: 24, requireWorkingHours: false)
        try await store.saveSettings(s)
        try await store.upsertEvents([ev(0, 120), ev(120, 180, category: .socialMedia, app: chrome)])
    }

    func coordinator() -> AnalysisCoordinator {
        let fixed = now
        return AnalysisCoordinator(store: store, provider: provider, connectors: [calendar], clock: { fixed })
    }

    func readyWindow() async throws -> AnalysisWindow {
        let w = AnalysisWindow(kind: .scheduled, start: at(0), end: at(180), awakeSeconds: 10800, status: .ready)
        try await store.saveWindow(w)
        return w
    }

    func focusCorrection(_ start: Double = 210, _ end: Double = 250, title: String = "Focus: write report") -> AgentResult.Correction {
        .init(action: "create_focus_block", title: title, reason: "Unfinished report; 60 min social media",
              planItemID: "", targetEventID: "", start: iso(at(start)), end: iso(at(end)))
    }

    func setLevel(_ level: AuthorizationLevel) async throws {
        var s = try await store.loadSettings()
        s.authorizationLevel = level
        try await store.saveSettings(s)
    }

    // 12. Retrying a failed analysis does not duplicate the same report or external action.
    func testRetryDoesNotDuplicateReportOrActions() async throws {
        try await setLevel(.boundedAutomation)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection()]))
        await provider.setFailures(1)
        let c = coordinator()
        let w = try await readyWindow()

        let first = await c.process(windowID: w.id, userApproved: false)
        guard case .failed = first else { return XCTFail("expected failure, got \(first)") }
        var stored = try await store.window(id: w.id)!
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.attempts, 1)
        XCTAssertNotNil(stored.nextAttemptAt)
        let frozenPayload = stored.requestPayload

        let second = await c.process(windowID: w.id, userApproved: false)
        XCTAssertEqual(second, .analyzed)
        stored = try await store.window(id: w.id)!
        XCTAssertEqual(stored.requestPayload, frozenPayload, "retries send identical data")
        let writesAfterFirstSuccess = await calendar.writeCount
        XCTAssertEqual(writesAfterFirstSuccess, 1)

        // Simulate a crash right after the result was stored: status back to sending.
        stored.status = .sending
        try await store.saveWindow(stored)
        try await c.recoverAfterRestart()
        let third = await c.process(windowID: w.id, userApproved: false)
        XCTAssertEqual(third, .analyzed)
        let calls = await provider.calls
        XCTAssertEqual(calls, 2, "stored result reused; model not called again")
        let actions = try await store.actions(windowID: w.id)
        XCTAssertEqual(actions.count, 1)
        let writes = await calendar.writeCount
        XCTAssertEqual(writes, 1, "no duplicate calendar event")
    }

    // 13. Manual analysis does not corrupt subsequent window boundaries.
    func testManualAnalysisLeavesScheduledWindowIntact() async throws {
        let open = AwakeWindowManager.newWindow(at: at(0))
        var o = open
        o.awakeSeconds = 7200
        o.accruedThrough = at(120)
        try await store.saveWindow(o)
        let c = coordinator()
        let manualID = try await c.requestManualAnalysis()
        let stillOpen = try await store.openWindow()
        XCTAssertEqual(stillOpen?.id, o.id)
        XCTAssertEqual(stillOpen?.start, o.start)
        XCTAssertEqual(stillOpen?.awakeSeconds, 7200)
        let manual = try await store.window(id: manualID)!
        XCTAssertEqual(manual.kind, .manual)
        XCTAssertEqual(manual.status, .analyzed)

        // Accrual continues from where it was.
        let r = AwakeWindowManager.accrue(window: stillOpen!, events: [ev(0, 120), ev(120, 200)], through: at(200),
                                          policy: WindowPolicy(interval: 10800, dayBreak: 14400, minimumPartial: 1200))
        XCTAssertEqual(r.closed.first?.end, at(180))
    }

    // 19. Read-only authorization prevents calendar writes.
    func testReadOnlyPreventsWrites() async throws {
        try await setLevel(.readOnly)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection()]))
        let w = try await readyWindow()
        _ = await coordinator().process(windowID: w.id, userApproved: false)
        let a = try await store.actions(windowID: w.id)
        XCTAssertEqual(a.first?.authorization, .blockedByPolicy)
        let writes = await calendar.writeCount
        XCTAssertEqual(writes, 0)

        // Even a forged approval is refused at execution time.
        var forged = a[0]
        forged.authorization = .approved
        try await store.saveAction(forged)
        await coordinator().executeApproved(settings: try await store.loadSettings())
        let writes2 = await calendar.writeCount
        XCTAssertEqual(writes2, 0)
    }

    // 20 & 21. Approval-required actions stay pending; rejected ones never execute.
    func testApprovalFlow() async throws {
        try await setLevel(.approvalRequired)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection(), focusCorrection(300, 330, title: "Break walk")]))
        let w = try await readyWindow()
        let c = coordinator()
        _ = await c.process(windowID: w.id, userApproved: false)
        var actions = try await store.actions(windowID: w.id)
        XCTAssertEqual(actions.map(\.authorization), [.pending, .pending])
        var writes = await calendar.writeCount
        XCTAssertEqual(writes, 0, "nothing runs before approval")

        try await c.reject(actionID: actions[1].id)
        try await c.approve(actionID: actions[0].id)
        actions = try await store.actions(windowID: w.id)
        XCTAssertEqual(actions[0].execution, .succeeded)
        XCTAssertEqual(actions[1].authorization, .rejected)
        XCTAssertEqual(actions[1].execution, .notStarted)
        writes = await calendar.writeCount
        XCTAssertEqual(writes, 1)

        // Approving a rejected action is a no-op.
        try await c.approve(actionID: actions[1].id)
        writes = await calendar.writeCount
        XCTAssertEqual(writes, 1)
    }

    // 22. Duplicate requests do not create duplicate events.
    func testDuplicateRequestsDoNotDuplicateEvents() async throws {
        try await setLevel(.boundedAutomation)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection(), focusCorrection()]))
        let w1 = try await readyWindow()
        let c = coordinator()
        _ = await c.process(windowID: w1.id, userApproved: false)
        _ = await c.process(windowID: w1.id, userApproved: false)
        // A different window proposing the same block (different idempotency key) is caught semantically.
        let w2 = AnalysisWindow(kind: .manual, start: at(0), end: at(180), status: .ready)
        try await store.saveWindow(w2)
        _ = await c.process(windowID: w2.id, userApproved: false)

        let created = await calendar.stored.filter { $0.createdByAtlas }
        XCTAssertEqual(created.count, 1)
        let all = try await store.actions()
        XCTAssertEqual(all.filter { $0.execution == .succeeded }.count, 1)
        XCTAssertEqual(all.filter { $0.execution == .skippedDuplicate }.count, 1)
    }

    // 23. Connector failures are logged and recoverable.
    func testConnectorFailureIsRecoverable() async throws {
        try await setLevel(.approvalRequired)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection()]))
        let w = try await readyWindow()
        let c = coordinator()
        _ = await c.process(windowID: w.id, userApproved: false)
        let a = try await store.actions(windowID: w.id)[0]
        await calendar.setFailNextWrite(true)
        try await c.approve(actionID: a.id)
        var stored = try await store.action(id: a.id)!
        XCTAssertEqual(stored.execution, .failed)
        XCTAssertTrue(stored.result?.contains("simulated write failure") ?? false)
        try await c.retry(actionID: a.id)
        stored = try await store.action(id: a.id)!
        XCTAssertEqual(stored.execution, .succeeded)
        let n = await calendar.stored.filter { $0.createdByAtlas }.count
        XCTAssertEqual(n, 1)
    }

    func testCalendarOfflineStillAnalyzesWithHealthNote() async throws {
        await calendar.setConnected(false)
        let w = try await readyWindow()
        let outcome = await coordinator().process(windowID: w.id, userApproved: false)
        XCTAssertEqual(outcome, .analyzed)
        let payload = try await store.window(id: w.id)!.requestPayload!
        XCTAssertTrue(payload.contains("Calendar In-memory calendar unavailable"))
    }

    func testMoveOfSharedMeetingIsNeverAllowed() {
        let meeting = CalendarEvent(id: "m1", title: "Sync", start: at(260), end: at(290), hasAttendees: true)
        let a = AgentAction(windowID: nil, kind: .moveEvent, connectorID: "memory", targetResourceID: "m1",
                            intendedState: ProposedChange(title: "Sync", start: at(300), end: at(330)), rationale: "", idempotencyKey: "k")
        for level in AuthorizationLevel.allCases {
            XCTAssertEqual(AuthorizationPolicy.decide(a, level: level, rules: BoundedAutomationRules(),
                                                      planner: SlotPlanner(workingHours: DailyHours(startMinute: 0, endMinute: 1440)),
                                                      calendar: [meeting], now: at(200)), .blockedByPolicy)
        }
    }

    func testRollbackRemovesCreatedEvent() async throws {
        try await setLevel(.boundedAutomation)
        await provider.setResult(MockProvider.sampleResult(corrections: [focusCorrection()]))
        let w = try await readyWindow()
        let c = coordinator()
        _ = await c.process(windowID: w.id, userApproved: false)
        let a = try await store.actions(windowID: w.id)[0]
        XCTAssertEqual(a.authorization, .autoApproved)
        try await c.rollback(actionID: a.id)
        let n = await calendar.stored.filter { $0.createdByAtlas }.count
        XCTAssertEqual(n, 0)
        let after = try await store.action(id: a.id)
        XCTAssertEqual(after?.execution, .rolledBack)
    }

    func testReviewBeforeSendingHoldsRequest() async throws {
        var s = try await store.loadSettings()
        s.reviewBeforeSending = true
        try await store.saveSettings(s)
        let w = try await readyWindow()
        let c = coordinator()
        let outcome = await c.process(windowID: w.id, userApproved: false)
        XCTAssertEqual(outcome, .awaitingReview)
        var calls = await provider.calls
        XCTAssertEqual(calls, 0)
        let approved = await c.process(windowID: w.id, userApproved: true)
        XCTAssertEqual(approved, .analyzed)
        calls = await provider.calls
        XCTAssertEqual(calls, 1)
    }

    func testNotConfiguredLeavesWindowQueued() async throws {
        let p = MockProvider()
        await p.setConfiguredForTest(false)
        let w = try await readyWindow()
        let c = AnalysisCoordinator(store: store, provider: p, connectors: [], clock: { at(200) })
        let outcome = await c.process(windowID: w.id, userApproved: false)
        XCTAssertEqual(outcome, .skippedNotConfigured)
        let stored = try await store.window(id: w.id)
        XCTAssertEqual(stored?.status, .ready, "queued, not lost, not burning retries")
    }
}

extension MockProvider {
    func setConfiguredForTest(_ v: Bool) { configured = v }
}
