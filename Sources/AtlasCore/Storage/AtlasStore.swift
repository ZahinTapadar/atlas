import Foundation

/// The single owner of the SQLite database. All reads and writes go through this actor,
/// so writes are serialized and every multi-row change is transactional.
public actor AtlasStore {
    private let db: SQLiteConnection
    public nonisolated let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        if readOnly {
            // External readers (atlas CLI / MCP) never migrate or write.
            db = try SQLiteConnection(path: path, readOnly: true)
            return
        }
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        db = try SQLiteConnection(path: path)
        try Migrations.migrate(db)
    }

    public static var defaultPath: String { defaultDirectory.appendingPathComponent("atlas.sqlite").path }

    public static func inMemory() throws -> AtlasStore { try AtlasStore(path: ":memory:") }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS", isDirectory: true)
    }

    public var schemaVersion: Int { db.userVersion }
    public func integrityOK() -> Bool { db.integrityCheck() }

    // MARK: - Events

    private static let eventColumns = """
        id, start_ts, end_ts, app_bundle_id, app_name, pid, window_title, browser_json, raw_type, state,
        category, confidence, evidence, explanation, origin, session_id, privacy, tz, state_note
        """

    private func eventParams(_ e: ActivityEvent) throws -> [SQLBindable] {
        let browserJSON = try e.browser.map { try AtlasJSON.string($0) }
        return [e.id, e.start, e.end, e.appBundleID, e.appName, e.pid.map(Int.init), e.windowTitle, browserJSON,
                e.rawType.rawValue, e.state.rawValue, e.classification.category.rawValue,
                e.classification.confidence, e.classification.evidence.map(\.rawValue).joined(separator: ","),
                e.classification.explanation, e.classification.origin.rawValue, e.sessionID,
                e.privacy.rawValue, e.timeZoneID, e.stateNote]
    }

    private func mapEvent(_ r: Row) -> ActivityEvent {
        let evidence = (r.string("evidence") ?? "").split(separator: ",").compactMap { EvidenceSource(rawValue: String($0)) }
        let cls = Classification(category: ActivityCategory(rawValue: r.string("category") ?? "") ?? .unknown,
                                 confidence: r.double("confidence") ?? 0, evidence: evidence,
                                 explanation: r.string("explanation"),
                                 origin: ClassificationOrigin(rawValue: r.string("origin") ?? "") ?? .inferred)
        return ActivityEvent(id: r.string("id")!, start: r.date("start_ts")!, end: r.date("end_ts")!,
                             appBundleID: r.string("app_bundle_id"), appName: r.string("app_name"),
                             pid: r.int("pid").map(Int32.init), windowTitle: r.string("window_title"),
                             browser: r.string("browser_json").flatMap { try? AtlasJSON.decode(BrowserContext.self, from: $0) },
                             rawType: RawActivityType(rawValue: r.string("raw_type") ?? "") ?? .gap,
                             state: ActivityState(rawValue: r.string("state") ?? "") ?? .uncertain,
                             classification: cls, sessionID: r.string("session_id"),
                             privacy: PrivacyClass(rawValue: r.string("privacy") ?? "") ?? .normal,
                             timeZoneID: r.string("tz") ?? TimeZone.current.identifier,
                             stateNote: r.string("state_note"))
    }

    /// Batched, transactional upsert. Re-inserting the same id replaces it (idempotent).
    public func upsertEvents(_ events: [ActivityEvent]) throws {
        guard !events.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: 19).joined(separator: ",")
        try db.transaction {
            for e in events {
                try db.run("INSERT OR REPLACE INTO activity_event (\(Self.eventColumns)) VALUES (\(placeholders))",
                           try eventParams(e))
            }
        }
    }

    /// Events overlapping [from, to), ordered by start.
    public func events(from: Date, to: Date) throws -> [ActivityEvent] {
        try db.query("SELECT * FROM activity_event WHERE end_ts > ? AND start_ts < ? ORDER BY start_ts, end_ts",
                     [from, to], map: mapEvent)
    }

    public func events(ids: [String]) throws -> [ActivityEvent] {
        guard !ids.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try db.query("SELECT * FROM activity_event WHERE id IN (\(ph)) ORDER BY start_ts", ids, map: mapEvent)
    }

    public func event(id: String) throws -> ActivityEvent? { try events(ids: [id]).first }

    public func latestEventEnd() throws -> Date? {
        try db.query("SELECT MAX(end_ts) AS m FROM activity_event") { $0.date("m") }.first ?? nil
    }

    public func deleteEvents(ids: [String]) throws {
        try db.transaction {
            for id in ids { try db.run("DELETE FROM activity_event WHERE id = ?", id) }
        }
    }

    /// Split one event at `at` into two contiguous events. Total time is preserved exactly.
    @discardableResult
    public func splitEvent(id: String, at: Date) throws -> (ActivityEvent, ActivityEvent)? {
        guard let e = try event(id: id), at > e.start, at < e.end else { return nil }
        var first = e, second = e
        first.end = at
        second.id = UUID().uuidString
        second.start = at
        try upsertEvents([first, second])
        return (first, second)
    }

    /// Merge adjacent events into the first, applying `classification` to the result.
    @discardableResult
    public func mergeEvents(ids: [String], classification: Classification) throws -> ActivityEvent? {
        let evs = try events(ids: ids).sorted { $0.start < $1.start }
        guard var merged = evs.first, evs.count > 1 else { return nil }
        merged.end = evs.map(\.end).max()!
        merged.classification = classification
        try db.transaction {
            for e in evs.dropFirst() { try db.run("DELETE FROM activity_event WHERE id = ?", e.id) }
            try db.run("INSERT OR REPLACE INTO activity_event (\(Self.eventColumns)) VALUES (\(Array(repeating: "?", count: 19).joined(separator: ",")))",
                       try eventParams(merged))
        }
        return merged
    }

    // MARK: - Sessions

    public func replaceSessions(from: Date, to: Date, sessions: [ActivitySession], assignments: [String: String]) throws {
        try db.transaction {
            try db.run("DELETE FROM activity_session WHERE start_ts >= ? AND start_ts < ?", from, to)
            for s in sessions {
                try db.run("""
                    INSERT OR REPLACE INTO activity_session
                    (id, start_ts, end_ts, primary_category, active_seconds, idle_seconds, context_switches, event_count, summary)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """, s.id, s.start, s.end, s.primaryCategory.rawValue, s.activeSeconds, s.idleSeconds,
                           s.contextSwitches, s.eventCount, s.summary)
            }
            for (eventID, sessionID) in assignments {
                try db.run("UPDATE activity_event SET session_id = ? WHERE id = ?", sessionID, eventID)
            }
        }
    }

    public func sessions(from: Date, to: Date) throws -> [ActivitySession] {
        try db.query("SELECT * FROM activity_session WHERE end_ts > ? AND start_ts < ? ORDER BY start_ts", [from, to]) { r in
            ActivitySession(id: r.string("id")!, start: r.date("start_ts")!, end: r.date("end_ts")!,
                            primaryCategory: ActivityCategory(rawValue: r.string("primary_category") ?? "") ?? .unknown,
                            activeSeconds: r.double("active_seconds") ?? 0, idleSeconds: r.double("idle_seconds") ?? 0,
                            contextSwitches: r.int("context_switches") ?? 0, eventCount: r.int("event_count") ?? 0,
                            summary: r.string("summary"))
        }
    }

    // MARK: - Analysis windows

    private func mapWindow(_ r: Row) -> AnalysisWindow {
        AnalysisWindow(id: r.string("id")!, kind: WindowKind(rawValue: r.string("kind") ?? "") ?? .scheduled,
                       start: r.date("start_ts")!, end: r.date("end_ts"), awakeSeconds: r.double("awake_seconds") ?? 0,
                       accruedThrough: r.date("accrued_through"),
                       status: WindowStatus(rawValue: r.string("status") ?? "") ?? .failed,
                       attempts: r.int("attempts") ?? 0, nextAttemptAt: r.date("next_attempt_at"),
                       lastError: r.string("last_error"), idempotencyKey: r.string("idempotency_key"),
                       eventIDs: (try? AtlasJSON.decode([String].self, from: r.string("event_ids") ?? "[]")) ?? [],
                       requestPayload: r.string("request_payload"), resultJSON: r.string("result_json"),
                       createdAt: r.date("created_at") ?? Date(), completedAt: r.date("completed_at"))
    }

    public func saveWindow(_ w: AnalysisWindow) throws {
        try db.run("""
            INSERT INTO analysis_window (id, kind, start_ts, end_ts, awake_seconds, accrued_through, status, attempts,
              next_attempt_at, last_error, idempotency_key, event_ids, request_payload, result_json, created_at, completed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, start_ts=excluded.start_ts, end_ts=excluded.end_ts,
              awake_seconds=excluded.awake_seconds, accrued_through=excluded.accrued_through, status=excluded.status,
              attempts=excluded.attempts, next_attempt_at=excluded.next_attempt_at, last_error=excluded.last_error,
              event_ids=excluded.event_ids, request_payload=excluded.request_payload, result_json=excluded.result_json,
              completed_at=excluded.completed_at
            """, [w.id, w.kind.rawValue, w.start, w.end, w.awakeSeconds, w.accruedThrough, w.status.rawValue, w.attempts,
                  w.nextAttemptAt, w.lastError, w.idempotencyKey, try AtlasJSON.string(w.eventIDs), w.requestPayload,
                  w.resultJSON, w.createdAt, w.completedAt])
    }

    /// Close the open window and open its successor atomically, so no instant is lost or double-assigned.
    public func rollWindow(closing: AnalysisWindow, opening: AnalysisWindow?) throws {
        try db.transaction {
            try saveWindow(closing)
            if let opening { try saveWindow(opening) }
        }
    }

    public func window(id: String) throws -> AnalysisWindow? {
        try db.query("SELECT * FROM analysis_window WHERE id = ?", [id], map: mapWindow).first
    }

    public func openWindow() throws -> AnalysisWindow? {
        try db.query("SELECT * FROM analysis_window WHERE status = 'open' LIMIT 1", map: mapWindow).first
    }

    public func windows(status: [WindowStatus]) throws -> [AnalysisWindow] {
        let ph = Array(repeating: "?", count: status.count).joined(separator: ",")
        return try db.query("SELECT * FROM analysis_window WHERE status IN (\(ph)) ORDER BY start_ts",
                            status.map(\.rawValue), map: mapWindow)
    }

    public func recentWindows(limit: Int = 20) throws -> [AnalysisWindow] {
        try db.query("SELECT * FROM analysis_window ORDER BY COALESCE(end_ts, start_ts) DESC LIMIT ?", [limit], map: mapWindow)
    }

    /// Windows ready for (re)analysis whose backoff has elapsed.
    public func dueWindows(now: Date) throws -> [AnalysisWindow] {
        try db.query("""
            SELECT * FROM analysis_window
            WHERE status = 'ready' OR (status = 'failed' AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
            ORDER BY start_ts
            """, [now], map: mapWindow)
    }

    /// Atomically claim a window for sending. Returns false if another task already claimed it.
    public func claimWindow(id: String) throws -> Bool {
        try db.run("UPDATE analysis_window SET status = 'sending' WHERE id = ? AND status IN ('ready','failed')", id) == 1
    }

    // MARK: - Plan items

    private func mapPlan(_ r: Row) -> PlanItem {
        PlanItem(id: r.string("id")!, title: r.string("title") ?? "", notes: r.string("notes"),
                 expectedMinutes: r.int("expected_minutes") ?? 30, priority: r.int("priority") ?? 2,
                 deadline: r.date("deadline"), plannedStart: r.date("planned_start"),
                 status: PlanStatus(rawValue: r.string("status") ?? "") ?? .notStarted,
                 source: PlanSource(rawValue: r.string("source") ?? "") ?? .user,
                 userConfirmed: r.bool("user_confirmed"), isFlexible: r.bool("is_flexible"),
                 categoryHint: r.string("category_hint").flatMap(ActivityCategory.init(rawValue:)),
                 externalID: r.string("external_id"))
    }

    public func savePlanItem(_ p: PlanItem) throws {
        try db.run("""
            INSERT OR REPLACE INTO plan_item (id, title, notes, expected_minutes, priority, deadline, planned_start, status,
              source, user_confirmed, is_flexible, category_hint, external_id, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [p.id, p.title, p.notes, p.expectedMinutes, p.priority, p.deadline, p.plannedStart, p.status.rawValue,
                  p.source.rawValue, p.userConfirmed, p.isFlexible, p.categoryHint?.rawValue, p.externalID, Date()])
    }

    public func planItems(includeClosed: Bool = false) throws -> [PlanItem] {
        let filter = includeClosed ? "" : "WHERE status NOT IN ('completed','dropped')"
        return try db.query("SELECT * FROM plan_item \(filter) ORDER BY priority, COALESCE(deadline, 1e12), title", map: mapPlan)
    }

    public func planItem(id: String) throws -> PlanItem? {
        try db.query("SELECT * FROM plan_item WHERE id = ?", [id], map: mapPlan).first
    }

    public func deletePlanItem(id: String) throws { try db.run("DELETE FROM plan_item WHERE id = ?", id) }

    // MARK: - Agent actions

    private func mapAction(_ r: Row) -> AgentAction {
        let dec: (String?) -> ProposedChange? = { s in s.flatMap { try? AtlasJSON.decode(ProposedChange.self, from: $0) } }
        return AgentAction(id: r.string("id")!, windowID: r.string("window_id"),
                           kind: AgentActionKind(rawValue: r.string("kind") ?? "") ?? .createFocusBlock,
                           connectorID: r.string("connector_id") ?? "", targetResourceID: r.string("target_resource_id"),
                           previousState: dec(r.string("previous_state")),
                           intendedState: dec(r.string("intended_state")) ?? ProposedChange(title: "?"),
                           rationale: r.string("rationale") ?? "",
                           authorization: AuthorizationStatus(rawValue: r.string("authorization") ?? "") ?? .pending,
                           execution: ExecutionStatus(rawValue: r.string("execution") ?? "") ?? .notStarted,
                           result: r.string("result"), idempotencyKey: r.string("idempotency_key") ?? "",
                           createdAt: r.date("created_at") ?? Date(), executedAt: r.date("executed_at"),
                           createdResourceID: r.string("created_resource_id"))
    }

    /// Insert unless an action with the same idempotency key exists; returns the stored action either way.
    @discardableResult
    public func insertActionIfNew(_ a: AgentAction) throws -> (action: AgentAction, inserted: Bool) {
        if let existing = try db.query("SELECT * FROM agent_action WHERE idempotency_key = ?", [a.idempotencyKey], map: mapAction).first {
            return (existing, false)
        }
        try saveAction(a)
        return (a, true)
    }

    public func saveAction(_ a: AgentAction) throws {
        try db.run("""
            INSERT INTO agent_action (id, window_id, kind, connector_id, target_resource_id, previous_state, intended_state,
              rationale, authorization, execution, result, idempotency_key, created_at, executed_at, created_resource_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET intended_state=excluded.intended_state, authorization=excluded.authorization,
              execution=excluded.execution, result=excluded.result, executed_at=excluded.executed_at,
              created_resource_id=excluded.created_resource_id, previous_state=excluded.previous_state
            """, [a.id, a.windowID, a.kind.rawValue, a.connectorID, a.targetResourceID,
                  try a.previousState.map { try AtlasJSON.string($0) }, try AtlasJSON.string(a.intendedState),
                  a.rationale, a.authorization.rawValue, a.execution.rawValue, a.result, a.idempotencyKey,
                  a.createdAt, a.executedAt, a.createdResourceID])
    }

    public func action(id: String) throws -> AgentAction? {
        try db.query("SELECT * FROM agent_action WHERE id = ?", [id], map: mapAction).first
    }

    public func actions(windowID: String? = nil, limit: Int = 200) throws -> [AgentAction] {
        if let windowID {
            return try db.query("SELECT * FROM agent_action WHERE window_id = ? ORDER BY created_at", [windowID], map: mapAction)
        }
        return try db.query("SELECT * FROM agent_action ORDER BY created_at DESC LIMIT ?", [limit], map: mapAction)
    }

    public func pendingActions() throws -> [AgentAction] {
        try db.query("SELECT * FROM agent_action WHERE authorization = 'pending' ORDER BY created_at", map: mapAction)
    }

    /// Approved/auto-approved actions that have not run yet (or were interrupted mid-execution).
    public func executableActions() throws -> [AgentAction] {
        try db.query("""
            SELECT * FROM agent_action WHERE authorization IN ('approved','auto_approved')
            AND execution IN ('not_started','executing') ORDER BY created_at
            """, map: mapAction)
    }

    // MARK: - Daily summaries

    public func saveDailySummary(_ s: DailySummary) throws {
        try db.run("INSERT OR REPLACE INTO daily_summary (day, tz, body, updated_at) VALUES (?,?,?,?)",
                   s.day, s.timeZoneID, try AtlasJSON.string(s), Date())
    }

    public func dailySummary(day: String) throws -> DailySummary? {
        try db.query("SELECT body FROM daily_summary WHERE day = ?", [day]) { r in
            r.string("body").flatMap { try? AtlasJSON.decode(DailySummary.self, from: $0) }
        }.first ?? nil
    }

    public func dailySummaries(limit: Int = 30) throws -> [DailySummary] {
        try db.query("SELECT body FROM daily_summary ORDER BY day DESC LIMIT ?", [limit]) { r in
            r.string("body").flatMap { try? AtlasJSON.decode(DailySummary.self, from: $0) }
        }.compactMap { $0 }
    }

    // MARK: - Rules

    public func rules() throws -> [ClassificationRule] {
        try db.query("SELECT * FROM classification_rule ORDER BY created_at") { r in
            ClassificationRule(id: r.string("id")!, field: RuleField(rawValue: r.string("field") ?? "") ?? .appName,
                               pattern: r.string("pattern") ?? "", titleContains: r.string("title_contains"),
                               category: ActivityCategory(rawValue: r.string("category") ?? "") ?? .unknown,
                               confidence: r.double("confidence") ?? 0.5,
                               source: RuleSource(rawValue: r.string("source") ?? "") ?? .user,
                               createdAt: r.date("created_at") ?? Date())
        }
    }

    /// Upsert keyed on (field, pattern, titleContains): a newer correction replaces an older one.
    public func saveRule(_ rule: ClassificationRule) throws {
        try db.transaction {
            try db.run("DELETE FROM classification_rule WHERE field = ? AND pattern = ? AND IFNULL(title_contains,'') = ?",
                       rule.field.rawValue, rule.pattern, rule.titleContains ?? "")
            try db.run("""
                INSERT INTO classification_rule (id, field, pattern, title_contains, category, confidence, source, created_at)
                VALUES (?,?,?,?,?,?,?,?)
                """, rule.id, rule.field.rawValue, rule.pattern, rule.titleContains, rule.category.rawValue,
                       rule.confidence, rule.source.rawValue, rule.createdAt)
        }
    }

    public func deleteRule(id: String) throws { try db.run("DELETE FROM classification_rule WHERE id = ?", id) }

    // MARK: - Settings

    public func loadSettings() throws -> AtlasSettings {
        guard let json = try db.query("SELECT value FROM settings WHERE key = 'app'", map: { $0.string("value") }).first ?? nil else {
            return AtlasSettings()
        }
        return AtlasSettings.decodeLenient(json)
    }

    public func saveSettings(_ s: AtlasSettings) throws {
        try db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('app', ?)", try AtlasJSON.string(s))
    }

    // MARK: - Request log

    public struct RequestLogEntry: Sendable, Hashable, Identifiable {
        public var id: String
        public var windowID: String?
        public var ts: Date
        public var model: String
        public var requestBytes: Int
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var outcome: String
        public var durationMs: Int?

        public init(id: String = UUID().uuidString, windowID: String?, ts: Date = Date(), model: String, requestBytes: Int,
                    inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, outcome: String,
                    durationMs: Int? = nil) {
            self.id = id; self.windowID = windowID; self.ts = ts; self.model = model; self.requestBytes = requestBytes
            self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens
            self.outcome = outcome; self.durationMs = durationMs
        }
    }

    public func logRequest(_ e: RequestLogEntry) throws {
        try db.run("""
            INSERT INTO request_log (id, window_id, ts, model, request_bytes, input_tokens, output_tokens, cache_read_tokens, outcome, duration_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, e.id, e.windowID, e.ts, e.model, e.requestBytes, e.inputTokens, e.outputTokens, e.cacheReadTokens,
                   e.outcome, e.durationMs)
    }

    public func requestLog(limit: Int = 100) throws -> [RequestLogEntry] {
        try db.query("SELECT * FROM request_log ORDER BY ts DESC LIMIT ?", [limit]) { r in
            RequestLogEntry(id: r.string("id")!, windowID: r.string("window_id"), ts: r.date("ts")!, model: r.string("model") ?? "",
                            requestBytes: r.int("request_bytes") ?? 0, inputTokens: r.int("input_tokens"),
                            outputTokens: r.int("output_tokens"), cacheReadTokens: r.int("cache_read_tokens"),
                            outcome: r.string("outcome") ?? "", durationMs: r.int("duration_ms"))
        }
    }

    // MARK: - Check-ins

    public struct Checkin: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var ts: Date
        public var source: String
        /// "on_track" | "mixed" | "off_track" | "insufficient_data"
        public var verdict: String?
        public var body: String

        public init(id: String = UUID().uuidString, ts: Date = Date(), source: String, verdict: String?, body: String) {
            self.id = id; self.ts = ts; self.source = source; self.verdict = verdict; self.body = body
        }
    }

    public func saveCheckin(_ c: Checkin) throws {
        try db.run("INSERT OR REPLACE INTO checkin (id, ts, source, verdict, body) VALUES (?,?,?,?,?)",
                   c.id, c.ts, c.source, c.verdict, String(c.body.prefix(20_000)))
    }

    public func checkins(limit: Int = 30) throws -> [Checkin] {
        try db.query("SELECT * FROM checkin ORDER BY ts DESC LIMIT ?", [limit]) { r in
            Checkin(id: r.string("id")!, ts: r.date("ts")!, source: r.string("source") ?? "", verdict: r.string("verdict"),
                    body: r.string("body") ?? "")
        }
    }

    // MARK: - Tracker heartbeat

    public func heartbeat(at: Date, clean: Bool = false) throws {
        try db.run("INSERT OR REPLACE INTO tracker_state (id, last_heartbeat, clean_shutdown) VALUES (1, ?, ?)", at, clean)
    }

    public func lastHeartbeat() throws -> (date: Date, clean: Bool)? {
        try db.query("SELECT * FROM tracker_state WHERE id = 1") { r in (r.date("last_heartbeat")!, r.bool("clean_shutdown")) }.first
    }

    // MARK: - Retention, export, deletion

    public func purge(olderThan cutoff: Date, requestLogCutoff: Date) throws {
        try db.transaction {
            try db.run("DELETE FROM activity_event WHERE end_ts < ?", cutoff)
            try db.run("DELETE FROM activity_session WHERE end_ts < ?", cutoff)
            try db.run("DELETE FROM analysis_window WHERE end_ts IS NOT NULL AND end_ts < ? AND status IN ('analyzed','skipped','abandoned')", cutoff)
            try db.run("DELETE FROM agent_action WHERE created_at < ? AND execution NOT IN ('not_started','executing')", cutoff)
            try db.run("DELETE FROM request_log WHERE ts < ?", requestLogCutoff)
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Delete all personal data. Settings and rules are kept unless `includeConfiguration`.
    public func deleteAllData(includeConfiguration: Bool = false) throws {
        try db.transaction {
            for t in ["activity_event", "activity_session", "analysis_window", "plan_item", "agent_action",
                      "daily_summary", "request_log", "tracker_state", "checkin"] {
                try db.run("DELETE FROM \(t)")
            }
            if includeConfiguration {
                try db.run("DELETE FROM classification_rule")
                try db.run("DELETE FROM settings")
            }
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("VACUUM")
    }

    public struct ExportBundle: Codable, Sendable {
        public var exportedAt: Date
        public var schemaVersion: Int
        public var events: [ActivityEvent]
        public var sessions: [ActivitySession]
        public var windows: [AnalysisWindow]
        public var planItems: [PlanItem]
        public var actions: [AgentAction]
        public var dailySummaries: [DailySummary]
        public var rules: [ClassificationRule]
    }

    public func export(from: Date = .distantPast, to: Date = .distantFuture) throws -> ExportBundle {
        ExportBundle(exportedAt: Date(), schemaVersion: db.userVersion, events: try events(from: from, to: to),
                     sessions: try sessions(from: from, to: to),
                     windows: try db.query("SELECT * FROM analysis_window ORDER BY start_ts", map: mapWindow),
                     planItems: try planItems(includeClosed: true), actions: try actions(limit: 100_000),
                     dailySummaries: try dailySummaries(limit: 100_000), rules: try rules())
    }

    public func backup(to url: URL) throws { try db.backup(to: url.path) }
}
