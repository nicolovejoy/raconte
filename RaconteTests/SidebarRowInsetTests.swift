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

    // MARK: - Sidebar containment (#67 item 3): the tick-rate read moved out

    /// `CaptureLiveBadge` is the only view that may read `.elapsed`; `SidebarView` must
    /// no longer re-evaluate once per second while a capture is running. A source pin,
    /// not a behavioral test — SwiftUI's fine-grained `@Observable` invalidation isn't
    /// otherwise directly assertable from XCTest.
    func testSidebarViewNoLongerReadsElapsedAndTheBadgeDoes() throws {
        func source(_ relativePath: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // RaconteTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent(relativePath)
            return strippingComments(try String(contentsOf: url, encoding: .utf8))
        }

        let sidebarView = try source("Raconte/App/SidebarView.swift")
        XCTAssertFalse(sidebarView.contains(".elapsed"),
                       "SidebarView must not read .elapsed itself — CaptureLiveBadge owns that read")

        let badge = try source("Raconte/App/CaptureLiveBadge.swift")
        XCTAssertTrue(badge.contains(".elapsed"),
                      "CaptureLiveBadge must be the view that reads .elapsed")
    }
}
