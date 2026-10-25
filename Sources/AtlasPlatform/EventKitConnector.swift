import AtlasCore
import EventKit
import Foundation

/// Apple Calendar & Reminders through EventKit. Read and write are gated separately by
/// the user's authorization level; EventKit itself asks for full access the first time.
/// ATLAS-created events carry `atlas://<key>` in their URL and a marker in their notes.
public final class EventKitConnector: CalendarConnector, @unchecked Sendable {
    public let id = "eventkit"
    public let displayName = "Apple Calendar"
    public let capabilities: ConnectorCapabilities = [.readEvents, .writeEvents, .reminders]
    private let store = EKEventStore()
    private let lock = NSLock()

    public init() {}

    public func requestAccess() async -> Bool {
        let events = (try? await store.requestFullAccessToEvents()) ?? false
        _ = try? await store.requestFullAccessToReminders()
        return events
    }

    public func status() async -> ConnectorStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .connected
        case .notDetermined: .notAuthorized("Calendar access not requested yet")
        case .writeOnly: .notAuthorized("Write-only access; ATLAS needs to read events to avoid conflicts")
        default: .notAuthorized("Calendar access denied in System Settings")
        }
    }

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw ProviderError.notConfigured("Calendar access not granted")
        }
    }

    private func map(_ e: EKEvent) -> CalendarEvent {
        let key = e.url?.scheme == "atlas" ? e.url?.host : AtlasMarker.extract(from: e.notes)
        return CalendarEvent(id: e.calendarItemIdentifier, calendarID: e.calendar.calendarIdentifier, title: e.title ?? "",
                             start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                             hasAttendees: !(e.attendees ?? []).isEmpty, createdByAtlas: key != nil, atlasKey: key,
                             notes: nil) // notes are never read into ATLAS beyond the marker
    }

    public func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        try requireAccess()
        let pred = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return lock.withLock { store.events(matching: pred) }
            .filter { $0.availability != .free && $0.status != .canceled }
            .map(map)
    }

    public func findEvent(atlasKey: String, near interval: DateInterval) async throws -> CalendarEvent? {
        try await events(in: interval).first { $0.atlasKey == atlasKey }
    }

    private func calendar(id: String?) -> EKCalendar? {
        if let id, let c = store.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        return store.defaultCalendarForNewEvents
    }

    public func createEvent(_ d: EventDraft) async throws -> String {
        try requireAccess()
        guard let cal = calendar(id: d.calendarID) else { throw ProviderError.notConfigured("No writable calendar") }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = d.title
        e.startDate = d.start
        e.endDate = d.end
        e.notes = d.notes
        e.url = URL(string: "atlas://\(d.atlasKey)")
        e.availability = .busy
        try lock.withLock { try store.save(e, span: .thisEvent, commit: true) }
        return e.calendarItemIdentifier
    }

    private func atlasEvent(_ id: String) throws -> EKEvent {
        guard let e = store.calendarItem(withIdentifier: id) as? EKEvent else { throw ProviderError.permanent("Event not found") }
        guard e.url?.scheme == "atlas" || AtlasMarker.extract(from: e.notes) != nil, (e.attendees ?? []).isEmpty else {
            throw ProviderError.permanent("Refusing to modify an event not created by ATLAS")
        }
        return e
    }

    public func moveEvent(id: String, to interval: DateInterval) async throws {
        try requireAccess()
        let e = try atlasEvent(id)
        e.startDate = interval.start
        e.endDate = interval.end
        try lock.withLock { try store.save(e, span: .thisEvent, commit: true) }
    }

    public func deleteAtlasEvent(id: String) async throws {
        try requireAccess()
        let e = try atlasEvent(id)
        try lock.withLock { try store.remove(e, span: .thisEvent, commit: true) }
    }

    public func createReminder(title: String, due: Date?, notes: String?, atlasKey: String) async throws -> String {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ProviderError.notConfigured("Reminders access not granted")
        }
        // Idempotency: look for an existing reminder with our marker.
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let existing: [(id: String, key: String?)] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { list in
                cont.resume(returning: (list ?? []).map { ($0.calendarItemIdentifier, AtlasMarker.extract(from: $0.notes)) })
            }
        }
        if let r = existing.first(where: { $0.key == atlasKey }) { return r.id }
        let r = EKReminder(eventStore: store)
        r.calendar = store.defaultCalendarForNewReminders()
        r.title = title
        r.notes = notes
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        try lock.withLock { try store.save(r, commit: true) }
        return r.calendarItemIdentifier
    }

    public func writableCalendars() -> [(id: String, title: String)] {
        store.calendars(for: .event).filter(\.allowsContentModifications).map { ($0.calendarIdentifier, $0.title) }
    }
}
