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
}
