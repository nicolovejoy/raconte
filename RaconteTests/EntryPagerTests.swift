import XCTest
@testable import Raconte

/// #101: the paging pure core. `orderedIDs` is `LibraryScreenModel.items` order —
/// newest FIRST — so previous = index-1 (toward newer) and next = index+1 (toward
/// older). These tests pin that direction mapping; getting it backwards inverts
/// every control in the UI.
@MainActor
final class EntryPagerTests: XCTestCase {

    private let ids = ["newest", "middle", "oldest"]

    // MARK: neighborID

    func testMiddleEntryHasBothNeighborsWithTheLockedDirectionMapping() {
        XCTAssertEqual(EntryPager.neighborID(of: "middle", in: ids, direction: .previous),
                       "newest", "previous must move toward the top (newer) of the list")
        XCTAssertEqual(EntryPager.neighborID(of: "middle", in: ids, direction: .next),
                       "oldest", "next must move toward the bottom (older) of the list")
    }

    func testFirstEntryHasNoPreviousAndLastHasNoNext() {
        XCTAssertNil(EntryPager.neighborID(of: "newest", in: ids, direction: .previous))
        XCTAssertEqual(EntryPager.neighborID(of: "newest", in: ids, direction: .next), "middle")
        XCTAssertNil(EntryPager.neighborID(of: "oldest", in: ids, direction: .next))
        XCTAssertEqual(EntryPager.neighborID(of: "oldest", in: ids, direction: .previous), "middle")
    }

    func testAbsentIDAndEmptyListProduceNoNeighbor() {
        XCTAssertNil(EntryPager.neighborID(of: "gone", in: ids, direction: .next),
                     "an entry that left the list's scope pages nowhere — both ends disable")
        XCTAssertNil(EntryPager.neighborID(of: "anything", in: [], direction: .previous))
    }

    // MARK: pagingTarget (the whole gate in one place)

    func testPagingTargetRequiresAScopedPlaceAndAnEntryOnTop() {
        let path: [LibraryDestination] = [.entry("middle")]
        XCTAssertEqual(EntryPager.pagingTarget(place: .allEntries, detailPath: path,
                                               orderedIDs: ids, direction: .next), "oldest")
        XCTAssertEqual(EntryPager.pagingTarget(place: .journal("j1"), detailPath: path,
                                               orderedIDs: ids, direction: .previous), "newest")
        XCTAssertNil(EntryPager.pagingTarget(place: .capture, detailPath: path,
                                             orderedIDs: ids, direction: .next),
                     "capture-pushed details have no 'list you came from' — no paging")
        XCTAssertNil(EntryPager.pagingTarget(place: .trash, detailPath: path,
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .about, detailPath: path,
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .debug, detailPath: path,
                                             orderedIDs: ids, direction: .next))
    }

    func testPagingTargetRefusesNonEntryTops() {
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries, detailPath: [],
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries,
                                             detailPath: [.journalEditor("j1")],
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries,
                                             detailPath: [.entry("middle"), .journalEditor("j1")],
                                             orderedIDs: ids, direction: .next),
                     "only the TOP of the path pages; an editor above the entry blocks it")
    }

    // MARK: AppRouter.replaceTopEntry

    func testReplaceTopEntrySwapsOnlyAnEntryTop() {
        let router = AppRouter()
        router.detailPath = [.entry("A")]
        router.replaceTopEntry(with: "B")
        XCTAssertEqual(router.detailPath, [.entry("B")])

        router.detailPath = [.entry("A"), .journalEditor("j1")]
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [.entry("A"), .journalEditor("j1")],
                       "a non-entry top is never replaced")

        router.detailPath = []
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [], "an empty path is a no-op, never a crash")
    }

    func testReplaceTopEntryPreservesTheRestOfThePath() {
        let router = AppRouter()
        router.detailPath = [.entry("A"), .entry("B")]
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [.entry("A"), .entry("C")],
                       "only the top element turns; anything beneath it stays")
    }
}
