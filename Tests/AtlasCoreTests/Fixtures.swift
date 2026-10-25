import Foundation
import XCTest
@testable import AtlasCore

/// Fixed epoch so every test is deterministic (2026-09-21 ~ 13:46 UTC).
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

let chrome = AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 100)
let xcode = AppInfo(bundleID: "com.apple.dt.Xcode", name: "Xcode", pid: 101)
let vscode = AppInfo(bundleID: "com.microsoft.VSCode", name: "Code", pid: 102)
let game = AppInfo(bundleID: "com.feralinteractive.tombraider", name: "Tomb Raider", pid: 103)
let steam = AppInfo(bundleID: "com.valvesoftware.steam", name: "Steam", pid: 104)
let preview = AppInfo(bundleID: "com.apple.Preview", name: "Preview", pid: 105)
let onePassword = AppInfo(bundleID: "com.1password.1password", name: "1Password", pid: 106)
let mystery = AppInfo(bundleID: "com.example.unknown", name: "Mystery", pid: 107)

func tab(_ url: String, _ title: String, audible: Bool = false, incognito: Bool = false) -> BrowserTabInfo {
    BrowserTabInfo(family: "chrome", url: url, title: title, incognito: incognito, audible: audible)
}

func makeSettings(_ mutate: (inout AtlasSettings) -> Void = { _ in }) -> AtlasSettings {
    var s = AtlasSettings()
    s.idleThresholdSeconds = 120
    s.passiveGraceSeconds = 900
    s.awayThresholdSeconds = 1800
    mutate(&s)
    return s
}

func makeEngine(_ mutate: (inout AtlasSettings) -> Void = { _ in }) -> ActivityStateEngine {
    ActivityStateEngine(policy: TrackingPolicy(settings: makeSettings(mutate)))
}

func ev(_ startMin: Double, _ endMin: Double, state: ActivityState = .active, category: ActivityCategory = .coding,
        confidence: Double = 0.8, app: AppInfo = xcode, privacy: PrivacyClass = .normal, title: String? = nil,
        raw: RawActivityType = .foregroundApp) -> ActivityEvent {
    ActivityEvent(start: at(startMin), end: at(endMin), appBundleID: app.bundleID, appName: app.name, windowTitle: title,
                  rawType: raw, state: state,
                  classification: Classification(category: category, confidence: confidence, evidence: [.appIdentity]),
                  privacy: privacy, timeZoneID: "UTC")
}

/// Asserts segments are contiguous, non-overlapping and cover exactly [from, to].
func assertTiles(_ events: [ActivityEvent], from: Date, to: Date, file: StaticString = #filePath, line: UInt = #line) {
    let s = events.sorted { $0.start < $1.start }
    XCTAssertEqual(s.first?.start, from, "first segment start", file: file, line: line)
    XCTAssertEqual(s.last?.end, to, "last segment end", file: file, line: line)
    for (a, b) in zip(s, s.dropFirst()) {
        XCTAssertEqual(a.end, b.start, "gap/overlap between \(a.displayLabel) and \(b.displayLabel)", file: file, line: line)
    }
    let total = s.reduce(0) { $0 + $1.duration }
    XCTAssertEqual(total, to.timeIntervalSince(from), accuracy: 0.001, file: file, line: line)
}

/// Mock model backend: counts calls, can fail, returns a fixed result.
actor MockProvider: AnalysisProvider {
    nonisolated let identifier = "mock"
    var calls = 0
    var failuresRemaining = 0
    var configured = true
    var result: AgentResult
    var lastRequest: AnalysisRequest?

    init(result: AgentResult = MockProvider.sampleResult()) { self.result = result }

    func setFailures(_ n: Int) { failuresRemaining = n }
    func setResult(_ r: AgentResult) { result = r }
    func isConfigured() async -> Bool { configured }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        calls += 1
        lastRequest = request
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ProviderError.retryable("simulated outage")
        }
        return AnalysisResponse(json: try AtlasJSON.string(result), model: "mock-model", inputTokens: 1000, outputTokens: 200)
    }

    static func sampleResult(corrections: [AgentResult.Correction] = []) -> AgentResult {
        AgentResult(summary: "Mostly coding.", chronology: [], allocationNotes: "", planAssessment: [], findings: [
            .init(kind: "context_switching", description: "Frequent switching", evidence: "12 switches", severity: "low"),
        ], assessment: .init(summary: "OK", caveats: ""), nextPlan: [], corrections: corrections,
        uncertainties: [], mostImportantUnfinishedTask: "Write report", reasoning: "")
    }
}

func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: d)
}
