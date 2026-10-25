import XCTest
@testable import AtlasCore

final class AnalysisTests: XCTestCase {
    let window = DateInterval(start: at(0), end: at(180))

    func build(_ events: [ActivityEvent], plan: [PlanItem] = [], calendar: [CalendarEvent] = [],
               settings: AtlasSettings = makeSettings()) -> ActivityPackage {
        var w = AnalysisWindow(kind: .scheduled, start: window.start, end: window.end, awakeSeconds: 10800, status: .ready)
        w.id = "w1"
        let rubric = Rubric.evaluate(events: events, window: window, plan: plan, calendar: calendar, weights: settings.rubricWeights)
        let next = DateInterval(start: at(180), duration: 3 * 3600)
        let planner = SlotPlanner(workingHours: DailyHours(startMinute: 0, endMinute: 24 * 60), timeZone: TimeZone(identifier: "UTC")!)
        return PackageBuilder.build(window: w, events: events, plan: plan, calendar: calendar,
                                    freeSlots: planner.freeSlots(in: next, busy: calendar), nextPeriod: next, rubric: rubric,
                                    options: PackageOptions(timeZone: TimeZone(identifier: "UTC")!), now: at(180))
    }

    // 14. Category totals do not exceed observed time because of double-counting.
    func testTotalsNeverExceedObservedTime() {
        // Deliberately overlapping events (e.g. after a manual edit) plus events spilling outside the window.
        let events = [ev(-30, 60), ev(30, 120, app: chrome, title: "Docs"), ev(100, 150, category: .socialMedia, app: chrome),
                      ev(140, 240, category: .gaming, app: game)]
        let normalized = TimeAccounting.normalized(events, from: window.start, to: window.end)
        assertTiles(normalized, from: at(0), to: at(180))
        let p = build(events)
        let total = p.totals.reduce(0) { $0 + $1.observedMinutes }
        XCTAssertLessThanOrEqual(total, p.wallMinutes + 0.1)
        XCTAssertEqual(total, 180, accuracy: 0.5)
    }

    // 15. Low-confidence activities remain uncertain.
    func testLowConfidenceStaysUncertain() {
        let p = build([ev(0, 90, category: .entertainmentVideo, confidence: 0.3, app: chrome), ev(90, 180, confidence: 0.9)])
        let low = p.timeline.first { $0.category == "entertainment_video" }!
        XCTAssertTrue(low.uncertain)
        XCTAssertEqual(low.confidence, 0.3, accuracy: 0.001)
        XCTAssertFalse(p.timeline.first { $0.category == "coding" }!.uncertain)
    }

    // 16. Missing evidence is never presented as fact.
    func testMissingEvidenceIsReportedAsMissing() {
        let gap = ActivityEvent(start: at(60), end: at(170), rawType: .gap, state: .away,
                                classification: Classification(category: .unknown, confidence: 0, evidence: [.none]))
        let p = build([ev(0, 20), gap])
        XCTAssertEqual(p.notObservedMinutes, 50, accuracy: 0.1, "holes in the timeline are counted as not observed")
        XCTAssertTrue(p.timeline.contains { $0.source == "not tracked" })
        XCTAssertTrue(p.rubric.insufficientData)
        XCTAssertNil(p.rubric.score, "no score is fabricated from 20 minutes of data")

        // A model claim of completion without strong evidence is downgraded.
        let item = PlanItem(id: "p1", title: "Write report", expectedMinutes: 60)
        var raw = MockProvider.sampleResult()
        raw.planAssessment = [.init(planItemID: "p1", title: "Write report", assessedStatus: "completed", evidence: "IDE open", confidence: 0.5),
                              .init(planItemID: "ghost", title: "Invented", assessedStatus: "completed", evidence: "", confidence: 1)]
        let planner = SlotPlanner(workingHours: DailyHours(startMinute: 0, endMinute: 1440))
        let v = AgentResultValidator.validate(raw, package: p, plan: [item], calendar: [], planner: planner,
                                              nextPeriod: DateInterval(start: at(180), duration: 10800))
        XCTAssertEqual(v.result.planAssessment.count, 1)
        XCTAssertEqual(v.result.planAssessment[0].assessedStatus, "partial")
        XCTAssertFalse(v.validationNotes.isEmpty)
    }

    // 17. The rubric produces reproducible results for the same input.
    func testRubricIsReproducible() {
        let events = [ev(0, 50), ev(50, 55, app: chrome, title: "Stack Overflow"), ev(55, 120),
                      ev(120, 140, category: .socialMedia, app: chrome), ev(140, 180, category: .research, app: chrome)]
        let plan = [PlanItem(id: "a", title: "Ship tracker", expectedMinutes: 90, priority: 1, plannedStart: at(0),
                             status: .partial, categoryHint: .coding)]
        let weights = RubricWeights()
        let r1 = Rubric.evaluate(events: events, window: window, plan: plan, calendar: [], weights: weights)
        let r2 = Rubric.evaluate(events: events.shuffled(), window: window, plan: plan, calendar: [], weights: weights)
        XCTAssertEqual(r1, r2)
        XCTAssertNotNil(r1.score)
        XCTAssertFalse(r1.insufficientData)
        XCTAssertEqual(r1.components.reduce(0) { $0 + $1.effectiveWeight }, 1, accuracy: 1e-9)
        // Changing weights changes the score transparently.
        let r3 = Rubric.evaluate(events: events, window: window, plan: plan, calendar: [],
                                 weights: RubricWeights(priorityAlignment: 1, taskCompletion: 0, focusContinuity: 0, scheduleAdherence: 0))
        XCTAssertNotEqual(r1.score, r3.score)
    }

