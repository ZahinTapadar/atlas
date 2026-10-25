import Foundation

/// Ordered, append-only schema migrations. Each runs in a transaction and bumps `user_version`.
/// Never edit a shipped migration; add a new one.
enum Migrations {
    static let all: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE activity_event (
            id TEXT PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL CHECK (end_ts >= start_ts),
            app_bundle_id TEXT,
            app_name TEXT,
            pid INTEGER,
            window_title TEXT,
            browser_json TEXT,
            raw_type TEXT NOT NULL,
            state TEXT NOT NULL,
            category TEXT NOT NULL,
            confidence REAL NOT NULL,
            evidence TEXT NOT NULL,
            explanation TEXT,
            origin TEXT NOT NULL,
            session_id TEXT,
            privacy TEXT NOT NULL,
            tz TEXT NOT NULL,
            state_note TEXT
        );
        CREATE INDEX idx_event_start ON activity_event(start_ts);
        CREATE INDEX idx_event_end ON activity_event(end_ts);
        CREATE INDEX idx_event_session ON activity_event(session_id);
        CREATE INDEX idx_event_category ON activity_event(category, start_ts);

        CREATE TABLE activity_session (
            id TEXT PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL,
            primary_category TEXT NOT NULL,
            active_seconds REAL NOT NULL,
            idle_seconds REAL NOT NULL,
            context_switches INTEGER NOT NULL,
            event_count INTEGER NOT NULL,
            summary TEXT
        );
        CREATE INDEX idx_session_start ON activity_session(start_ts);

        CREATE TABLE analysis_window (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            start_ts REAL NOT NULL,
            end_ts REAL,
            awake_seconds REAL NOT NULL,
            accrued_through REAL NOT NULL,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL,
            last_error TEXT,
            idempotency_key TEXT NOT NULL UNIQUE,
            event_ids TEXT NOT NULL DEFAULT '[]',
            request_payload TEXT,
            result_json TEXT,
            created_at REAL NOT NULL,
            completed_at REAL
        );
        CREATE INDEX idx_window_status ON analysis_window(status, next_attempt_at);
        CREATE INDEX idx_window_range ON analysis_window(start_ts, end_ts);
        -- At most one open scheduled window: the core invariant that prevents overlap.
        CREATE UNIQUE INDEX idx_one_open_window ON analysis_window(status) WHERE status = 'open';

        CREATE TABLE plan_item (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            notes TEXT,
            expected_minutes INTEGER NOT NULL,
            priority INTEGER NOT NULL,
            deadline REAL,
            planned_start REAL,
            status TEXT NOT NULL,
            source TEXT NOT NULL,
            user_confirmed INTEGER NOT NULL,
            is_flexible INTEGER NOT NULL,
            category_hint TEXT,
            external_id TEXT,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_plan_status ON plan_item(status);

        CREATE TABLE agent_action (
            id TEXT PRIMARY KEY,
            window_id TEXT,
            kind TEXT NOT NULL,
            connector_id TEXT NOT NULL,
            target_resource_id TEXT,
            previous_state TEXT,
            intended_state TEXT NOT NULL,
            rationale TEXT NOT NULL,
            authorization TEXT NOT NULL,
            execution TEXT NOT NULL,
            result TEXT,
            idempotency_key TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL,
            executed_at REAL,
            created_resource_id TEXT
        );
        CREATE INDEX idx_action_window ON agent_action(window_id);
        CREATE INDEX idx_action_auth ON agent_action(authorization, execution);

        CREATE TABLE daily_summary (
            day TEXT PRIMARY KEY,
            tz TEXT NOT NULL,
            body TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE classification_rule (
            id TEXT PRIMARY KEY,
            field TEXT NOT NULL,
            pattern TEXT NOT NULL,
            title_contains TEXT,
            category TEXT NOT NULL,
            confidence REAL NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX idx_rule_unique ON classification_rule(field, pattern, IFNULL(title_contains, ''));

        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        -- Metadata-only log of model requests (no payload contents) for usage estimates.
        CREATE TABLE request_log (
            id TEXT PRIMARY KEY,
            window_id TEXT,
            ts REAL NOT NULL,
            model TEXT NOT NULL,
            request_bytes INTEGER NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read_tokens INTEGER,
            outcome TEXT NOT NULL,
            duration_ms INTEGER
        );
        CREATE INDEX idx_request_ts ON request_log(ts);

        -- Tracker heartbeat lets us detect crashes / unclean shutdowns and record gaps honestly.
        CREATE TABLE tracker_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            last_heartbeat REAL NOT NULL,
            clean_shutdown INTEGER NOT NULL
        );
        """),
        (2, """
        -- Feedback written back by scheduled Claude check-ins (via `atlas checkin`).
        CREATE TABLE checkin (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            source TEXT NOT NULL,
            verdict TEXT,
            body TEXT NOT NULL
        );
        CREATE INDEX idx_checkin_ts ON checkin(ts);
        """),
        (3, """
        -- Per check-in to-do status (mirrors Things: what was supposed to happen and what did).
        ALTER TABLE checkin ADD COLUMN todos TEXT;
        """),
    ]

    static var latestVersion: Int { all.last?.version ?? 0 }

    static func migrate(_ db: SQLiteConnection) throws {
        let current = db.userVersion
        guard current <= latestVersion else {
            throw SQLiteError(code: -1, message: "Database schema v\(current) is newer than this build (v\(latestVersion))")
        }
        for m in all where m.version > current {
            try db.transaction {
                try db.execute(m.sql)
                try db.setUserVersion(m.version)
            }
        }
    }
}
