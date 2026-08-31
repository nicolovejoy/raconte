import XCTest
@testable import Raconte

/// #128 Task 1: the pure selection value type behind select mode in the library and
/// Trash screens. Every fixture here carries at least two ids — a one-element fixture
/// cannot catch an operation that ignores its argument (repo memory: vacuous fixtures
/// need an adversary, cardinality >= 2).
final class BulkSelectionTests: XCTestCase {

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    private let idC = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    func testStartsEmptyAndInactive() {
        let selection = BulkSelection()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
        XCTAssertFalse(selection.isActive)
        XCTAssertFalse(selection.isSelected(idA))
    }

    func testToggleSelectsExactlyTheGivenId() {
        var selection = BulkSelection()
        selection.toggle(idA)
        XCTAssertTrue(selection.isSelected(idA))
        XCTAssertFalse(selection.isSelected(idB), "toggling A must not select B")
        XCTAssertEqual(selection.count, 1)

        selection.toggle(idB)
        XCTAssertTrue(selection.isSelected(idA))
        XCTAssertTrue(selection.isSelected(idB))
        XCTAssertEqual(selection.count, 2)
    }

    func testTogglingTheSameIdTwiceDeselectsIt() {
        var selection = BulkSelection()
        selection.toggle(idA)
        selection.toggle(idB)
        selection.toggle(idA)
        XCTAssertFalse(selection.isSelected(idA))
        XCTAssertTrue(selection.isSelected(idB), "the second toggle of A must not touch B")
        XCTAssertEqual(selection.count, 1)
    }

    /// Select-all over a list that partially overlaps an existing selection: the result
    /// is the union — already-selected ids stay selected, nothing is double-counted.
    func testSelectAllUnionsWithAnExistingPartialSelection() {
        var selection = BulkSelection()
        selection.toggle(idA)
        selection.selectAll([idA, idB, idC])
        XCTAssertTrue(selection.isSelected(idA))
        XCTAssertTrue(selection.isSelected(idB))
        XCTAssertTrue(selection.isSelected(idC))
        XCTAssertEqual(selection.count, 3, "the overlap (idA) must not be counted twice")
    }

    /// "Select All" applies to what is on screen; an id selected earlier that has since
    /// left the screen (a filter change) survives — selectAll only ever adds.
    func testSelectAllDoesNotDropAnIdOutsideTheGivenList() {
        var selection = BulkSelection()
        selection.toggle(idC)
        selection.selectAll([idA, idB])
        XCTAssertTrue(selection.isSelected(idC))
        XCTAssertEqual(selection.count, 3)
    }

    func testClearEmptiesTheSelection() {
        var selection = BulkSelection()
        selection.selectAll([idA, idB])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
        XCTAssertFalse(selection.isSelected(idA))
        XCTAssertFalse(selection.isSelected(idB))
    }

    /// `clear()` clears the ids only — leaving or entering select MODE is the view's
    /// decision, made separately through `isActive`.
    func testClearLeavesTheModeFlagAlone() {
        var selection = BulkSelection()
        selection.isActive = true
        selection.toggle(idA)
        selection.toggle(idB)
        selection.clear()
        XCTAssertTrue(selection.isActive)
    }

    func testSortedIdsExposesTheSelectionDeterministically() {
        var selection = BulkSelection()
        selection.toggle(idB)
        selection.toggle(idA)
        XCTAssertEqual(selection.sortedIDs, [idA, idB])
    }
}
