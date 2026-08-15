import XCTest
@testable import Raconte

/// Issue #48 follow-up (owner ask 2026-08-14): the weekday moved out of a standalone
/// caption row and into the nav title itself, so it reads "up there" next to the date
/// instead of buried below the (now-removed) redundant "Entry date" row. Pins the pure
/// composition `EntryDetailView.navigationTitleText`, same reasoning as
/// `EntryDetailViewBackdateAffordanceTests`.
final class EntryDetailViewNavigationTitleTests: XCTestCase {

    private func item(originalDate: PartialDate?) -> EntryListItem {
        EntryListItem(captureID: "A", capturedAt: Date(timeIntervalSince1970: 1_000),
                     metadata: EntryMetadata(originalDate: originalDate))
    }

    func testNoBackdateShowsPlainDateNoWeekday() {
        let entry = item(originalDate: nil)
        XCTAssertNil(entry.weekdayText())
        XCTAssertEqual(EntryDetailView.navigationTitleText(for: entry), entry.formattedEffectiveDate())
    }

    /// Day-precision backdate composes as "<weekday>, <date>" — which weekday is
    /// `PartialDateTests`' job, this only pins the composition rule.
    func testDayPrecisionBackdatePrependsWeekday() throws {
        let entry = item(originalDate: PartialDate(year: 1998, month: 3, day: 4))
        let weekday = try XCTUnwrap(entry.weekdayText())
        XCTAssertEqual(EntryDetailView.navigationTitleText(for: entry),
                       "\(weekday), \(entry.formattedEffectiveDate())")
    }

    /// Coarser backdates have no day to name a weekday for (issue #48) — title stays
    /// plain, same as the no-backdate case.
    func testCoarserBackdatePrecisionsShowPlainDate() {
        for date in [PartialDate(year: 1998), PartialDate(year: 1998, month: 3)] {
            let entry = item(originalDate: date)
            XCTAssertNil(entry.weekdayText())
            XCTAssertEqual(EntryDetailView.navigationTitleText(for: entry), entry.formattedEffectiveDate())
        }
    }
}
