import XCTest
@testable import Raconte

/// #139: journal rows sit under Capture as children of the list, and the owner wants
/// the hierarchy to read at a glance — an indent on the journal rows only.
final class SidebarRowInsetTests: XCTestCase {
    func testJournalRowsAreIndentedAndSystemRowsAreNot() {
        XCTAssertGreaterThan(SidebarRowView.leadingInset(isJournal: true), 0)
        XCTAssertEqual(SidebarRowView.leadingInset(isJournal: false), 0)
    }

    /// The rule must actually be applied to the row, or the test above pins nothing.
    func testTheRowAppliesTheInsetRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/App/SidebarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = strippingComments(source)
        XCTAssertTrue(code.contains("leadingInset(isJournal: row.journalID != nil)"),
                      "SidebarRowView must pad its title group by leadingInset(isJournal:)")
    }
}
