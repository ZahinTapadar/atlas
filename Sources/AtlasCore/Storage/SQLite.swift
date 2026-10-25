import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int32: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
/// Dates are stored as UTC epoch seconds (REAL) — canonical and timezone-independent.
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }

public struct Row {
    fileprivate let stmt: OpaquePointer
    fileprivate let columns: [String: Int32]

    public func isNull(_ name: String) -> Bool {
        guard let i = columns[name] else { return true }
        return sqlite3_column_type(stmt, i) == SQLITE_NULL
    }
    public func string(_ name: String) -> String? {
        guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    public func int(_ name: String) -> Int? {
        guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, i))
    }
    public func double(_ name: String) -> Double? {
        guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, i)
    }
    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
}

/// Minimal, synchronous SQLite connection. Not thread-safe by itself:
/// `AtlasStore` (an actor) is the only owner.
public final class SQLiteConnection {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: -1, message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
        // WAL gives crash-safe, atomic commits and lets the native host write concurrently.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close_v2(db) }

    private var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(db), message: msg)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError }
        for (idx, p) in params.enumerated() {
            let i = Int32(idx + 1)
            let rc: Int32
            switch p.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case .int(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
            if rc != SQLITE_OK { sqlite3_finalize(stmt); throw lastError }
        }
        return stmt
    }

    @discardableResult
    public func run(_ sql: String, _ params: SQLBindable...) throws -> Int {
        try run(sql, params)
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLBindable]) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError }
        return Int(sqlite3_changes(db))
    }

    public func query<T>(_ sql: String, _ params: [SQLBindable] = [], map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var cols: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            cols[String(cString: sqlite3_column_name(stmt, i))] = i
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError }
            out.append(try map(Row(stmt: stmt, columns: cols)))
        }
        return out
    }

    public func scalarInt(_ sql: String, _ params: [SQLBindable] = []) throws -> Int? {
        try query(sql, params) { row -> Int? in
            sqlite3_column_type(row.stmt, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(row.stmt, 0))
        }.first ?? nil
    }

    /// All-or-nothing: an interrupted write (crash, error) leaves no partial state.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try execute("COMMIT")
            return v
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    /// Online, consistent backup to another file (safe while the DB is in use).
    public func backup(to destination: String) throws {
        var dest: OpaquePointer?
        guard sqlite3_open(destination, &dest) == SQLITE_OK else {
            sqlite3_close(dest)
            throw SQLiteError(code: -1, message: "cannot open backup destination")
        }
        defer { sqlite3_close(dest) }
        guard let b = sqlite3_backup_init(dest, "main", db, "main") else {
            throw SQLiteError(code: sqlite3_errcode(dest), message: String(cString: sqlite3_errmsg(dest)))
        }
        sqlite3_backup_step(b, -1)
        let rc = sqlite3_backup_finish(b)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: "backup failed") }
    }

    public func integrityCheck() -> Bool {
        ((try? query("PRAGMA quick_check") { $0.string("quick_check") })?.first ?? nil) == "ok"
    }
}
