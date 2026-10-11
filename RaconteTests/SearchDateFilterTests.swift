import XCTest
@testable import Raconte

/// #194: the search screen's date chip. Every bound is a unit, never an instant — the
/// same trap `JournalSpanTests` exists for.
final class SearchDateFilterTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent
    private var now: Date { date(2026, 10, 8, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0,
                      nanosecond: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min,
                                       second: s, nanosecond: nanosecond))!
    }

    func testLastDayOfThisYearIsInThisYear() {
        // The final half-second of the year: a bound faked by subtracting one second from
        // the next unit would leave it out.
        let lastInstant = date(2026, 12, 31, 23, 59, 59, nanosecond: 500_000_000)
        XCTAssertTrue(SearchDateFilter.thisYear.contains(date(2026, 12, 31, 12), calendar: cal, now: now))
        XCTAssertTrue(SearchDateFilter.thisYear.contains(lastInstant, calendar: cal, now: now))
        XCTAssertTrue(SearchDateFilter.thisYear.contains(date(2026, 1, 1), calendar: cal, now: now))
        XCTAssertFalse(SearchDateFilter.thisYear.contains(date(2027, 1, 1), calendar: cal, now: now))
        XCTAssertFalse(SearchDateFilter.thisYear.contains(date(2025, 12, 31, 23, 59, 59), calendar: cal, now: now))
    }

    func testLastYear() {
        XCTAssertTrue(SearchDateFilter.lastYear.contains(date(2025, 1, 1), calendar: cal, now: now))
        XCTAssertTrue(SearchDateFilter.lastYear.contains(date(2025, 12, 31, 23, 59, 59), calendar: cal, now: now))
        XCTAssertFalse(SearchDateFilter.lastYear.contains(date(2026, 1, 1), calendar: cal, now: now))
        XCTAssertFalse(SearchDateFilter.lastYear.contains(date(2024, 12, 31, 23, 59, 59), calendar: cal, now: now))
        // "Last year" follows `now`, not the year the test was written in.
        XCTAssertTrue(SearchDateFilter.lastYear.contains(date(1999, 6, 1), calendar: cal, now: date(2000, 3, 1)))
    }

    func testCustomYearPrecisionExpandsToTheWholeYear() {
        let f = SearchDateFilter.custom(from: PartialDate(year: 2024), to: PartialDate(year: 2024))
        XCTAssertTrue(f.contains(date(2024, 1, 1), calendar: cal, now: now))
        XCTAssertTrue(f.contains(date(2024, 12, 31, 23, 59, 59), calendar: cal, now: now))
        XCTAssertFalse(f.contains(date(2025, 1, 1), calendar: cal, now: now))
        XCTAssertFalse(f.contains(date(2023, 12, 31, 23, 59, 59), calendar: cal, now: now))
        // A month and a day expand the same way: February 2024 ends on the 29th.
        let month = SearchDateFilter.custom(from: PartialDate(year: 2024, month: 2),
                                            to: PartialDate(year: 2024, month: 2))
        XCTAssertTrue(month.contains(date(2024, 2, 29, 23, 59, 59), calendar: cal, now: now))
        XCTAssertFalse(month.contains(date(2024, 3, 1), calendar: cal, now: now))
        let day = SearchDateFilter.custom(from: PartialDate(year: 2024, month: 2, day: 10),
                                          to: PartialDate(year: 2024, month: 2, day: 10))
        XCTAssertTrue(day.contains(date(2024, 2, 10, 23, 59, 59), calendar: cal, now: now))
        XCTAssertFalse(day.contains(date(2024, 2, 11), calendar: cal, now: now))
    }

    func testOpenEndedCustom() {
        let fromOnly = SearchDateFilter.custom(from: PartialDate(year: 2020), to: nil)
        XCTAssertTrue(fromOnly.contains(date(2020, 1, 1), calendar: cal, now: now))
        XCTAssertTrue(fromOnly.contains(date(2031, 5, 5), calendar: cal, now: now))
        XCTAssertFalse(fromOnly.contains(date(2019, 12, 31, 23, 59, 59), calendar: cal, now: now))

        let toOnly = SearchDateFilter.custom(from: nil, to: PartialDate(year: 2020))
        XCTAssertTrue(toOnly.contains(date(1987, 3, 3), calendar: cal, now: now))
        XCTAssertTrue(toOnly.contains(date(2020, 12, 31, 23, 59, 59), calendar: cal, now: now))
        XCTAssertFalse(toOnly.contains(date(2021, 1, 1), calendar: cal, now: now))

        let neither = SearchDateFilter.custom(from: nil, to: nil)
        XCTAssertTrue(neither.contains(date(1987, 3, 3), calendar: cal, now: now))
        XCTAssertTrue(SearchDateFilter.anyTime.contains(date(1987, 3, 3), calendar: cal, now: now))
    }

    func testTitlesNameTheFilter() {
        XCTAssertEqual(SearchDateFilter.anyTime.title, "Any time")
        XCTAssertEqual(SearchDateFilter.thisYear.title, "This year")
        XCTAssertEqual(SearchDateFilter.lastYear.title, "Last year")
        XCTAssertEqual(SearchDateFilter.custom(from: nil, to: nil).title, "Custom")
        XCTAssertEqual(SearchDateFilter.custom(from: PartialDate(year: 2020), to: nil).title, "From 2020")
        XCTAssertEqual(SearchDateFilter.custom(from: nil, to: PartialDate(year: 2024)).title, "Until 2024")
        XCTAssertEqual(SearchDateFilter.custom(from: PartialDate(year: 2020), to: PartialDate(year: 2024)).title,
                       "2020 – 2024")
        XCTAssertEqual(SearchDateFilter.custom(from: PartialDate(year: 2024), to: PartialDate(year: 2024)).title,
                       "2024")
    }
}
