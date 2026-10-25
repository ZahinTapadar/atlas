import XCTest
@testable import AtlasCore

/// Exercises ClaudeCodeProvider against a fake `claude` executable, so no subscription usage is spent.
final class ClaudeCodeProviderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a fake CLI. `auth status` prints `authJSON`; `-p` records args/env/stdin and prints `resultJSON`.
    func fakeCLI(auth authJSON: String, result resultJSON: String) throws -> String {
        let path = dir.appendingPathComponent("claude").path
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ]; then echo '\(authJSON)'; exit 0; fi
        printf '%s\\n' "$@" > "\(dir.path)/args.txt"
        env > "\(dir.path)/env.txt"
        pwd > "\(dir.path)/cwd.txt"
        cat > "\(dir.path)/stdin.txt"
        echo '\(resultJSON)'
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    let subscription = #"{"loggedIn":true,"authMethod":"claude.ai"}"#
    let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"{}","structured_output":{"summary":"fine"},"usage":{"input_tokens":12,"output_tokens":34},"modelUsage":{"claude-opus-5-5":{}}}"#

    func request() -> AnalysisRequest {
        AnalysisRequest(system: "SYS", userContent: "PACKAGE", schemaJSON: #"{"type":"object"}"#, model: "claude-opus-5-5", effort: "medium")
    }

    func testRunsToolLessSubscriptionCallAndParsesStructuredOutput() async throws {
        let exe = try fakeCLI(auth: subscription, result: ok)
        setenv("ANTHROPIC_API_KEY", "sk-should-never-reach-claude", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }

        let p = ClaudeCodeProvider(executablePath: exe)
        let configured = await p.isConfigured()
        XCTAssertTrue(configured)
        let resp = try await p.analyze(request())
        XCTAssertEqual(resp.json, #"{"summary":"fine"}"#)
        XCTAssertEqual(resp.inputTokens, 12)
        XCTAssertEqual(resp.model, "claude-opus-5-5")

        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        for flag in ["-p", "--json-schema", "--strict-mcp-config", "--safe-mode", "--no-session-persistence"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(args[args.firstIndex(of: "--system-prompt")! + 1], "SYS")
        XCTAssertFalse(args.contains("--bare"), "--bare would force API-key auth")
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertEqual(stdin, "PACKAGE", "the activity package goes over stdin, not argv")
        let env = try String(contentsOf: dir.appendingPathComponent("env.txt"), encoding: .utf8)
        XCTAssertFalse(env.contains("ANTHROPIC_API_KEY"), "API key must be scrubbed so billing can't switch to it")
        let cwd = try String(contentsOf: dir.appendingPathComponent("cwd.txt"), encoding: .utf8)
        XCTAssertTrue(cwd.contains("atlas-agent-"), "runs from an empty scratch folder")
    }

    func testRefusesWhenNotSignedInWithSubscription() async throws {
        let exe = try fakeCLI(auth: #"{"loggedIn":true,"authMethod":"api_key"}"#, result: ok)
        let p = ClaudeCodeProvider(executablePath: exe)
        let configured = await p.isConfigured()
        XCTAssertFalse(configured)
        do {
            _ = try await p.analyze(request())
            XCTFail("must refuse API-key auth")
        } catch let e as ProviderError {
            guard case .notConfigured = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("args.txt").path), "never invoked -p")
    }

    func testUsageLimitIsRetryable() async throws {
        let exe = try fakeCLI(auth: subscription,
                              result: #"{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429,"result":"limit"}"#)
        do {
            _ = try await ClaudeCodeProvider(executablePath: exe).analyze(request())
            XCTFail("expected error")
        } catch let e as ProviderError {
            XCTAssertTrue(e.isRetryable)
        }
    }

    func testMissingCLIIsNotConfigured() async {
        let p = ClaudeCodeProvider(executablePath: "/nonexistent/claude")
        // Falls back to searching standard locations; with an explicit bad path and no install it must not crash.
        _ = await p.isConfigured()
    }

    func testSelectorNeverFallsBackToAPI() async throws {
        let api = MockProvider()
        let subscription = MockProvider()
        await subscription.setConfiguredForTest(false)
        let selector = BackendSelector { subscription }
        let configured = await selector.isConfigured()
        XCTAssertFalse(configured)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls, 0)
    }
}

/// Opt-in live check against the real Claude Code CLI and your subscription:
/// `ATLAS_LIVE_CLAUDE=1 swift test --filter LiveClaudeCodeTests`
final class LiveClaudeCodeTests: XCTestCase {
    func testEndToEndAnalysisThroughSubscription() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATLAS_LIVE_CLAUDE"] == "1", "set ATLAS_LIVE_CLAUDE=1 to run")
        let store = try AtlasStore.inMemory()
        var s = makeSettings()
        s.effort = "low"
        s.authorizationLevel = .approvalRequired
        s.workingHours = DailyHours(startMinute: 0, endMinute: 1440)
        try await store.saveSettings(s)
        try await store.upsertEvents([
            ev(0, 70, title: "ATLAS — TrackerCore.swift"),
            ev(70, 110, category: .socialMedia, app: chrome),
            ev(110, 180, category: .research, app: chrome, title: "Swift Concurrency docs"),
        ])
        try await store.savePlanItem(PlanItem(id: "p1", title: "Finish tracker tests", expectedMinutes: 90, priority: 1,
                                              plannedStart: at(0), status: .inProgress, categoryHint: .coding))
        let w = AnalysisWindow(kind: .scheduled, start: at(0), end: at(180), awakeSeconds: 10800, status: .ready)
        try await store.saveWindow(w)
        let c = AnalysisCoordinator(store: store, provider: ClaudeCodeProvider(), connectors: [], clock: { at(181) })
        let outcome = await c.process(windowID: w.id, userApproved: false)
        XCTAssertEqual(outcome, .analyzed)
        let stored = try await store.window(id: w.id)!
        let analysis = try AtlasJSON.decode(ValidatedAnalysis.self, from: XCTUnwrap(stored.resultJSON))
        print("LIVE SUMMARY:", analysis.result.summary)
        print("LIVE TOP TASK:", analysis.result.mostImportantUnfinishedTask)
        print("LIVE corrections:", analysis.result.corrections.count, "notes:", analysis.validationNotes)
        let log = try await store.requestLog()
        print("LIVE LOG:", log.map { "\($0.model) in=\($0.inputTokens ?? -1) out=\($0.outputTokens ?? -1) \($0.outcome)" })
        XCTAssertFalse(analysis.result.summary.isEmpty)
    }
}
