@testable import AtlasCore
import XCTest

final class CheckinPlanTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }()
    // Monday 26 Oct 2026, local.
    func at(_ h: Int, _ m: Int = 2, day: Int = 26) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }

    func testRunsOnlyInChosenHours() {
        let p = CheckinPlan()
        XCTAssertTrue(p.decide(at: at(12), lastCheckin: nil, calendar: cal).proceed)
        XCTAssertFalse(p.decide(at: at(13), lastCheckin: nil, calendar: cal).proceed)
    }

    func testWeekdays() {
        var p = CheckinPlan(); p.weekdays = [2, 3, 4, 5, 6]          // Mon–Fri
        XCTAssertTrue(p.decide(at: at(9), lastCheckin: nil, calendar: cal).proceed)
        XCTAssertFalse(p.decide(at: at(9, day: 25), lastCheckin: nil, calendar: cal).proceed)   // Sunday
    }

    func testPauseSkipAndDuplicate() {
        var p = CheckinPlan()
        p.pausedUntil = at(14, 0)
        XCTAssertFalse(p.decide(at: at(12), lastCheckin: nil, calendar: cal).proceed)
        XCTAssertTrue(p.decide(at: at(15), lastCheckin: nil, calendar: cal).proceed)
        p.pausedUntil = nil
        p.skippedSlot = at(15, 0)
        XCTAssertFalse(p.decide(at: at(15), lastCheckin: nil, calendar: cal).proceed)
        XCTAssertTrue(p.decide(at: at(18), lastCheckin: nil, calendar: cal).proceed)
        // A manual check-in at 11:40 makes the 12:00 one redundant.
        XCTAssertFalse(p.decide(at: at(12, 3), lastCheckin: at(11, 40), calendar: cal).proceed)
        XCTAssertTrue(p.decide(at: at(12, 3), lastCheckin: at(11, 40), manual: true, calendar: cal).proceed)
    }

    func testNextSlotRespectsPauseAndSkip() {
        var p = CheckinPlan()
        XCTAssertEqual(p.next(after: at(12, 30), calendar: cal), at(15, 0))
        p.skippedSlot = at(15, 0)
        XCTAssertEqual(p.next(after: at(12, 30), calendar: cal), at(18, 0))
        p.pausedUntil = at(20, 0)
        XCTAssertEqual(p.next(after: at(12, 30), calendar: cal), at(21, 0))
        p.hours = []
        XCTAssertNil(p.next(after: at(12, 30), calendar: cal))
    }
}
