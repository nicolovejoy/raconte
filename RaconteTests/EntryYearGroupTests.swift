import XCTest
@testable import Raconte

/// M3 T4: the pure year-grouping the library screen sorts rows into.
final class EntryYearGroupTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func item(_ captureID: String, year: Int, month: Int = 6, day: Int = 15) -> EntryListItem {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.timeZone = utc.timeZone
        let date = utc.date(from: comps)!
        return EntryListItem(captureID: captureID, capturedAt: date)
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertEqual(EntryListItem.groupedByYear([], calendar: utc), [])
    }

    func testSingleYearProducesOneGroupPreservingOrder() {
        let items = [item("A", year: 2024, month: 3), item("B", year: 2024, month: 1)]
        let groups = EntryListItem.groupedByYear(items, calendar: utc)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].year, 2024)
        XCTAssertEqual(groups[0].items.map(\.captureID), ["A", "B"])
    }

    func testDescendingYearsProduceDescendingGroups() {
        let items = [item("A", year: 2025), item("B", year: 2025), item("C", year: 2020)]
        let groups = EntryListItem.groupedByYear(items, calendar: utc)
        XCTAssertEqual(groups.map(\.year), [2025, 2020])
        XCTAssertEqual(groups[0].items.map(\.captureID), ["A", "B"])
        XCTAssertEqual(groups[1].items.map(\.captureID), ["C"])
    }

    /// A backdated entry groups by `effectiveDate` (the backdate), not `capturedAt` — the
    /// whole point of "grouped by year" is that an entry read aloud from a 1987 paper
    /// journal sorts under 1987, not under the afternoon it was recorded.
    func testGroupsByEffectiveDateNotCapturedAt() {
        var backdated = item("A", year: 2026)
        backdated.originalDate = PartialDate(year: 1987, month: 5, day: 1)

        let groups = EntryListItem.groupedByYear([backdated], calendar: utc)
        XCTAssertEqual(groups.map(\.year), [1987])
    }

    /// Same year, non-contiguous input (unsorted) splits into separate groups rather than
    /// merging — the function documents this as a linear pass over already-sorted input,
    /// not a full grouping.
    func testNonContiguousSameYearSplitsIntoSeparateGroups() {
        let items = [item("A", year: 2024), item("B", year: 2023), item("C", year: 2024)]
        let groups = EntryListItem.groupedByYear(items, calendar: utc)
        XCTAssertEqual(groups.map(\.year), [2024, 2023, 2024])
    }
}
