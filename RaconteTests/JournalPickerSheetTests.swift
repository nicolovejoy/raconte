import XCTest
@testable import Raconte

final class JournalPickerSheetTests: XCTestCase {
    func testDateLineAndCountJoined() {
        XCTAssertEqual(
            JournalPickerSheet.rowSubtitle(dateLine: "Jun – Aug 2026", entryCount: 41),
            "Jun – Aug 2026 · 41 entries")
    }

    func testNilDateLineAndNilCountIsEmpty() {
        XCTAssertEqual(JournalPickerSheet.rowSubtitle(dateLine: nil, entryCount: nil), "")
    }

    func testSingularEntryCount() {
        XCTAssertEqual(
            JournalPickerSheet.rowSubtitle(dateLine: "1987", entryCount: 1),
            "1987 · 1 entry")
    }

    func testDateLineOnlyWhenCountAbsent() {
        XCTAssertEqual(
            JournalPickerSheet.rowSubtitle(dateLine: "1987", entryCount: nil),
            "1987")
    }

    func testCountOnlyWhenDateLineAbsent() {
        XCTAssertEqual(
            JournalPickerSheet.rowSubtitle(dateLine: nil, entryCount: 3),
            "3 entries")
    }

    func testSingularCountOnlyWhenDateLineAbsent() {
        XCTAssertEqual(
            JournalPickerSheet.rowSubtitle(dateLine: nil, entryCount: 1),
            "1 entry")
    }
}
