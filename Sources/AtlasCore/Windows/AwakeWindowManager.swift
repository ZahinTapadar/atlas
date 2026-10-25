import Foundation

public struct WindowPolicy: Sendable {
    public var interval: TimeInterval
    /// A contiguous non-awake stretch (sleep, lock, away) at least this long ends the "day".
    public var dayBreak: TimeInterval
    public var minimumPartial: TimeInterval

    public init(interval: TimeInterval, dayBreak: TimeInterval, minimumPartial: TimeInterval) {
        self.interval = interval
        self.dayBreak = dayBreak
        self.minimumPartial = minimumPartial
    }

    public init(settings s: AtlasSettings) {
        self.init(interval: s.analysisIntervalSeconds, dayBreak: s.dayBreakSleepHours * 3600,
                  minimumPartial: s.minimumPartialMinutes * 60)
    }
}

public struct WindowAccrual: Sendable {
    /// The window that is now open (possibly a new one).
    public var open: AnalysisWindow
    /// Windows closed during this accrual, in order (status `ready` or `skipped`).
    public var closed: [AnalysisWindow]
}

/// Awake-time analysis windows.
///
/// A window is ready once it holds `interval` seconds of *awake* time — not wall-clock time.
/// Awake time is time whose state `countsAsAwake` (active, passive, idle, uncertain). System sleep,
/// lock and "away" do not advance the counter. Windows tile the timeline contiguously:
/// each window's end is exactly the next window's start, so no instant is lost or double-assigned.
public enum AwakeWindowManager {

    public static func newWindow(at start: Date) -> AnalysisWindow {
        AnalysisWindow(kind: .scheduled, start: start, accruedThrough: start, status: .open)
    }

    /// Advance `window` using timeline events up to `now`.
    /// `events` must cover [window.start, now] (events overlapping that range, any order).
    public static func accrue(window: AnalysisWindow, events: [ActivityEvent], through now: Date,
                              policy: WindowPolicy) -> WindowAccrual {
        precondition(window.status == .open)
        var open = window
        var closed: [AnalysisWindow] = []
        guard now > open.accruedThrough else { return WindowAccrual(open: open, closed: []) }

        let sorted = events.sorted { $0.start < $1.start }
        // Start of the current contiguous non-awake stretch (holes in the timeline count as non-awake).
        var runStart: Date? = nil
        var cursor = open.start

        func considerDayBreak(runFrom: Date, runTo: Date) {
            guard runTo.timeIntervalSince(runFrom) >= policy.dayBreak, open.awakeSeconds > 0 else { return }
            // Close at the start of the long non-awake stretch (the "end of day").
            let boundary = max(runFrom, open.start)
            var done = open
            done.end = boundary
            done.kind = .partial
            done.status = done.awakeSeconds >= policy.minimumPartial ? .ready : .skipped
            closed.append(done)
            open = newWindow(at: boundary)
            open.accruedThrough = max(boundary, min(runTo, now))
        }

        for e in sorted {
            guard let seg = e.clipped(from: open.start, to: now) else { continue }
            // Hole between the previous segment and this one: non-awake.
            if seg.start > cursor, runStart == nil { runStart = cursor }
            cursor = max(cursor, seg.end)

            if !seg.state.countsAsAwake {
                if runStart == nil { runStart = seg.start }
                considerDayBreak(runFrom: runStart!, runTo: seg.end)
                if open.accruedThrough < seg.end { open.accruedThrough = seg.end }
                continue
            }

            if let rs = runStart {
                considerDayBreak(runFrom: rs, runTo: seg.start)
                runStart = nil
            }

            // Count only the part not yet accrued.
            var from = max(seg.start, open.accruedThrough)
            let to = seg.end
            while from < to {
                let needed = policy.interval - open.awakeSeconds
                let available = to.timeIntervalSince(from)
                if available < needed {
                    open.awakeSeconds += available
                    open.accruedThrough = to
                    from = to
                } else {
                    let boundary = from.addingTimeInterval(needed)
                    var done = open
                    done.awakeSeconds = policy.interval
                    done.end = boundary
                    done.accruedThrough = boundary
                    done.status = .ready
                    closed.append(done)
                    open = newWindow(at: boundary)
                    from = boundary
                }
            }
        }
        // Trailing hole up to now.
        if cursor < now {
            let rs = runStart ?? cursor
            considerDayBreak(runFrom: rs, runTo: now)
        }
        open.accruedThrough = max(open.accruedThrough, min(now, max(cursor, open.start)))
        return WindowAccrual(open: open, closed: closed)
    }

    /// An ad-hoc window for manual analysis. It never alters the open scheduled window.
    public static func manualWindow(from: Date, to: Date, events: [ActivityEvent]) -> AnalysisWindow {
        let awake = events.compactMap { $0.clipped(from: from, to: to) }.filter { $0.state.countsAsAwake }
            .reduce(0) { $0 + $1.duration }
        return AnalysisWindow(kind: .manual, start: from, end: to, awakeSeconds: awake, accruedThrough: to, status: .ready)
    }

    /// Delay before retry `attempt` (1-based): base * 2^(attempt-1), capped at 6 hours, with ±10% jitter.
    public static func backoff(attempt: Int, base: TimeInterval, jitter: Double = Double.random(in: -0.1...0.1)) -> TimeInterval {
        let raw = base * pow(2, Double(max(0, attempt - 1)))
        return min(raw, 6 * 3600) * (1 + jitter)
    }
}
