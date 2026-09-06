import XCTest
@testable import Raconte

/// M3 issue #14 part 2: the string-backed partial date that replaces `Date? +
/// DatePrecision?` for `originalDate` — parsing, formatting, the anchor rule, ordering,
/// and precision derivation.
final class PartialDateTests: XCTestCase {

    private var cal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    // MARK: Parse / format round trip

    func testDayPrecisionRoundTrips() throws {
        let parsed = try PartialDate(parsing: "1998-03-04")
        XCTAssertEqual(parsed, PartialDate(year: 1998, month: 3, day: 4))
        XCTAssertEqual(parsed.isoString, "1998-03-04")
        XCTAssertEqual(parsed.precision, .day)
    }

    func testYearMonthPrecisionRoundTrips() throws {
        let parsed = try PartialDate(parsing: "1998-03")
        XCTAssertEqual(parsed, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(parsed.isoString, "1998-03")
        XCTAssertEqual(parsed.precision, .yearMonth)
    }

    func testYearPrecisionRoundTrips() throws {
        let parsed = try PartialDate(parsing: "1998")
        XCTAssertEqual(parsed, PartialDate(year: 1998))
        XCTAssertEqual(parsed.isoString, "1998")
        XCTAssertEqual(parsed.precision, .year)
    }

    // MARK: Rejection

    func testRejectsUnpaddedMonth() {
        XCTAssertThrowsError(try PartialDate(parsing: "1998-3"))
    }

    func testRejectsUnpaddedDay() {
        XCTAssertThrowsError(try PartialDate(parsing: "1998-03-4"))
    }

    func testRejectsOutOfRangeMonth() {
        XCTAssertThrowsError(try PartialDate(parsing: "1998-13-01"))
        XCTAssertThrowsError(try PartialDate(parsing: "1998-00-01"))
    }

    func testRejectsInvalidDayForMonth() {
        XCTAssertThrowsError(try PartialDate(parsing: "1998-02-30"))
        XCTAssertThrowsError(try PartialDate(parsing: "1998-04-31"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try PartialDate(parsing: "not-a-date"))
        XCTAssertThrowsError(try PartialDate(parsing: ""))
        XCTAssertThrowsError(try PartialDate(parsing: "1998-03-04T00:00:00Z"))
        XCTAssertThrowsError(try PartialDate(parsing: "1998-03-04-05"))
    }

    // MARK: Codable (single JSON string)

    func testCodableRoundTripsAsAPlainString() throws {
        let value = PartialDate(year: 1998, month: 3, day: 4)
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""1998-03-04""#)
        let decoded = try JSONDecoder().decode(PartialDate.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testDecodeThrowsOnMalformedString() {
        let data = Data(#""1998-3""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PartialDate.self, from: data))
    }

    // MARK: Anchor rule

    func testAnchorFillsMissingMonthAndDayAtNoon() {
        let year = PartialDate(year: 1998)
        let expected = cal.date(from: DateComponents(year: 1998, month: 1, day: 1, hour: 12))!
        XCTAssertEqual(year.anchorDate(calendar: cal), expected)

        let yearMonth = PartialDate(year: 1998, month: 6)
        let expectedMonth = cal.date(from: DateComponents(year: 1998, month: 6, day: 1, hour: 12))!
        XCTAssertEqual(yearMonth.anchorDate(calendar: cal), expectedMonth)
    }

    func testAnchorOfADayPrecisionValueSitsAtNoonThatDay() {
        let day = PartialDate(year: 1998, month: 6, day: 15)
        let expected = cal.date(from: DateComponents(year: 1998, month: 6, day: 15, hour: 12))!
        XCTAssertEqual(day.anchorDate(calendar: cal), expected)
    }

    // MARK: init(from:precision:calendar:)

    func testTruncatingInitDropsComponentsBelowPrecision() {
        let midMonth = cal.date(from: DateComponents(year: 1987, month: 6, day: 15, hour: 14))!
        XCTAssertEqual(PartialDate(from: midMonth, precision: .day, calendar: cal),
                       PartialDate(year: 1987, month: 6, day: 15))
        XCTAssertEqual(PartialDate(from: midMonth, precision: .yearMonth, calendar: cal),
                       PartialDate(year: 1987, month: 6))
        XCTAssertEqual(PartialDate(from: midMonth, precision: .year, calendar: cal),
                       PartialDate(year: 1987))
    }

    // MARK: Comparable

    func testOrdersByYearThenMonthThenDay() {
        let year = PartialDate(year: 1998)
        let yearMonth = PartialDate(year: 1998, month: 3)
        let day = PartialDate(year: 1998, month: 3, day: 4)
        let laterYear = PartialDate(year: 1999)
        XCTAssertLessThan(year, yearMonth)
        XCTAssertLessThan(yearMonth, day)
        XCTAssertLessThan(day, laterYear)
    }

    func testSortIsStableAcrossMixedPrecisions() {
        let values = [PartialDate(year: 2000), PartialDate(year: 1998, month: 6, day: 1),
                      PartialDate(year: 1998, month: 3)]
        XCTAssertEqual(values.sorted(), [
            PartialDate(year: 1998, month: 3),
            PartialDate(year: 1998, month: 6, day: 1),
            PartialDate(year: 2000),
        ])
    }

    // MARK: Precision derivation

    func testPrecisionDerivesFromWhichComponentsArePresent() {
        XCTAssertEqual(PartialDate(year: 1998).precision, .year)
        XCTAssertEqual(PartialDate(year: 1998, month: 3).precision, .yearMonth)
        XCTAssertEqual(PartialDate(year: 1998, month: 3, day: 4).precision, .day)
    }

    // MARK: isFuture (disallow-future-backdates)
    //
    // Fixed "now" of June 15, 2026 — deliberately clear of any year boundary, per the
    // house rule that backdate fixtures near Jan 1 have broken CI under UTC before.

    private var referenceNow: Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }

    func testTodayAtDayPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 2026, month: 6, day: 15).isFuture(now: referenceNow, calendar: cal))
    }

    func testTomorrowAtDayPrecisionIsFuture() {
        XCTAssertTrue(PartialDate(year: 2026, month: 6, day: 16).isFuture(now: referenceNow, calendar: cal))
    }

    func testYesterdayAtDayPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 2026, month: 6, day: 14).isFuture(now: referenceNow, calendar: cal))
    }

    func testCurrentMonthAtYearMonthPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 2026, month: 6).isFuture(now: referenceNow, calendar: cal))
    }

    func testNextMonthAtYearMonthPrecisionIsFuture() {
        XCTAssertTrue(PartialDate(year: 2026, month: 7).isFuture(now: referenceNow, calendar: cal))
    }

    func testPreviousMonthAtYearMonthPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 2026, month: 5).isFuture(now: referenceNow, calendar: cal))
    }

    func testCurrentYearAtYearPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 2026).isFuture(now: referenceNow, calendar: cal))
    }

    func testNextYearAtYearPrecisionIsFuture() {
        XCTAssertTrue(PartialDate(year: 2027).isFuture(now: referenceNow, calendar: cal))
    }

    func testPastYearAtYearPrecisionIsNotFuture() {
        XCTAssertFalse(PartialDate(year: 1998).isFuture(now: referenceNow, calendar: cal))
    }

    /// A future day within the *current* month must not be masked by the month-level
    /// comparison — day precision compares day-for-day, not just year+month.
    func testLaterDayInCurrentMonthIsFutureEvenThoughSameMonth() {
        XCTAssertTrue(PartialDate(year: 2026, month: 6, day: 30).isFuture(now: referenceNow, calendar: cal))
    }

    // MARK: formatted

    func testFormattedRendersByPrecision() {
        XCTAssertEqual(PartialDate(year: 1998).formatted(calendar: cal), "1998")
        XCTAssertEqual(PartialDate(year: 1998, month: 3).formatted(calendar: cal), "March 1998")
        let dayText = PartialDate(year: 1998, month: 3, day: 4).formatted(calendar: cal)
        XCTAssertTrue(dayText.contains("1998"))
        XCTAssertTrue(dayText.contains("4") || dayText.contains("04"))
    }

    // MARK: weekdayText (issue #48)
    //
    // March 4, 1998 is deliberately clear of any year boundary (house rule — backdate
    // fixtures near Jan 1 have broken CI under UTC before). It was a Wednesday.

    func testWeekdayTextIsPresentOnlyAtDayPrecision() {
        let day = PartialDate(year: 1998, month: 3, day: 4)
        let yearMonth = PartialDate(year: 1998, month: 3)
        let year = PartialDate(year: 1998)
        XCTAssertNotNil(day.weekdayText(calendar: cal))
        XCTAssertNil(yearMonth.weekdayText(calendar: cal),
                     "anchorDate's day-1 fill would fabricate a weekday nobody wrote down")
        XCTAssertNil(year.weekdayText(calendar: cal))
    }

    /// Names the actual weekday, computed via an independent Calendar path (component +
    /// `weekdaySymbols`, not `Date.FormatStyle`) so a hardcoded or off-by-one production
    /// answer is caught rather than just "some non-nil string".
    func testWeekdayTextNamesTheActualDay() {
        let day = PartialDate(year: 1998, month: 3, day: 4)
        let weekdayIndex = cal.component(.weekday, from: day.anchorDate(calendar: cal))
        let expectedWide = cal.weekdaySymbols[weekdayIndex - 1]
        let expectedAbbreviated = cal.shortWeekdaySymbols[weekdayIndex - 1]
        XCTAssertEqual(day.weekdayText(style: .wide, calendar: cal), expectedWide)
        XCTAssertEqual(day.weekdayText(calendar: cal), expectedAbbreviated,
                       "default style must be abbreviated for the library row")
    }

    // MARK: nextDay (#47)

    func testNextDayAdvancesADayPrecisionValue() {
        XCTAssertEqual(PartialDate(year: 1987, month: 6, day: 12).nextDay(calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(PartialDate(year: 1987, month: 12, day: 31).nextDay(calendar: .gregorianCurrent),
                       PartialDate(year: 1988, month: 1, day: 1))
    }

    func testNextDayIsNilBelowDayPrecision() {
        XCTAssertNil(PartialDate(year: 1987, month: 6).nextDay(calendar: .gregorianCurrent))
        XCTAssertNil(PartialDate(year: 1987).nextDay(calendar: .gregorianCurrent))
    }
}
