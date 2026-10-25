import Foundation
import CryptoKit

/// Decides whether a proposed action may run, needs approval, or is forbidden (spec §10).
public enum AuthorizationPolicy {
    public static func decide(_ action: AgentAction, level: AuthorizationLevel, rules: BoundedAutomationRules,
                              planner: SlotPlanner, calendar: [CalendarEvent], now: Date) -> AuthorizationStatus {
        // Moving anything not created by ATLAS, or shared with other people, is never allowed.
        if action.kind == .moveEvent {
            guard let target = calendar.first(where: { $0.id == action.targetResourceID }), !target.isFixed else {
                return .blockedByPolicy
            }
        }
        switch level {
        case .readOnly:
            return .blockedByPolicy
        case .approvalRequired:
            return .pending
        case .boundedAutomation:
            guard rules.autoKinds.contains(action.kind) else { return .pending }
            if let s = action.intendedState.start, let e = action.intendedState.end {
                if s < now || e > now.addingTimeInterval(rules.horizonHours * 3600) { return .pending }
                if planner.validate(start: s, end: e, against: calendar, requireWorkingHours: rules.requireWorkingHours) != nil {
                    return .pending
                }
            } else if action.kind != .createReminder {
                return .pending
            }
            return .autoApproved
        }
    }

    /// Stable key: the same proposal from the same window always maps to the same key.
    public static func idempotencyKey(windowKey: String, correction c: AgentResult.Correction) -> String {
        let raw = [windowKey, c.action, c.planItemID, c.targetEventID, c.title.lowercased(), c.start, c.end].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return "atl-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Executes authorized actions against connectors. Every write is checked for conflicts,
/// deduplicated via the idempotency marker, persisted before and after, and reversible where possible.
public struct ActionExecutor: Sendable {
    let store: AtlasStore
    let connectors: [String: CalendarConnector]

    public init(store: AtlasStore, connectors: [CalendarConnector]) {
        self.store = store
        self.connectors = Dictionary(connectors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @discardableResult
    public func execute(_ input: AgentAction, settings: AtlasSettings, planner: SlotPlanner) async -> AgentAction {
        var a = input
        guard a.authorization == .approved || a.authorization == .autoApproved else { return a }
        // Defense in depth: re-check the level at execution time; the user may have lowered it since approval.
        if settings.authorizationLevel == .readOnly {
            a.authorization = .blockedByPolicy
            a.result = "Blocked: authorization level is read-only"
            try? await store.saveAction(a)
            return a
        }
        guard a.execution == .notStarted || a.execution == .executing else { return a }

        a.execution = .executing
        try? await store.saveAction(a)

        do {
            switch a.kind {
            case .createFocusBlock, .createBreak, .rescheduleTask:
                try await createBlock(&a, settings: settings, planner: planner)
            case .moveEvent:
                try await move(&a)
            case .createReminder:
                guard let c = connector(for: a, needs: .reminders) else { throw ProviderError.notConfigured("No reminders connector") }
                let id = try await c.createReminder(title: a.intendedState.title, due: a.intendedState.start,
                                                    notes: annotated(a), atlasKey: a.idempotencyKey)
                a.createdResourceID = id
                a.execution = .succeeded
                a.result = "Reminder created"
            case .updatePlanItem:
                try await updatePlan(&a)
            case .splitTask:
                try await split(&a)
            }
        } catch {
            a.execution = .failed
            a.result = "Failed: \(error)"
        }
        a.executedAt = Date()
        try? await store.saveAction(a)
        return a
    }

    private func connector(for a: AgentAction, needs cap: ConnectorCapabilities) -> CalendarConnector? {
        if let c = connectors[a.connectorID], c.capabilities.contains(cap) { return c }
        return connectors.values.first { $0.capabilities.contains(cap) }
    }

    private func annotated(_ a: AgentAction) -> String {
        "\(a.rationale)\n\nCreated by ATLAS. \(AtlasMarker.tag(a.idempotencyKey))"
    }

    private func createBlock(_ a: inout AgentAction, settings: AtlasSettings, planner: SlotPlanner) async throws {
        guard let s = a.intendedState.start, let e = a.intendedState.end else { throw ProviderError.permanent("Missing time") }
        guard let c = connector(for: a, needs: .writeEvents) else { throw ProviderError.notConfigured("No writable calendar connected") }
        let iv = DateInterval(start: s, end: e)
        let around = DateInterval(start: s.addingTimeInterval(-86400), end: e.addingTimeInterval(86400))

        // 1. Idempotency: already created by a previous (possibly interrupted) attempt?
        if let existing = try await c.findEvent(atlasKey: a.idempotencyKey, near: around) {
            a.createdResourceID = existing.id
            a.execution = .skippedDuplicate
            a.result = "Already exists"
            return
        }
        let current = try await c.events(in: around)
        // 2. Semantic duplicate: an ATLAS event with the same title overlapping the same time.
        if let dup = current.first(where: { $0.createdByAtlas && $0.title.caseInsensitiveCompare(a.intendedState.title) == .orderedSame
                                          && DateInterval(start: $0.start, end: $0.end).intersects(iv) }) {
            a.createdResourceID = dup.id
            a.execution = .skippedDuplicate
            a.result = "Equivalent event already on calendar"
            return
        }
        // 3. Conflict with a fixed commitment that appeared since the proposal.
        if let why = planner.validate(start: s, end: e, against: current, requireWorkingHours: false) {
            a.execution = .skippedConflict
            a.result = why
            return
        }
        let id = try await c.createEvent(EventDraft(title: a.intendedState.title, start: s, end: e, notes: annotated(a),
                                                    atlasKey: a.idempotencyKey, calendarID: settings.targetCalendarID))
        a.createdResourceID = id
        a.execution = .succeeded
        a.result = "Created on \(c.displayName)"

        if a.kind == .rescheduleTask, let pid = a.intendedState.planItemID, var item = try await store.planItem(id: pid) {
            item.plannedStart = s
            if item.status == .notStarted || item.status == .deferred { item.status = .notStarted }
            try await store.savePlanItem(item)
        }
    }

    private func move(_ a: inout AgentAction) async throws {
        guard let c = connector(for: a, needs: .writeEvents), let target = a.targetResourceID,
              let s = a.intendedState.start, let e = a.intendedState.end else { throw ProviderError.permanent("Incomplete move") }
        let around = DateInterval(start: s.addingTimeInterval(-7 * 86400), end: e.addingTimeInterval(7 * 86400))
        guard let ev = try await c.events(in: around).first(where: { $0.id == target }) else {
            throw ProviderError.permanent("Event no longer exists")
        }
        guard !ev.isFixed else {
            a.authorization = .blockedByPolicy
            a.execution = .notStarted
            a.result = "Blocked: only unshared events created by ATLAS can be moved"
            return
        }
        if ev.start == s && ev.end == e {
            a.execution = .skippedDuplicate
            a.result = "Already at the proposed time"
            return
        }
        a.previousState = ProposedChange(title: ev.title, start: ev.start, end: ev.end)
        try await store.saveAction(a) // persist rollback info before the write
        try await c.moveEvent(id: target, to: DateInterval(start: s, end: e))
        a.execution = .succeeded
        a.result = "Moved"
    }

    private func updatePlan(_ a: inout AgentAction) async throws {
        guard let pid = a.intendedState.planItemID, var item = try await store.planItem(id: pid) else {
            throw ProviderError.permanent("Task not found")
        }
        a.previousState = ProposedChange(title: item.title, start: item.plannedStart, notes: item.notes, planItemID: pid,
                                         planStatus: item.status)
        if let s = a.intendedState.start { item.plannedStart = s }
        if let st = a.intendedState.planStatus, st != .dropped { item.status = st }
        if let n = a.intendedState.notes, !n.isEmpty { item.notes = [item.notes, n].compactMap { $0 }.joined(separator: "\n") }
        try await store.savePlanItem(item)
        a.execution = .succeeded
        a.result = "Task updated"
    }

    private func split(_ a: inout AgentAction) async throws {
        guard let pid = a.intendedState.planItemID, var item = try await store.planItem(id: pid) else {
            throw ProviderError.permanent("Task not found")
        }
        let half = max(15, item.expectedMinutes / 2)
        for i in 1...2 {
            let part = PlanItem(id: "\(a.idempotencyKey)-\(i)", title: "\(item.title) (part \(i)/2)", notes: item.notes,
                                expectedMinutes: half, priority: item.priority, deadline: item.deadline, source: .agent,
                                userConfirmed: true, categoryHint: item.categoryHint)
            try await store.savePlanItem(part)
        }
        a.previousState = ProposedChange(title: item.title, planItemID: pid, planStatus: item.status)
        item.status = .deferred
        item.notes = [item.notes, "Split into two parts by ATLAS."].compactMap { $0 }.joined(separator: "\n")
        try await store.savePlanItem(item)
        a.execution = .succeeded
        a.result = "Split into two tasks"
    }

    /// Undo a successful action where possible.
    @discardableResult
    public func rollback(_ input: AgentAction) async -> AgentAction {
        var a = input
        guard a.execution == .succeeded else { return a }
        do {
            switch a.kind {
            case .createFocusBlock, .createBreak, .rescheduleTask:
                guard let c = connector(for: a, needs: .writeEvents), let id = a.createdResourceID else { return a }
                try await c.deleteAtlasEvent(id: id)
            case .moveEvent:
                guard let c = connector(for: a, needs: .writeEvents), let id = a.targetResourceID,
                      let s = a.previousState?.start, let e = a.previousState?.end else { return a }
                try await c.moveEvent(id: id, to: DateInterval(start: s, end: e))
            case .updatePlanItem, .splitTask:
                guard let pid = a.previousState?.planItemID, var item = try await store.planItem(id: pid) else { return a }
                if let st = a.previousState?.planStatus { item.status = st }
                if a.kind == .updatePlanItem { item.plannedStart = a.previousState?.start; item.notes = a.previousState?.notes }
                try await store.savePlanItem(item)
                if a.kind == .splitTask {
                    for i in 1...2 { try await store.deletePlanItem(id: "\(a.idempotencyKey)-\(i)") }
                }
            case .createReminder:
                return a // Reminders are left for the user to remove; we never delete user-visible tasks.
            }
            a.execution = .rolledBack
            a.result = "Rolled back"
        } catch {
            a.result = "Rollback failed: \(error)"
        }
        try? await store.saveAction(a)
        return a
    }
}
