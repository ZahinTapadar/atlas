import XCTest
@testable import AtlasCore

final class WindowTests: XCTestCase {
    let policy = WindowPolicy(interval: 3 * 3600, dayBreak: 4 * 3600, minimumPartial: 20 * 60)

    // 9. Three hours of accumulated awake time triggers an analysis window.
    func testThreeAwakeHoursTriggersWindow() {
        let w = AwakeWindowManager.newWindow(at: at(0))
        let events = [ev(0, 100), ev(100, 130, state: .idle, category: .idle), ev(130, 200, app: chrome)]
        let r = AwakeWindowManager.accrue(window: w, events: events, through: at(200), policy: policy)
        XCTAssertEqual(r.closed.count, 1)
        XCTAssertEqual(r.closed[0].status, .ready)
        XCTAssertEqual(r.closed[0].end, at(180), "boundary falls exactly at 180 awake minutes")
        XCTAssertEqual(r.open.start, at(180), "next window starts where the previous ended")
        XCTAssertEqual(r.open.awakeSeconds, 20 * 60, accuracy: 0.001)
    }

    func testNotReadyBeforeThreshold() {
        let w = AwakeWindowManager.newWindow(at: at(0))
        let r = AwakeWindowManager.accrue(window: w, events: [ev(0, 179)], through: at(179), policy: policy)
        XCTAssertTrue(r.closed.isEmpty)
        XCTAssertEqual(r.open.awakeSeconds, 179 * 60, accuracy: 0.001)
    }

    // 10. System sleep does not advance the awake-time counter.
    func testSleepDoesNotAdvanceAwakeTime() {
        let w = AwakeWindowManager.newWindow(at: at(0))
        let events = [ev(0, 60), ev(60, 180, state: .systemSleep, category: .idle, raw: .systemSleep), ev(180, 240)]
        let r = AwakeWindowManager.accrue(window: w, events: events, through: at(240), policy: policy)
        XCTAssertTrue(r.closed.isEmpty, "only 2 awake hours elapsed")
        XCTAssertEqual(r.open.awakeSeconds, 120 * 60, accuracy: 0.001)
    }

    func testIncrementalAccrualMatchesOneShot() {
        let events = [ev(0, 50), ev(50, 70, state: .locked, category: .idle, raw: .locked), ev(70, 250, app: chrome)]
        var w = AwakeWindowManager.newWindow(at: at(0))
        var closed: [AnalysisWindow] = []
        for m in stride(from: 5.0, through: 250, by: 7.5) {
            let r = AwakeWindowManager.accrue(window: w, events: events, through: at(m), policy: policy)
            closed += r.closed
            w = r.open
        }
        let r = AwakeWindowManager.accrue(window: w, events: events, through: at(250), policy: policy)
        closed += r.closed
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].end, at(200))
    }

    func testLongSleepClosesPartialWindowAndTilesTimeline() {
        let w = AwakeWindowManager.newWindow(at: at(0))
        let events = [ev(0, 90), ev(90, 90 + 8 * 60, state: .systemSleep, category: .idle, raw: .systemSleep),
                      ev(570, 600)]
        let r = AwakeWindowManager.accrue(window: w, events: events, through: at(600), policy: policy)
        XCTAssertEqual(r.closed.count, 1)
        XCTAssertEqual(r.closed[0].kind, .partial)
        XCTAssertEqual(r.closed[0].status, .ready)
        XCTAssertEqual(r.closed[0].end, at(90))
        XCTAssertEqual(r.open.start, at(90), "windows tile: next starts at previous end")
        XCTAssertEqual(r.open.awakeSeconds, 30 * 60, accuracy: 0.001)
    }

    func testTinyPartialIsSkipped() {
        let w = AwakeWindowManager.newWindow(at: at(0))
        let events = [ev(0, 5), ev(5, 5 + 6 * 60, state: .systemSleep, category: .idle, raw: .systemSleep)]
        let r = AwakeWindowManager.accrue(window: w, events: events, through: at(5 + 6 * 60), policy: policy)
        XCTAssertEqual(r.closed.first?.status, .skipped)
    }

    func testLongIdleIsNotSleepButAwayStillEndsDay() {
        // Idle (not away) keeps counting as awake: someone may be reading at the desk.
        let w = AwakeWindowManager.newWindow(at: at(0))
        let r = AwakeWindowManager.accrue(window: w, events: [ev(0, 60), ev(60, 100, state: .idle, category: .idle)],
                                          through: at(100), policy: policy)
        XCTAssertEqual(r.open.awakeSeconds, 100 * 60, accuracy: 0.001)
    }

    func testDSTTransitionUsesElapsedTime() {
        // 2026-11-01 01:30 America/New_York is ambiguous; windows depend only on elapsed seconds.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 0))!
        let w = AwakeWindowManager.newWindow(at: start)
        let e = ActivityEvent(start: start, end: start.addingTimeInterval(4 * 3600), rawType: .foregroundApp, state: .active)
        let r = AwakeWindowManager.accrue(window: w, events: [e], through: start.addingTimeInterval(4 * 3600), policy: policy)
        XCTAssertEqual(r.closed.first?.end, start.addingTimeInterval(3 * 3600))
    }

    // 11. Partial windows survive application restarts.
    func testPartialWindowSurvivesRestart() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-\(UUID().uuidString).sqlite").path
        var settings = makeSettings()
        settings.analysisIntervalHours = 3

        do {
            let store = try AtlasStore(path: path)
            let tracker = TrackerCore(store: store, settings: settings, rules: [])
            try await tracker.start(at: at(0), frontmost: xcode)
            try await tracker.tick(now: at(60))
            try await tracker.tick(now: at(100))
            await tracker.stop(at: at(100))
        }
        // "Restart": new store and tracker on the same file. ATLAS was quit for 2 minutes.
        let store = try AtlasStore(path: path)
        let open = try await store.openWindow()
        XCTAssertEqual(open?.awakeSeconds ?? 0, 100 * 60, accuracy: 1)
        let tracker = TrackerCore(store: store, settings: settings, rules: [])
        try await tracker.start(at: at(102), frontmost: xcode)
        let ready = try await tracker.tick(now: at(190))
        XCTAssertEqual(ready.count, 1)
        // 2-minute gap is "uncertain" (counted), so the boundary lands at 180.
        XCTAssertEqual(ready.first?.end, at(180))
        XCTAssertEqual(ready.first?.start, at(0))
        let windows = try await store.recentWindows()
        XCTAssertEqual(windows.filter { $0.status == .open }.count, 1)
        let gaps = try await store.events(from: at(0), to: at(190)).filter { $0.rawType == .gap }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.stateNote, "ATLAS was quit")
    }

    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(AwakeWindowManager.backoff(attempt: 1, base: 60, jitter: 0), 60)
        XCTAssertEqual(AwakeWindowManager.backoff(attempt: 4, base: 60, jitter: 0), 480)
        XCTAssertEqual(AwakeWindowManager.backoff(attempt: 30, base: 60, jitter: 0), 6 * 3600)
    }
}
