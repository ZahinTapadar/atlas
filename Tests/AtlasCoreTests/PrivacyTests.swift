import XCTest
@testable import AtlasCore

final class PrivacyTests: XCTestCase {

    // 24. API credentials are not stored in source code or settings.
    func testNoCredentialsInSourceOrSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var scanned = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(text.range(of: #"sk-ant-[A-Za-z0-9_\-]{10,}"#, options: .regularExpression), url.lastPathComponent)
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 10)
        let settingsJSON = try AtlasJSON.string(AtlasSettings())
        XCTAssertFalse(settingsJSON.lowercased().contains("apikey"))
        XCTAssertFalse(settingsJSON.contains("sk-ant"))
    }

    func testApiKeyOnlyReadFromSecretStore() async {
        let secrets = InMemorySecretStore()
        let p = ClaudeProvider(secrets: secrets)
        let unconfigured = await p.isConfigured()
        XCTAssertFalse(unconfigured)
        try? secrets.write(ClaudeProvider.apiKeyAccount, value: "test-key")
        let configured = await p.isConfigured()
        XCTAssertTrue(configured)
    }

    // 25. Excluded activity is not transmitted to Claude.
    func testExcludedActivityIsNotTransmitted() async throws {
        let store = try AtlasStore.inMemory()
        var s = makeSettings { $0.excludedDomains = ["therapy-notes.com"]; $0.sensitiveDomains = ["mybank"] }
        s.authorizationLevel = .readOnly
        try await store.saveSettings(s)

        var engine = ActivityStateEngine(policy: TrackingPolicy(settings: s))
        var events: [ActivityEvent] = []
        engine.start(at: at(0), frontmost: chrome)
        events += engine.handle(.browserTab(tab("https://therapy-notes.com/session/42", "Session notes — Alex")), at: at(0))
        events += engine.handle(.browserTab(tab("https://www.mybank.com/accounts", "Checking ••4821")), at: at(40))
        events += engine.handle(.appActivated(onePassword), at: at(60))
        events += engine.handle(.appActivated(xcode), at: at(70))
        events += engine.handle(.windowTitle("ATLAS — main.swift", available: true), at: at(70))
        events += engine.stop(at: at(180))
        try await store.upsertEvents(events)

        let w = AnalysisWindow(kind: .scheduled, start: at(0), end: at(180), awakeSeconds: 10800, status: .ready)
        try await store.saveWindow(w)
        let provider = MockProvider()
        let c = AnalysisCoordinator(store: store, provider: provider, connectors: [], clock: { at(181) })
        _ = await c.process(windowID: w.id, userApproved: false)
        let sent = await provider.lastRequest!.userContent
        for forbidden in ["therapy-notes", "Session notes", "Alex", "1Password", "1password", "mybank", "4821", "Checking"] {
            XCTAssertFalse(sent.contains(forbidden), "leaked: \(forbidden)")
        }
        XCTAssertTrue(sent.contains("Xcode"), "ordinary activity is still analyzed")
        XCTAssertTrue(sent.contains("excluded"))
    }

    // 26. Sensitive details do not appear in ordinary diagnostic logs.
    func testLogRedaction() {
        let msg = #"Failed for https://mail.google.com/u/0/#inbox title "Re: biopsy results" user alex@example.com at /Users/alex/Docs on reddit.com"#
        let r = AtlasLog.redact(msg)
        for leak in ["mail.google.com", "biopsy", "alex@example.com", "/Users/alex", "reddit.com"] {
            XCTAssertFalse(r.contains(leak), leak)
        }
        XCTAssertTrue(r.contains("Failed for"))
    }

    // 27. Export and deletion behave as documented.
    func testExportAndDeletion() async throws {
        let store = try AtlasStore.inMemory()
        try await store.upsertEvents([ev(0, 10), ev(10, 20, app: chrome)])
        try await store.savePlanItem(PlanItem(title: "Task", expectedMinutes: 30))
        try await store.saveRule(ClassificationRule(field: .bundleID, pattern: "com.x", category: .coding, confidence: 0.9, source: .user))
        var s = AtlasSettings()
        s.analysisIntervalHours = 4
        try await store.saveSettings(s)

        let bundle = try await store.export()
        XCTAssertEqual(bundle.events.count, 2)
        XCTAssertEqual(bundle.planItems.count, 1)
        XCTAssertEqual(bundle.rules.count, 1)
        let json = try AtlasJSON.string(bundle, iso: true, pretty: true)
        let roundTrip = try AtlasJSON.decode(AtlasStore.ExportBundle.self, from: json, iso: true)
        XCTAssertEqual(roundTrip.events.map(\.id).sorted(), bundle.events.map(\.id).sorted())

        try await store.deleteAllData()
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        let plan = try await store.planItems(includeClosed: true)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(plan.isEmpty)
        let rules = try await store.rules()
        XCTAssertEqual(rules.count, 1, "configuration kept by default")
        let settings = try await store.loadSettings()
        XCTAssertEqual(settings.analysisIntervalHours, 4)

        try await store.deleteAllData(includeConfiguration: true)
        let rules2 = try await store.rules()
        XCTAssertTrue(rules2.isEmpty)
        let settings2 = try await store.loadSettings()
        XCTAssertEqual(settings2.analysisIntervalHours, 3)
    }

    func testRetentionPurge() async throws {
        let store = try AtlasStore.inMemory()
        try await store.upsertEvents([ev(-200 * 24 * 60, -200 * 24 * 60 + 10), ev(0, 10)])
        try await store.purge(olderThan: at(-90 * 24 * 60), requestLogCutoff: at(-30 * 24 * 60))
        let left = try await store.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(left.count, 1)
    }

    func testSettingsDecodeLenientlyAcrossVersions() {
        let old = #"{"analysisIntervalHours":4,"someRemovedKey":true}"#
        let s = AtlasSettings.decodeLenient(old)
        XCTAssertEqual(s.analysisIntervalHours, 4)
        XCTAssertEqual(s.idleThresholdSeconds, AtlasSettings().idleThresholdSeconds)
    }

    func testMigrationsAreIdempotentAndBackupWorks() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).sqlite").path
        _ = try AtlasStore(path: path)
        let reopened = try AtlasStore(path: path)
        let v = await reopened.schemaVersion
        XCTAssertEqual(v, Migrations.latestVersion)
        try await reopened.upsertEvents([ev(0, 1)])
        let backupURL = URL(fileURLWithPath: path + ".bak")
        try await reopened.backup(to: backupURL)
        let restored = try AtlasStore(path: backupURL.path)
        let n = try await restored.events(from: .distantPast, to: .distantFuture).count
        XCTAssertEqual(n, 1)
        let ok = await restored.integrityOK()
        XCTAssertTrue(ok)
    }

    func testOnlyOneOpenWindowCanExist() async throws {
        let store = try AtlasStore.inMemory()
        try await store.saveWindow(AwakeWindowManager.newWindow(at: at(0)))
        do {
            try await store.saveWindow(AwakeWindowManager.newWindow(at: at(1)))
            XCTFail("second open window must be rejected")
        } catch {}
    }
}
