import XCTest
@testable import Raconte

/// Spec ruling 3: stored wins when set; derived is the fallback. Never a union — a union
/// silently invents a span nobody typed and hides the disagreement.
final class JournalDateLineTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    func testStoredSpanWinsOverTheDerivedRange() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: derived, calendar: cal),
                       span.formatted(calendar: cal),
                       "a half-read 1998 journal must not advertise itself as Aug 2026")
    }

    func testDerivedRangeIsUsedWhenNoSpanIsSet() {
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: cal),
                       derived.formatted(calendar: cal))
    }

    func testSpanWinsEvenWhenThereAreNoEntriesAtAll() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: nil, calendar: cal),
                       span.formatted(calendar: cal),
                       "an untranscribed journal still knows what it covers")
    }

    func testNothingToSayReturnsNil() {
        XCTAssertNil(JournalDateLine.text(span: nil, derived: nil, calendar: cal))
    }

    /// Task 4 fix round 1, Minor: every other test in this file passes `.gregorianCurrent`
    /// — `text`'s own default — so none of them can tell "forwards the argument" apart
    /// from "always uses `.gregorianCurrent` internally and ignores what it was handed".
    /// Discriminates by comparing two calendars that are guaranteed to disagree on the
    /// YEAR NUMBER for the same instant (Gregorian vs. Hebrew — centuries apart), both
    /// pinned to a fixed (non-"current") time zone so the result is machine-independent.
    /// Exercises the `derived` branch specifically: `JournalDateRange.formatted`'s
    /// non-point path (`minDate != maxDate`) reads `calendar.component(.year, from:)`
    /// directly, with no `PartialDate`/`anchorDate` round trip to cancel the difference
    /// back out (a point-precision fixture very nearly would — the round trip re-derives
    /// an instant close to the original, which a Gregorian-default display formatter
    /// then reports the same either way).
    func testCalendarArgumentIsThreadedThroughRatherThanHardcoded() {
        var gregorianUTC = Calendar(identifier: .gregorian)
        gregorianUTC.timeZone = TimeZone(identifier: "UTC")!
        var hebrewUTC = Calendar(identifier: .hebrew)
        hebrewUTC.timeZone = TimeZone(identifier: "UTC")!

        // Same day, an hour apart — same year in either calendar, so the range collapses
        // to a single year number rather than a "min–max" span, keeping the expected
        // strings simple.
        let minDate = Date(timeIntervalSince1970: 0)
        let maxDate = Date(timeIntervalSince1970: 3_600)
        let derived = JournalDateRange(minDate: minDate, minPrecision: .year,
                                       maxDate: maxDate, maxPrecision: .year)

        let expectedGregorian = derived.formatted(calendar: gregorianUTC)
        let expectedHebrew = derived.formatted(calendar: hebrewUTC)
        XCTAssertNotEqual(expectedGregorian, expectedHebrew,
                          "sanity check on the fixture itself: Gregorian and Hebrew must "
                          + "disagree on the year number here, or this test proves nothing")

        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: gregorianUTC),
                       expectedGregorian)
        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: hebrewUTC),
                       expectedHebrew,
                       "a hardcoded .gregorianCurrent inside JournalDateLine.text would "
                       + "report the Gregorian year here regardless of what was passed in")
    }
}
