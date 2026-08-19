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
