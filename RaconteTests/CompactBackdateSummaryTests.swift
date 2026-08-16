import XCTest
@testable import Raconte

/// Approach 2 of the 2026-08-16 capture-interface IA discussion: bounded content (the
/// journal name, the backdate) must never need its own scroll region during a capture —
/// only the transcript is genuinely unbounded. `CompactBackdateSummary` is the one-line,
/// non-scrolling stand-in for the full `BackdateField` while recording; this pins its pure
/// text logic, the same "pull the string out so a test can call it directly" pattern
/// `EntryDetailView.navigationTitleText` already uses.
final class CompactBackdateSummaryTests: XCTestCase {

    private var cal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    func testNotBackdatedReadsAsNotBackdated() {
        XCTAssertEqual(
            CompactBackdateSummary.summaryText(enabled: false, date: Date(), precision: .day,
                                               calendar: cal),
            "Not backdated")
    }

    /// Disabled always wins, regardless of what stale date/precision is sitting in the
    /// model — the toggle is the source of truth, not "is there a date value at all".
    func testDisabledIgnoresWhateverDateIsCarried() {
        let date = PartialDate(year: 1998, month: 3, day: 4).anchorDate(calendar: cal)
        XCTAssertEqual(
            CompactBackdateSummary.summaryText(enabled: false, date: date, precision: .day,
                                               calendar: cal),
            "Not backdated")
    }

    func testBackdatedAtDayPrecisionNamesTheDate() {
        let date = PartialDate(year: 1998, month: 3, day: 4).anchorDate(calendar: cal)
        let text = CompactBackdateSummary.summaryText(enabled: true, date: date, precision: .day,
                                                       calendar: cal)
        XCTAssertTrue(text.hasPrefix("Backdated to "), text)
        XCTAssertTrue(text.contains("1998"), text)
    }

    /// A precision coarser than day must not leak the anchor's fabricated day-1 into the
    /// summary — the same class of bug `PartialDate.anchorDate`'s doc comment warns every
    /// consumer about. Regressing this would silently say "Backdated to March 1, 1998" for
    /// a year-month backdate.
    func testBackdatedAtYearMonthPrecisionOmitsTheFabricatedDay() {
        let date = PartialDate(year: 1998, month: 3).anchorDate(calendar: cal)
        let text = CompactBackdateSummary.summaryText(enabled: true, date: date,
                                                       precision: .yearMonth, calendar: cal)
        XCTAssertEqual(text, "Backdated to \(PartialDate(year: 1998, month: 3).formatted(calendar: cal))")
    }

    func testBackdatedAtYearPrecisionOmitsMonthAndDay() {
        let date = PartialDate(year: 1998).anchorDate(calendar: cal)
        XCTAssertEqual(
            CompactBackdateSummary.summaryText(enabled: true, date: date, precision: .year,
                                               calendar: cal),
            "Backdated to \(PartialDate(year: 1998).formatted(calendar: cal))")
    }
}
