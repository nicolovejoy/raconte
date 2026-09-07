import XCTest
@testable import Raconte

/// Spec: "the span the PAPER journal covers, as its owner knows it".
///
/// THE TRAP THIS FILE EXISTS FOR: `PartialDate` is `Comparable` by `anchorDate`, which
/// fills absent components with the FIRST — "2001" anchors to 1 Jan 2001. So a naive
/// `start <= d && d <= end` would call every entry after 1 Jan 2001 out-of-range for a
/// journal spanning "1998 – 2001". Each endpoint must expand to its precision's UNIT:
/// start to the earliest instant of that unit, end to the LATEST.
final class JournalSpanTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// Exact-instant construction (down to a sub-second) for boundary tests, where a
    /// noon-anchored fixture is nowhere near the edge and can't discriminate an
    /// off-by-one in the bound math.
    private func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int,
                          nanosecond: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min,
                                       second: s, nanosecond: nanosecond))!
    }

    // MARK: Validation

    func testInvertedSpanIsRejected() {
        XCTAssertThrowsError(try JournalSpan(start: PartialDate(year: 2001),
                                             end: PartialDate(year: 1998))) { error in
            XCTAssertEqual(error as? JournalSpanError, .inverted)
        }
    }

    func testOpenEndedSpanIsAllowed() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertNil(span.end)
    }

    /// Construction-only: for a single precision, `lowerBound(x)` and `upperBound(x)`
    /// are never equal (a day/month/year always has positive duration), so this test
    /// cannot discriminate `>` from `>=` in the inversion check. It pins only that a
    /// same-value span is accepted, not any boundary-comparison behaviour — see the
    /// dedicated boundary tests below for that.
    func testEqualEndpointsAreAllowed() throws {
        _ = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 1998))
    }

    /// Inversion is judged at the COARSEST common precision: "Mar 1998" to "1998" is not
    /// inverted, because the end bound means "the end of 1998", which is after March.
    func testMixedPrecisionEndIsNotInvertedWhenItsUnitExtendsPastTheStart() throws {
        _ = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                            end: PartialDate(year: 1998))
    }

    // MARK: Containment — the whole point

    func testYearPrecisionEndBoundCoversTheWholeYear() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        XCTAssertTrue(span.contains(date(2001, 12, 31), calendar: cal),
                      "an end bound of \"2001\" means 31 Dec 2001, not 1 Jan")
        XCTAssertTrue(span.contains(date(1998, 1, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(2002, 1, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1997, 12, 31), calendar: cal))
    }

    func testMonthPrecisionEndBoundCoversTheWholeMonth() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 1998, month: 8))
        XCTAssertTrue(span.contains(date(1998, 8, 31), calendar: cal))
        XCTAssertTrue(span.contains(date(1998, 3, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 9, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 2, 28), calendar: cal))
    }

    func testDayPrecisionBoundsAreInclusive() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3, day: 4),
                                   end: PartialDate(year: 1998, month: 3, day: 6))
        XCTAssertTrue(span.contains(date(1998, 3, 4), calendar: cal))
        XCTAssertTrue(span.contains(date(1998, 3, 6), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 3, 7), calendar: cal))
    }

    func testOpenEndedSpanContainsEverythingAfterItsStart() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertTrue(span.contains(date(2026, 8, 18), calendar: cal))
        XCTAssertFalse(span.contains(date(1997, 12, 31), calendar: cal))
    }

    func testLeapDayIsInsideAFebruaryMonthBound() throws {
        let span = try JournalSpan(start: PartialDate(year: 2024, month: 2),
                                   end: PartialDate(year: 2024, month: 2))
        XCTAssertTrue(span.contains(date(2024, 2, 29), calendar: cal),
                      "a month bound must expand to that month's real length")
    }

    // MARK: Boundary precision — the noon fixtures above can't catch an off-by-one, so
    // these are anchored at exact instants: the last sub-second inside a unit, the first
    // instant of the following unit, and the corresponding pair at the start bound.

    func testLastInstantInsideAYearEndBoundIsContained() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 1998))
        XCTAssertTrue(span.contains(instant(1998, 12, 31, 23, 59, 59, nanosecond: 999_000_000),
                                     calendar: cal))
    }

    func testFirstInstantOutsideAYearEndBoundIsExcluded() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 1998))
        XCTAssertFalse(span.contains(instant(1999, 1, 1, 0, 0, 0), calendar: cal))
    }

    func testLastInstantInsideAMonthEndBoundIsContained() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 1998, month: 3))
        XCTAssertTrue(span.contains(instant(1998, 3, 31, 23, 59, 59, nanosecond: 999_000_000),
                                     calendar: cal))
    }

    func testFirstInstantOutsideAMonthEndBoundIsExcluded() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 1998, month: 3))
        XCTAssertFalse(span.contains(instant(1998, 4, 1, 0, 0, 0), calendar: cal))
    }

    func testLastInstantInsideADayEndBoundIsContained() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3, day: 4),
                                   end: PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertTrue(span.contains(instant(1998, 3, 4, 23, 59, 59, nanosecond: 999_000_000),
                                     calendar: cal))
    }

    func testFirstInstantOutsideADayEndBoundIsExcluded() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3, day: 4),
                                   end: PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertFalse(span.contains(instant(1998, 3, 5, 0, 0, 0), calendar: cal))
    }

    func testFirstInstantOfStartBoundIsContained() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertTrue(span.contains(instant(1998, 1, 1, 0, 0, 0), calendar: cal))
    }

    func testInstantImmediatelyBeforeStartBoundIsExcluded() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertFalse(span.contains(instant(1997, 12, 31, 23, 59, 59, nanosecond: 999_000_000),
                                      calendar: cal))
    }

    // MARK: flags(_:_:calendar:) — #71, owner ruling 4 (2026-08-18): flagged, never
    // blocked. A nil span makes no claim, so nothing in it is ever flagged.

    func testFlagsIsFalseWhenSpanIsNil() {
        XCTAssertFalse(JournalSpan.flags(nil, date(2001, 1, 1), calendar: cal))
    }

    func testFlagsIsFalseWhenDateIsInsideTheSpan() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001))
        XCTAssertFalse(JournalSpan.flags(span, date(1999, 6, 1), calendar: cal))
    }

    func testFlagsIsTrueWhenDateIsBeforeTheSpanStart() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001))
        XCTAssertTrue(JournalSpan.flags(span, date(1997, 12, 31), calendar: cal))
    }

    func testFlagsIsFalseForAnOpenEndedSpanAfterItsStart() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertFalse(JournalSpan.flags(span, date(2026, 8, 18), calendar: cal))
    }

    /// Reuses the containment boundary fixture above: the last sub-second of a
    /// year-precision end bound must not be flagged.
    func testFlagsYearPrecisionEndCoversTheLastInstantOfTheYear() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001))
        XCTAssertFalse(JournalSpan.flags(span, instant(2001, 12, 31, 23, 59, 59, nanosecond: 999_000_000),
                                          calendar: cal))
    }

    // MARK: formatted

    func testFormattedOpenEndedSpanShowsStartWithATrailingDash() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertEqual(span.formatted(calendar: cal), "1998 –")
    }

    func testFormattedClosedSpanShowsBothEndpoints() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 2001))
        XCTAssertEqual(span.formatted(calendar: cal), "1998 – 2001")
    }

    func testFormattedMixedPrecisionSpanUsesEachEndpointsOwnPrecision() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 2001))
        XCTAssertEqual(span.formatted(calendar: cal), "March 1998 – 2001")
    }

    func testFormattedSameValueStartAndEndCollapsesToOneDate() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 1998))
        XCTAssertEqual(span.formatted(calendar: cal), "1998")
    }

    // MARK: Codable

    func testCodableRoundTripsAsTwoPartialDateStrings() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 2001))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(span)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"end":"2001","start":"1998-03"}"#)
        XCTAssertEqual(try JSONDecoder().decode(JournalSpan.self, from: data), span)
    }

    func testOpenEndedSpanOmitsTheEndKey() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(span)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"start":"1998"}"#)
    }

    func testDecodingAnInvertedSpanThrows() {
        let data = Data(#"{"start":"2001","end":"1998"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JournalSpan.self, from: data),
                             "the invariant must hold for values that arrive off disk too")
    }
}
