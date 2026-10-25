import XCTest
@testable import AtlasCore

final class ClassificationFixTests: XCTestCase {
    let c = Classifier()

    func classify(_ bundle: String, _ name: String, declared: String? = nil, path: String? = nil, title: String? = nil) -> Classification {
        c.classify(ClassificationInput(bundleID: bundle, appName: name, windowTitle: title, domain: nil, pageTitle: nil,
                                       state: .active, declaredCategory: declared, bundlePath: path))
    }

    func testSteamInstalledGamesAreGaming() {
        XCTAssertEqual(classify("com.cdprojektred.cyberpunk.steam", "Cyberpunk 2077: Ultimate").category, .gaming)
        XCTAssertEqual(classify("com.example.indie", "Indie", path: "/Users/u/Library/Application Support/Steam/steamapps/common/Indie/Indie.app").category, .gaming)
        XCTAssertEqual(classify("com.example.thing", "Thing", declared: "public.app-category.role-playing-games").category, .gaming)
    }

    func testSteamClientIsLauncherNotGameplay() {
        let helper = classify("com.valvesoftware.steam.helper", "Steam Helper")
        XCTAssertEqual(helper.category, .gaming)
        XCTAssertLessThan(helper.confidence, 0.6, "store/library browsing is weaker evidence than playing")
    }

    func testChromeWebAppsClassifyAsTheirSite() {
        XCTAssertEqual(classify("com.google.Chrome.app.lodlkdfmihgonocnmddehnfgiljnadcf", "X").category, .socialMedia)
        XCTAssertEqual(classify("com.google.Chrome.app.lgnggepjiihbfdbedefdhcffnmhcahbm", "Reddit").category, .socialMedia)
        XCTAssertEqual(classify("com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml", "YouTube",
                                title: "MIT 6.006 Lecture 1 - YouTube").category, .educationalVideo)
    }

    func testBrowserWindowTitleIdentifiesSiteWithoutTabData() {
        XCTAssertEqual(classify("com.google.Chrome", "Google Chrome", title: "(1) Home / X - Google Chrome").category, .socialMedia)
        XCTAssertEqual(classify("com.google.Chrome", "Google Chrome", title: "Inbox (3) - Gmail - Google Chrome").category, .communication)
        XCTAssertEqual(classify("com.google.Chrome", "Google Chrome", title: "Raycast - Your shortcut to everything - Google Chrome").category, .unknown)
    }

    func testDeclaredCategoryAndKnownApps() {
        XCTAssertEqual(classify("com.example.ide", "IDE", declared: "public.app-category.developer-tools").category, .coding)
        XCTAssertEqual(classify("com.anthropic.claudefordesktop", "Claude").category, .research)
        XCTAssertEqual(classify("com.atlas.tracker", "ATLAS").category, .administrative)
        XCTAssertEqual(classify("com.apple.UserNotificationCenter", "UserNotificationCenter").category, .administrative)
    }

    func testReclassifyFixesStoredHistoryButKeepsCorrections() async throws {
        let store = try AtlasStore.inMemory()
        let game = ActivityEvent(start: at(0), end: at(60), appBundleID: "com.cdprojektred.cyberpunk.steam", appName: "Cyberpunk",
                                 rawType: .foregroundApp, state: .active, classification: .unknown)
        var corrected = ActivityEvent(start: at(60), end: at(70), appBundleID: "com.cdprojektred.cyberpunk.steam", appName: "Cyberpunk",
                                      rawType: .foregroundApp, state: .active)
        corrected.classification = Classification(category: .breakTime, confidence: 1, evidence: [.userCorrection], origin: .userConfirmed)
        try await store.upsertEvents([game, corrected])
        let tracker = TrackerCore(store: store, settings: makeSettings(), rules: [])
        let n = try await tracker.reclassify(from: at(0), to: at(70))
        XCTAssertEqual(n, 1)
        let after = try await store.events(from: at(0), to: at(70))
        XCTAssertEqual(after[0].classification.category, .gaming)
        XCTAssertEqual(after[1].classification.category, .breakTime, "user corrections are never overwritten")
    }
}

final class DigestTests: XCTestCase {
    func testRangeParsing() {
        let now = at(600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let (f, t) = DigestRange.parse(from: "-3h", to: nil, now: now, calendar: cal)!
        XCTAssertEqual(f, now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(t, now)
        let (f2, _) = DigestRange.parse(from: "last_90m", to: "now", now: now, calendar: cal)!
        XCTAssertEqual(f2, now.addingTimeInterval(-90 * 60))
        XCTAssertNotNil(DigestRange.parse(from: iso(at(0)), to: iso(at(60)), now: now, calendar: cal))
        XCTAssertNil(DigestRange.parse(from: "now", to: "-1h", now: now, calendar: cal))
    }

    func testDigestNeverExposesExcludedOrSensitive() {
        let events = [
            ev(0, 30, app: xcode, title: "ATLAS — main.swift"),
            ActivityEvent(start: at(30), end: at(40), rawType: .foregroundApp, state: .active, privacy: .excluded),
            ActivityEvent(start: at(40), end: at(50), appBundleID: chrome.bundleID, appName: chrome.name,
                          browser: BrowserContext(browser: "Chrome", domain: "mybank.com", title: "Balance 4821"),
                          rawType: .browserTab, state: .active, privacy: .sensitive),
        ]
        let d = ActivityDigest.build(events: events, from: at(0), to: at(50), now: at(50), includeTimeline: true, sendTitles: true)
        let text = (try? AtlasJSON.string(d)) ?? ""
        XCTAssertFalse(text.contains("4821"))
        XCTAssertFalse(text.contains("mybank"))
        XCTAssertTrue(text.contains("ATLAS — main.swift"))
        XCTAssertEqual(d.engagedMinutes, 50, accuracy: 0.1)
        XCTAssertTrue(d.markdown.contains("coding"))
    }

    func testCheckinsRoundTrip() async throws {
        let store = try AtlasStore.inMemory()
        try await store.saveCheckin(.init(source: "scheduled-checkin", verdict: "mixed", body: "Two hours of gaming before the deadline."))
        let list = try await store.checkins()
        XCTAssertEqual(list.first?.verdict, "mixed")
        try await store.deleteAllData()
        let empty = try await store.checkins()
        XCTAssertTrue(empty.isEmpty)
    }

    func testReadOnlyStoreCannotWrite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString).sqlite").path
        let rw = try AtlasStore(path: path)
        try await rw.upsertEvents([ev(0, 1)])
        let ro = try AtlasStore(path: path, readOnly: true)
        let n = try await ro.events(from: .distantPast, to: .distantFuture).count
        XCTAssertEqual(n, 1)
        do { try await ro.upsertEvents([ev(1, 2)]); XCTFail("read-only store wrote") } catch {}
    }
}
