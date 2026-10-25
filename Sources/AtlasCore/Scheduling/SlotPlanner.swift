import Foundation

public struct ScheduledBlock: Codable, Hashable, Sendable {
    public var planItemID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isBreak: Bool
}

/// Finds free time and packs tasks into it without overlapping fixed commitments or overfilling.
public struct SlotPlanner: Sendable {
    public var workingHours: DailyHours
    public var bufferMinutes: Int
    public var breakEveryMinutes: Int
    public var breakMinutes: Int
    public var minimumSlotMinutes: Int
    public var calendar: Calendar

    public init(workingHours: DailyHours, bufferMinutes: Int = 10, breakEveryMinutes: Int = 90, breakMinutes: Int = 10,
                minimumSlotMinutes: Int = 15, timeZone: TimeZone = .current) {
        self.workingHours = workingHours
        self.bufferMinutes = bufferMinutes
        self.breakEveryMinutes = breakEveryMinutes
        self.breakMinutes = breakMinutes
        self.minimumSlotMinutes = minimumSlotMinutes
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    public init(settings s: AtlasSettings, timeZone: TimeZone = .current) {
        self.init(workingHours: s.workingHours, bufferMinutes: s.bufferMinutes, breakEveryMinutes: s.breakEveryMinutes,
                  timeZone: timeZone)
    }

    /// Working-hour intervals intersecting `period`, computed per local day (DST-safe: uses calendar arithmetic).
    public func workingIntervals(in period: DateInterval) -> [DateInterval] {
        var out: [DateInterval] = []
        var day = calendar.startOfDay(for: period.start)
        while day < period.end {
            if let s = calendar.date(byAdding: .minute, value: workingHours.startMinute, to: day),
               let e = calendar.date(byAdding: .minute, value: workingHours.endMinute, to: day), e > s,
               let iv = DateInterval(start: s, end: e).intersection(with: period), iv.duration > 0 {
                out.append(iv)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// Free intervals in `period`: working hours minus busy events (each padded by the buffer).
    public func freeSlots(in period: DateInterval, busy: [CalendarEvent]) -> [DateInterval] {
        let pad = TimeInterval(bufferMinutes * 60)
        let blocks = busy.filter { !$0.isAllDay }
            .map { DateInterval(start: $0.start.addingTimeInterval(-pad), end: max($0.start, $0.end).addingTimeInterval(pad)) }
            .sorted { $0.start < $1.start }
        var free: [DateInterval] = []
        for wi in workingIntervals(in: period) {
            var cursor = wi.start
            for b in blocks where b.end > cursor && b.start < wi.end {
                if b.start > cursor { free.append(DateInterval(start: cursor, end: b.start)) }
                cursor = max(cursor, b.end)
            }
            if cursor < wi.end { free.append(DateInterval(start: cursor, end: wi.end)) }
        }
        return free.filter { $0.duration >= TimeInterval(minimumSlotMinutes * 60) }
    }

    /// Greedy packing by priority then deadline. Tasks that don't fit are returned as `unscheduled`
    /// rather than squeezed in. Breaks are inserted after `breakEveryMinutes` of continuous work.
    public func pack(_ items: [PlanItem], into slots: [DateInterval]) -> (blocks: [ScheduledBlock], unscheduled: [PlanItem]) {
        let queue = items.filter { $0.isFlexible && $0.status != .completed && $0.status != .dropped }
            .sorted { ($0.priority, $0.deadline ?? .distantFuture, $0.title) < ($1.priority, $1.deadline ?? .distantFuture, $1.title) }
        var free = slots.sorted { $0.start < $1.start }
        var blocks: [ScheduledBlock] = []
        var unscheduled: [PlanItem] = []
        var continuous: [Date: TimeInterval] = [:] // slot start → work minutes since last break

        for item in queue {
            let need = TimeInterval(item.expectedMinutes * 60)
            guard let idx = free.firstIndex(where: { $0.duration >= need }) else { unscheduled.append(item); continue }
            var slot = free[idx]
            let run = continuous[slot.start] ?? 0
            if run > 0, run + need > TimeInterval(breakEveryMinutes * 60) {
                let brk = TimeInterval(breakMinutes * 60)
                if slot.duration >= brk + need {
                    blocks.append(ScheduledBlock(planItemID: nil, title: "Break", start: slot.start,
                                                 end: slot.start.addingTimeInterval(brk), isBreak: true))
                    slot = DateInterval(start: slot.start.addingTimeInterval(brk), end: slot.end)
                    continuous[slot.start] = 0
                }
            }
            let start = slot.start, end = start.addingTimeInterval(need)
            blocks.append(ScheduledBlock(planItemID: item.id, title: item.title, start: start, end: end, isBreak: false))
            let remaining = DateInterval(start: end, end: slot.end)
            let carried = (continuous[slot.start] ?? 0) + need
            continuous[slot.start] = nil
            if remaining.duration >= TimeInterval(minimumSlotMinutes * 60) {
                free[idx] = remaining
                continuous[remaining.start] = carried
            } else {
                free.remove(at: idx)
            }
        }
        return (blocks, unscheduled)
    }

    /// Whether a proposed block respects fixed commitments and working hours.
    public func validate(start: Date, end: Date, against busy: [CalendarEvent], requireWorkingHours: Bool) -> String? {
        guard end > start else { return "Block has no duration" }
        let iv = DateInterval(start: start, end: end)
        if let clash = busy.first(where: { $0.isFixed && !$0.isAllDay && DateInterval(start: $0.start, end: max($0.start, $0.end)).intersects(iv)
                                     && DateInterval(start: $0.start, end: max($0.start, $0.end)).intersection(with: iv)!.duration > 0 }) {
            return "Overlaps fixed commitment “\(clash.title)”"
        }
        if requireWorkingHours {
            let inside = workingIntervals(in: DateInterval(start: calendar.startOfDay(for: start), end: end.addingTimeInterval(1)))
                .contains { $0.start <= start && $0.end >= end }
            if !inside { return "Outside working hours" }
        }
        return nil
    }
}
