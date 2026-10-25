import Foundation

/// When check-ins happen, decided in ATLAS. The Claude task runs every hour in `runHours` and first asks
/// ATLAS (`should_check_in`); everything except the chosen hours, days, pauses and skips stops there.
public struct CheckinPlan: Codable, Hashable, Sendable {
    /// Local hours (0–23) that get a check-in.
    public var hours: [Int] = [9, 12, 15, 18, 21]
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    public var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    /// No check-ins before this moment.
    public var pausedUntil: Date?
    /// One upcoming slot (its start) to skip.
    public var skippedSlot: Date?

    public init() {}

    /// The hours the Claude task wakes up in; only these can be chosen.
    public static let runHours = Array(6...23)
    /// The Claude task's schedule: on the hour, every hour in `runHours`.
    public static let cron = "0 6-23 * * *"

    public struct Decision: Codable, Sendable, Equatable {
        public var proceed: Bool
        public var reason: String
    }

    public func isScheduled(_ slot: Date, calendar: Calendar = .current) -> Bool {
        hours.contains(calendar.component(.hour, from: slot)) && weekdays.contains(calendar.component(.weekday, from: slot))
    }

    /// The next scheduled slot after `date` that isn't paused or skipped.
    public func next(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard !hours.isEmpty, !weekdays.isEmpty else { return nil }
        var t = calendar.dateInterval(of: .hour, for: date)?.end ?? date
        for _ in 0..<(24 * 15) {
            if isScheduled(t, calendar: calendar), pausedUntil.map({ t >= $0 }) ?? true, t != skippedSlot { return t }
            t = t.addingTimeInterval(3600)
        }
        return nil
    }

    /// Whether the check-in that woke up at `now` should go ahead.
    public func decide(at now: Date = Date(), lastCheckin: Date?, manual: Bool = false, calendar: Calendar = .current) -> Decision {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        if manual { return Decision(proceed: true, reason: "Requested from ATLAS.") }
        if let p = pausedUntil, now < p {
            let df = DateFormatter(); df.setLocalizedDateFormatFromTemplate("EEE jmm")
            return Decision(proceed: false, reason: "Check-ins are paused until \(df.string(from: p)).")
        }
        guard let slot = calendar.dateInterval(of: .hour, for: now)?.start, isScheduled(slot, calendar: calendar) else {
            return Decision(proceed: false, reason: "No check-in is scheduled for this hour.")
        }
        if skippedSlot == slot { return Decision(proceed: false, reason: "This check-in was skipped in ATLAS.") }
        if let last = lastCheckin, now.timeIntervalSince(last) < 45 * 60, now >= last {
            return Decision(proceed: false, reason: "Already checked in at \(f.string(from: last)).")
        }
        return Decision(proceed: true, reason: "Scheduled check-in at \(f.string(from: slot)).")
    }
}