    func testFixedMeetingTimeIsExcludedFromScoring() {
        let meeting = CalendarEvent(id: "m", title: "Standup", start: at(0), end: at(60), hasAttendees: true)
        let r = Rubric.evaluate(events: [ev(0, 60, category: .communication, app: chrome), ev(60, 180)], window: window,
                                plan: [], calendar: [meeting], weights: RubricWeights())
        XCTAssertEqual(r.consideredMinutes, 120, accuracy: 0.1)
    }

    // 18. The next schedule respects fixed calendar commitments.
    func testScheduleRespectsFixedCommitments() {
        let utc = TimeZone(identifier: "UTC")!
        let planner = SlotPlanner(workingHours: DailyHours(startMinute: 0, endMinute: 1440), bufferMinutes: 10, timeZone: utc)
        let next = DateInterval(start: at(180), end: at(360))
        let meeting = CalendarEvent(id: "m1", title: "1:1 with Sam", start: at(240), end: at(270), hasAttendees: true)
        let free = planner.freeSlots(in: next, busy: [meeting])
        for f in free {
            XCTAssertFalse(f.intersects(DateInterval(start: at(230), end: at(280))) && f.intersection(with: DateInterval(start: at(230), end: at(280)))!.duration > 0)
        }
        let items = [PlanItem(title: "Deep work", expectedMinutes: 45, priority: 1),
                     PlanItem(title: "Email", expectedMinutes: 20, priority: 3),
                     PlanItem(title: "Huge task", expectedMinutes: 400, priority: 2)]
        let (blocks, unscheduled) = planner.pack(items, into: free)
        XCTAssertEqual(unscheduled.map(\.title), ["Huge task"], "never overfills")
        for b in blocks { XCTAssertNil(planner.validate(start: b.start, end: b.end, against: [meeting], requireWorkingHours: false)) }

        // A model suggestion overlapping the meeting is stripped by validation.
        var raw = MockProvider.sampleResult(corrections: [
            .init(action: "create_focus_block", title: "Focus", reason: "", planItemID: "", targetEventID: "",
                  start: iso(at(235)), end: iso(at(265))),
            .init(action: "move_event", title: "Move 1:1", reason: "", planItemID: "", targetEventID: "m1",
                  start: iso(at(300)), end: iso(at(330))),
        ])
        raw.nextPlan = [.init(planItemID: "", title: "Overlap", reason: "", estimatedMinutes: 30, deadline: "", priority: 1,
                              dependencies: [], suggestedStart: iso(at(250)), suggestedEnd: iso(at(280)), deferrable: true,
                              requiresApproval: true)]
        let p = build([ev(0, 180)], calendar: [meeting])
        let v = AgentResultValidator.validate(raw, package: p, plan: [], calendar: [meeting], planner: planner, nextPeriod: next)
        XCTAssertTrue(v.result.corrections.isEmpty, "both the overlapping block and the move of a shared meeting are dropped")
        XCTAssertEqual(v.result.nextPlan.first?.suggestedStart, "")
    }

    func testPackageRespectsTimelineBudget() {
        var events: [ActivityEvent] = []
        for i in 0..<180 { events.append(ev(Double(i), Double(i + 1), app: i % 2 == 0 ? xcode : chrome, title: "T\(i)")) }
        var w = AnalysisWindow(kind: .scheduled, start: at(0), end: at(180), status: .ready)
        w.id = "w"
        let rubric = Rubric.evaluate(events: events, window: window, plan: [], calendar: [], weights: RubricWeights())
        let p = PackageBuilder.build(window: w, events: events, plan: [], calendar: [], freeSlots: [],
                                     nextPeriod: DateInterval(start: at(180), duration: 60), rubric: rubric,
                                     options: PackageOptions(maxTimelineEntries: 20), now: at(180))
        XCTAssertEqual(p.timeline.count, 20)
        XCTAssertTrue(p.timelineTruncated)
    }

    func testSchemaIsStrict() throws {
        let schema = AgentResult.jsonSchema
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let data = try JSONSerialization.data(withJSONObject: schema)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        // Every field of AgentResult is required by the schema.
        let encoded = try JSONSerialization.jsonObject(with: AtlasJSON.encoder().encode(MockProvider.sampleResult())) as! [String: Any]
        XCTAssertEqual(Set(encoded.keys), Set(schema["required"] as! [String]))
    }
}
