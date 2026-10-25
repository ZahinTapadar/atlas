import Foundation

public struct ConnectorCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let readEvents = ConnectorCapabilities(rawValue: 1)
    public static let writeEvents = ConnectorCapabilities(rawValue: 2)
    public static let reminders = ConnectorCapabilities(rawValue: 4)
}

public enum ConnectorStatus: Sendable, Hashable {
    case connected
    case notAuthorized(String)
    case unavailable(String)

    public var isConnected: Bool { if case .connected = self { true } else { false } }
    public var label: String {
        switch self {
        case .connected: "Connected"
        case .notAuthorized(let s): "Not authorized — \(s)"
        case .unavailable(let s): "Unavailable — \(s)"
        }
    }
}

public struct EventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var notes: String?
    /// Idempotency marker stored on the external event so retries can find it.
    public var atlasKey: String
    public var calendarID: String?

    public init(title: String, start: Date, end: Date, notes: String?, atlasKey: String, calendarID: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.notes = notes
        self.atlasKey = atlasKey
        self.calendarID = calendarID
    }
}

/// Calendar / task backends (EventKit today; Google, Todoist, etc. can conform later).
/// Read and write are separate capabilities. There is deliberately no API for invitations.
public protocol CalendarConnector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ConnectorCapabilities { get }
    func status() async -> ConnectorStatus
    func events(in interval: DateInterval) async throws -> [CalendarEvent]
    func findEvent(atlasKey: String, near interval: DateInterval) async throws -> CalendarEvent?
    func createEvent(_ draft: EventDraft) async throws -> String
    /// Only ever called for events created by ATLAS.
    func moveEvent(id: String, to interval: DateInterval) async throws
    /// Only used to roll back an event ATLAS itself created.
    func deleteAtlasEvent(id: String) async throws
    func createReminder(title: String, due: Date?, notes: String?, atlasKey: String) async throws -> String
}

public enum AtlasMarker {
    public static func tag(_ key: String) -> String { "[atlas:\(key)]" }
    public static func extract(from notes: String?) -> String? {
        guard let notes, let r = notes.range(of: #"\[atlas:([^\]]+)\]"#, options: .regularExpression) else { return nil }
        return String(notes[r].dropFirst(7).dropLast())
    }
}

/// Deterministic connector for tests and previews.
public actor InMemoryCalendarConnector: CalendarConnector {
    public nonisolated let id: String
    public nonisolated let displayName = "In-memory calendar"
    public nonisolated let capabilities: ConnectorCapabilities = [.readEvents, .writeEvents, .reminders]
    public private(set) var stored: [CalendarEvent]
    public private(set) var reminders: [(id: String, title: String, key: String)] = []
    public private(set) var writeCount = 0
    public var failNextWrite = false
    public var connected = true

    public init(id: String = "memory", events: [CalendarEvent] = []) {
        self.id = id
        self.stored = events
    }

    public func setFailNextWrite(_ v: Bool) { failNextWrite = v }
    public func setConnected(_ v: Bool) { connected = v }

    public func status() async -> ConnectorStatus { connected ? .connected : .unavailable("offline") }

    public func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        guard connected else { throw ProviderError.retryable("calendar offline") }
        return stored.filter { $0.end > interval.start && $0.start < interval.end }
    }

    public func findEvent(atlasKey: String, near interval: DateInterval) async throws -> CalendarEvent? {
        stored.first { $0.atlasKey == atlasKey }
    }

    private func checkWrite() throws {
        guard connected else { throw ProviderError.retryable("calendar offline") }
        if failNextWrite { failNextWrite = false; throw ProviderError.retryable("simulated write failure") }
        writeCount += 1
    }

    public func createEvent(_ d: EventDraft) async throws -> String {
        try checkWrite()
        let id = "evt-\(stored.count + 1)-\(d.atlasKey.prefix(6))"
        stored.append(CalendarEvent(id: id, title: d.title, start: d.start, end: d.end, createdByAtlas: true,
                                    atlasKey: d.atlasKey, notes: d.notes))
        return id
    }

    public func moveEvent(id: String, to interval: DateInterval) async throws {
        try checkWrite()
        guard let i = stored.firstIndex(where: { $0.id == id }) else { throw ProviderError.permanent("no such event") }
        stored[i].start = interval.start
        stored[i].end = interval.end
    }

    public func deleteAtlasEvent(id: String) async throws {
        try checkWrite()
        stored.removeAll { $0.id == id && $0.createdByAtlas }
    }

    public func createReminder(title: String, due: Date?, notes: String?, atlasKey: String) async throws -> String {
        if let existing = reminders.first(where: { $0.key == atlasKey }) { return existing.id }
        try checkWrite()
        let id = "rem-\(reminders.count + 1)"
        reminders.append((id, title, atlasKey))
        return id
    }
}
