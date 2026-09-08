import XCTest
@testable import Raconte

/// #163: the Trash screen's unreadable-entries block is visually its own thing — tinted
/// ground, warning bar, count in the header — while the ordinary trash rows stay plain.
/// Pinned at the source level (comment-stripped) because SwiftUI's row background is not
/// reachable from XCUITest.
final class TrashUnreadableSectionSourceTests: XCTestCase {

    private func trashSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/Library/UI/TrashView.swift")
        return strippingComments(try String(contentsOf: url))
    }

    /// The block between the section's opening and the `trash.unreadable.section` header
    /// identifier carries the barred background and the count; the bar and inset ground
    /// themselves live in `unreadableRowBackground`'s own body, which sits AFTER this range
    /// (declared below `unreadableSection`) — checked separately below.
    func testTheUnreadableBlockIsTintedBarredAndCounted() throws {
        let source = try trashSource()
        guard let start = source.range(of: "private var unreadableSection"),
              let header = source.range(of: "trash.unreadable.section", range: start.upperBound..<source.endIndex) else {
            return XCTFail("unreadableSection or its header identifier is gone")
        }
        let block = source[start.upperBound..<header.lowerBound]
        XCTAssertTrue(block.contains(".listRowBackground(unreadableRowBackground)"),
                      "unreadable rows sit on the barred background")
        XCTAssertTrue(block.contains("Unreadable entries · \\(model.unreadableEntries.count)"),
                      "the header carries the count")
    }

    /// `unreadableRowBackground`'s own body carries the warning bar and the inset ground
    /// it sits next to.
    func testTheUnreadableRowBackgroundIsBarredAndInset() throws {
        let source = try trashSource()
        guard let start = source.range(of: "private var unreadableRowBackground"),
              let end = source.range(of: "private func unreadableRow", range: start.upperBound..<source.endIndex) else {
            return XCTFail("unreadableRowBackground or unreadableRow is gone")
        }
        let block = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(block.contains("InkTone.warning.color"), "a warning bar marks the block")
        XCTAssertTrue(block.contains("InkTone.paperInset.color"), "the background's ground is inset")
    }

    /// The ordinary trash rows keep the plain ground: the tint must not leak.
    func testTheOrdinaryTrashRowsAreNotTinted() throws {
        let source = try trashSource()
        guard let row = source.range(of: "struct TrashEntryRow") else {
            return XCTFail("TrashEntryRow is gone")
        }
        let rowRegion = source[row.upperBound...]
        XCTAssertFalse(rowRegion.contains(".listRowBackground(unreadableRowBackground)"),
                       "the barred background belongs to the unreadable block only")
        XCTAssertFalse(rowRegion.contains("InkTone.paperInset.color"),
                       "the inset ground belongs to the unreadable block only")
    }
}
