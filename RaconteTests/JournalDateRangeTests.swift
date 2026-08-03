import XCTest
@testable import Raconte

/// Issue #14 part 2: a journal's date range, derived from its entries — never stored.
final class JournalDateRangeTests: XCTestCase {

    /// `.current`, not a fixed UTC calendar — matches `EntryMetadataStoreTests`'s
    /// `PartialDate.formatted` convention. `formatted()` below calls straight into
    /// `Date.formatted`/`PartialDate.formatted`, both of which render in the system
    /// time zone, so pinning dates to a different zone here would make month/year
    /// boundaries disagree with what's under test.
    private var cal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    private func date(_ year: Int, _ month: Int = 6, _ day: Int = 15) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.timeZone = cal.timeZone
        return cal.date(from: comps)!
    }

    private func item(_ captureID: String, capturedAt: Date, originalDate: PartialDate? = nil,
                      trashedAt: Date? = nil) -> EntryListItem {
        EntryListItem(captureID: captureID, capturedAt: capturedAt,
                     metadata: EntryMetadata(originalDate: originalDate, trashedAt: trashedAt))
    }

    // MARK: compute

    func testEmptyJournalHasNoRange() {
        XCTAssertNil(JournalDateRange.compute(from: []))
    }

    func testSingleEntryIsAPointRange() {
        let range = JournalDateRange.compute(from: [item("A", capturedAt: date(2024, 3, 5))])
        XCTAssertEqual(range?.minDate, date(2024, 3, 5))
        XCTAssertEqual(range?.maxDate, date(2024, 3, 5))
    }

    func testMixedBackdatedAndNonBackdatedSpansEffectiveDates() {
        let backdate = PartialDate(year: 1987, month: 5, day: 1)
        let entries = [
            item("A", capturedAt: date(2026, 1, 1)),
            item("B", capturedAt: date(2026, 6, 1), originalDate: backdate),
        ]
        let range = JournalDateRange.compute(from: entries)
        XCTAssertEqual(range?.minDate, backdate.anchorDate(calendar: cal))
        XCTAssertEqual(range?.maxDate, date(2026, 1, 1))
    }

    /// A year-only backdate bounds the range at Jan 1 of that year — `effectiveDate`
    /// already normalizes it; this pins that the range computation doesn't re-derive.
    func testReducedPrecisionYearEntryBoundsAtJanuaryFirst() {
        let backdate = PartialDate(year: 1998)
        let entries = [item("A", capturedAt: date(2026, 6, 1), originalDate: backdate)]
        let range = JournalDateRange.compute(from: entries)
        XCTAssertEqual(range?.minDate, backdate.anchorDate(calendar: cal))
        XCTAssertEqual(range?.maxDate, backdate.anchorDate(calendar: cal))
        XCTAssertEqual(range?.minPrecision, .year)
    }

    func testTrashedEntriesDoNotContribute() {
        let entries = [
            item("A", capturedAt: date(2024, 1, 1)),
            item("B", capturedAt: date(1990, 1, 1), trashedAt: date(2026, 1, 1)),
        ]
        let range = JournalDateRange.compute(from: entries)
        XCTAssertEqual(range?.minDate, date(2024, 1, 1))
        XCTAssertEqual(range?.maxDate, date(2024, 1, 1))
    }

    func testAllTrashedIsAnEmptyJournal() {
        let entries = [item("A", capturedAt: date(2024, 1, 1), trashedAt: date(2026, 1, 1))]
        XCTAssertNil(JournalDateRange.compute(from: entries))
    }

    // MARK: formatted

    func testPointRangeUsesPrecisionAwareSingleDate() {
        let range = JournalDateRange(minDate: date(1998, 1, 1), minPrecision: .year,
                                     maxDate: date(1998, 1, 1), maxPrecision: .year)
        XCTAssertEqual(range.formatted(calendar: cal), "1998")
    }

    func testSameYearDifferentMonthsCollapsesToMonthRange() {
        let range = JournalDateRange(minDate: date(1998, 3, 1), minPrecision: .day,
                                     maxDate: date(1998, 7, 20), maxPrecision: .day)
        XCTAssertEqual(range.formatted(calendar: cal), "March – July 1998")
    }

    func testSameYearSameMonthCollapsesToOneMonth() {
        let range = JournalDateRange(minDate: date(1998, 3, 1), minPrecision: .day,
                                     maxDate: date(1998, 3, 20), maxPrecision: .day)
        XCTAssertEqual(range.formatted(calendar: cal), "March 1998")
    }

    func testMultiYearCollapsesToYearRange() {
        let range = JournalDateRange(minDate: date(1998, 3, 1), minPrecision: .day,
                                     maxDate: date(2003, 7, 20), maxPrecision: .day)
        XCTAssertEqual(range.formatted(calendar: cal), "1998–2003")
    }

    /// FIX 5: a `.year`-precision bound never contributes a month it doesn't have. A
    /// year-only 1998 entry alongside a July 1998 day entry must not fabricate
    /// "January – July 1998" — January was never said.
    func testYearPrecisionBoundCollapsesToYearEvenWithinOneCalendarYear() {
        let range = JournalDateRange(minDate: date(1998, 1, 1), minPrecision: .year,
                                     maxDate: date(1998, 7, 20), maxPrecision: .day)
        XCTAssertEqual(range.formatted(calendar: cal), "1998")
    }

    func testYearPrecisionBoundCollapsesToYearRangeAcrossYears() {
        let range = JournalDateRange(minDate: date(1998, 1, 1), minPrecision: .year,
                                     maxDate: date(2003, 7, 20), maxPrecision: .day)
        XCTAssertEqual(range.formatted(calendar: cal), "1998–2003")
    }

    /// When the range collapses to a point but the two bounds disagree on precision
    /// (a tie in `compute`'s min/max tracking), the coarser precision wins — it's the
    /// honest description of what's actually known about that instant.
    func testPointRangeWithDifferingPrecisionsUsesTheCoarserOne() {
        let range = JournalDateRange(minDate: date(1998, 1, 1), minPrecision: .day,
                                     maxDate: date(1998, 1, 1), maxPrecision: .year)
        XCTAssertEqual(range.formatted(calendar: cal), "1998")
    }
}
