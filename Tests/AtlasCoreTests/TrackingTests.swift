import XCTest
@testable import AtlasCore

final class TrackingTests: XCTestCase {

    // 1. Switching from a browser to an IDE produces correctly timestamped events.
    func testBrowserToIDESwitchTimestamps() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: chrome)
        out += e.handle(.browserTab(tab("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer")), at: at(0))
        out += e.handle(.appActivated(xcode), at: at(25))
        out += e.handle(.windowTitle("ATLAS — TrackerCore.swift", available: true), at: at(25))
        out += e.stop(at: at(60))

        assertTiles(out, from: at(0), to: at(60))
        let browser = out.filter { $0.appBundleID == "com.google.Chrome" }
        XCTAssertEqual(browser.reduce(0) { $0 + $1.duration }, 25 * 60, accuracy: 0.001)
        XCTAssertEqual(browser.last?.browser?.domain, "developer.apple.com")
        XCTAssertEqual(browser.last?.classification.category, .research)
        let ide = out.filter { $0.appBundleID == "com.apple.dt.Xcode" }
        XCTAssertEqual(ide.first?.start, at(25))
        XCTAssertEqual(ide.last?.end, at(60))
        XCTAssertEqual(ide.last?.classification.category, .coding)
    }

    // 2. Switching between windows does not double-count time.
    func testRapidWindowSwitchingDoesNotDoubleCount() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: xcode)
        for i in 0..<40 {
            out += e.handle(.appActivated(i % 2 == 0 ? chrome : xcode), at: at(Double(i) * 0.5 + 0.25))
            out += e.handle(.windowTitle("Window \(i)", available: true), at: at(Double(i) * 0.5 + 0.3))
        }
        out += e.stop(at: at(30))
        assertTiles(out, from: at(0), to: at(30))
        let totals = TimeAccounting.totals(TimeAccounting.normalized(out, from: at(0), to: at(30)))
        let sum = totals.values.reduce(0) { $0 + $1.observed }
        XCTAssertLessThanOrEqual(sum, 30 * 60 + 0.001)
    }

    // 3. A game running in the background is not classified as active gaming.
    func testBackgroundGameIsNotActiveGaming() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: game)
        out += e.handle(.appActivated(xcode), at: at(10))   // game keeps running in background
        out += e.stop(at: at(70))
        let gaming = out.filter { $0.classification.category == .gaming && $0.state == .active }
        XCTAssertEqual(gaming.reduce(0) { $0 + $1.duration }, 10 * 60, accuracy: 0.001, "only foreground time counts")

        // Foreground but untouched: passive, then idle — never active gaming for the whole period.
        var e2 = makeEngine()
        var out2: [ActivityEvent] = []
        e2.start(at: at(0), frontmost: game)
        out2 += e2.handle(.inputIdle(lastInput: at(5)), at: at(7))
        out2 += e2.advance(to: at(60))
        out2 += e2.stop(at: at(60))
        assertTiles(out2, from: at(0), to: at(60))
        let activeGaming = out2.filter { $0.state == .active && $0.classification.category == .gaming }
        XCTAssertEqual(activeGaming.reduce(0) { $0 + $1.duration }, 5 * 60, accuracy: 0.001)
        XCTAssertTrue(out2.contains { $0.state == .away })
    }

    // 4. An idle period is not automatically classified as sleep.
    func testIdleIsNotSleep() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: xcode)
        out += e.handle(.inputIdle(lastInput: at(10)), at: at(12))
        out += e.advance(to: at(300))  // 5 hours of no input, no sleep event
        out += e.stop(at: at(300))
        assertTiles(out, from: at(0), to: at(300))
        XCTAssertFalse(out.contains { $0.state == .systemSleep }, "idle must never become sleep")
        XCTAssertTrue(out.contains { $0.state == .idle })
        XCTAssertTrue(out.contains { $0.state == .away })
        // Idle started retroactively at the last input, not when it was detected.
        XCTAssertEqual(out.first { $0.state == .idle }?.start, at(10))
    }

    // Reading a PDF without touching the keyboard is passive engagement, not idle.
    func testReadingWithoutInputIsPassive() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: preview)
        out += e.handle(.windowTitle("Designing Data-Intensive Applications.pdf", available: true), at: at(0))
        out += e.handle(.inputIdle(lastInput: at(3)), at: at(5))
        out += e.handle(.inputResumed, at: at(10))
        out += e.stop(at: at(15))
        let passive = out.filter { $0.state == .passive }
        XCTAssertEqual(passive.reduce(0) { $0 + $1.duration }, 7 * 60, accuracy: 0.001)
        XCTAssertEqual(passive.first?.classification.category, .reading)
    }

    // 5. Sleep and wake events are handled correctly.
    func testSleepAndWake() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: vscode)
        out += e.handle(.systemWillSleep, at: at(30))
        out += e.handle(.appActivated(chrome), at: at(40)) // spurious while asleep: ignored
        out += e.handle(.systemDidWake, at: at(120))
        out += e.stop(at: at(150))
        assertTiles(out, from: at(0), to: at(150))
        let sleep = out.filter { $0.state == .systemSleep }
        XCTAssertEqual(sleep.count, 1)
        XCTAssertEqual(sleep.first?.start, at(30))
        XCTAssertEqual(sleep.first?.end, at(120))
        XCTAssertEqual(out.last?.state, .active)
    }

    // 6. An inaccessible application produces an explicit uncertainty state.
    func testInaccessibleAppIsExplicitlyUncertain() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: mystery)
        out += e.handle(.windowTitle(nil, available: false), at: at(0))
        out += e.handle(.appActivated(chrome), at: at(10)) // browser, no extension data
        out += e.stop(at: at(20))
        let m = out.first { $0.appBundleID == mystery.bundleID }!
        XCTAssertNotNil(m.stateNote)
        XCTAssertTrue(m.classification.isUncertain)
        let c = out.first { $0.appBundleID == chrome.bundleID }!
        XCTAssertEqual(c.classification.category, .unknown)
        XCTAssertTrue(c.classification.isUncertain)
        XCTAssertEqual(c.stateNote, "Browser tab data unavailable")
    }

    // 7. Browser tracking failure does not crash the main tracker.
    func testMalformedBrowserDataIsIgnored() throws {
        let garbage = ["", "not json", "{\"v\":1}", "{\"v\":2,\"type\":\"tab\",\"ts\":1,\"family\":\"chrome\"}",
                       String(repeating: "x", count: 20_000), "{\"v\":1,\"type\":\"tab\",\"ts\":-5,\"family\":\"chrome\"}"]
        for g in garbage { XCTAssertNil(BrowserInbox.parse(line: g)) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = #"{"v":1,"type":"tab","ts":1790000000,"family":"chrome","url":"https://youtube.com/watch?v=1","title":"MIT 6.006 Lecture 1"}"#
        try (garbage + [good]).joined(separator: "\n").write(to: dir.appendingPathComponent("1.jsonl"), atomically: true, encoding: .utf8)
        let msgs = BrowserInbox.drain(directory: dir)
        XCTAssertEqual(msgs.count, 1)

        // A tab with no URL/title is accepted without crashing and just yields low confidence.
        var e = makeEngine()
        e.start(at: at(0), frontmost: chrome)
        _ = e.handle(.browserTab(BrowserTabInfo(family: "chrome", url: nil, title: nil)), at: at(1))
        let out = e.stop(at: at(5))
        XCTAssertEqual(out.last?.classification.category, .unknown)
    }

    // 8. Application exclusions prevent excluded metadata from being collected.
    func testExclusionsStripMetadata() {
        var e = makeEngine { $0.excludedDomains = ["secret-bank.com"] }
        var out: [ActivityEvent] = []
        e.start(at: at(0), frontmost: onePassword)
        out += e.handle(.windowTitle("Vault — Personal", available: true), at: at(0))
        out += e.handle(.appActivated(chrome), at: at(5))
        out += e.handle(.browserTab(tab("https://login.secret-bank.com/acct", "Account 1234")), at: at(5))
        out += e.handle(.browserTab(tab("https://example.org/private", "Private", incognito: true)), at: at(8))
        out += e.stop(at: at(10))
        assertTiles(out, from: at(0), to: at(10))
        for x in out {
            XCTAssertEqual(x.privacy, .excluded, "\(x.displayLabel)")
            XCTAssertNil(x.appName)
            XCTAssertNil(x.appBundleID)
            XCTAssertNil(x.windowTitle)
            XCTAssertNil(x.browser)
        }
    }

    func testClockMovingBackwardsNeverProducesNegativeTime() {
        var e = makeEngine()
        var out: [ActivityEvent] = []
        e.start(at: at(10), frontmost: xcode)
        out += e.handle(.appActivated(chrome), at: at(5)) // clock stepped back
        out += e.stop(at: at(20))
        XCTAssertTrue(out.allSatisfy { $0.end >= $0.start })
        assertTiles(out, from: at(10), to: at(20))
    }

    func testYouTubeClassificationDependsOnTitle() {
        let c = Classifier()
        let lecture = c.classify(.init(bundleID: "com.google.chrome", appName: nil, windowTitle: nil, domain: "youtube.com",
                                       pageTitle: "MIT 6.006 Lecture 3: Sorting", state: .active))
        XCTAssertEqual(lecture.category, .educationalVideo)
        let noTitle = c.classify(.init(bundleID: nil, appName: nil, windowTitle: nil, domain: "youtube.com", pageTitle: nil, state: .active))
        XCTAssertTrue(noTitle.isUncertain)
    }

    func testCorrectionsBecomeRules() {
        let e = ActivityEvent(start: at(0), end: at(10), appBundleID: chrome.bundleID, appName: chrome.name,
                              browser: BrowserContext(browser: "Chrome", domain: "reddit.com", title: "r/swift"),
                              rawType: .browserTab, state: .active)
        let rule = CorrectionLearner.rule(for: e, category: .research, scope: .appOrSite)!
        let c = Classifier(userRules: [rule])
        let r = c.classify(.init(bundleID: "com.google.chrome", appName: nil, windowTitle: nil, domain: "old.reddit.com",
                                 pageTitle: "anything", state: .active))
        XCTAssertEqual(r.category, .research)
        XCTAssertEqual(r.origin, .userConfirmed)
    }

    func testSessionsSplitOnBreaks() {
        let events = [ev(0, 30), ev(30, 32, state: .idle, category: .idle), ev(32, 60, app: chrome),
                      ev(60, 80, state: .idle, category: .idle), ev(80, 100)]
        let (sessions, assignments) = SessionBuilder.build(events)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].contextSwitches, 1)
        XCTAssertEqual(sessions[0].activeSeconds, 58 * 60, accuracy: 0.001)
        XCTAssertNil(assignments[events[3].id], "a 20-minute break belongs to no session")
    }
}
