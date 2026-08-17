import XCTest
@testable import Raconte

@MainActor
final class PlaceRoutingTests: XCTestCase {

    private func journal(_ id: String, _ name: String) -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    // Cardinality ≥ 2 on purpose: one journal cannot distinguish "a row per journal"
    // from "a row for the first journal".
    func testRowsAreCaptureThenEveryJournalThenAllEntriesThenTrash() {
        let rows = SidebarModel.rows(journals: [journal("j1", "1987"), journal("j2", "France")],
                                     dateRanges: ["j1": "1987"],
                                     includesDebug: false)
        XCTAssertEqual(rows.map(\.place),
                       [.capture, .journal("j1"), .journal("j2"), .allEntries, .trash])
        XCTAssertEqual(rows[1].title, "1987")
        XCTAssertEqual(rows[1].subtitle, "1987")
        XCTAssertNil(rows[2].subtitle, "a journal with no entries shows no range, not an empty one")
        XCTAssertEqual(rows[1].journalID, "j1")
        XCTAssertNil(rows[0].journalID, "only journal rows draw a cover")
    }

    func testDebugRowIsLastAndOnlyWhenIncluded() {
        let without = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
        XCTAssertFalse(without.contains { $0.place == .debug })
        let with = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        XCTAssertEqual(with.last?.place, .debug)
    }

    func testEveryRowCarriesItsOwnIdentifier() {
        let rows = SidebarModel.rows(journals: [journal("j1", "1987"), journal("j2", "France")],
                                     dateRanges: [:], includesDebug: true)
        XCTAssertEqual(Set(rows.map(\.accessibilityIdentifier)).count, rows.count,
                       "two rows sharing an identifier makes every UI test that taps one ambiguous")
        XCTAssertEqual(rows.first { $0.place == .journal("j2") }?.accessibilityIdentifier,
                       "sidebar.journal.j2")
        XCTAssertEqual(rows.first { $0.place == .trash }?.accessibilityIdentifier, "sidebar.trash")
    }

    func testSwitchingPlacesClearsTheDetailPath() {
        let path: [LibraryDestination] = [.entry("A"), .entry("B")]
        XCTAssertEqual(PlaceRouting.detailPath(afterSelecting: .trash, from: .allEntries, path: path),
                       [])
    }

    func testReselectingTheSamePlaceKeepsTheDetailPath() {
        let path: [LibraryDestination] = [.entry("A")]
        XCTAssertEqual(PlaceRouting.detailPath(afterSelecting: .capture, from: .capture, path: path),
                       path,
                       "tapping the place you are already in must not throw away where you are")
    }

    func testAJournalPlaceForAMissingJournalFallsBackToCapture() {
        XCTAssertEqual(PlaceRouting.resolve(.journal("gone"), journals: [journal("j1", "1987")]),
                       .capture)
        XCTAssertEqual(PlaceRouting.resolve(.journal("j1"), journals: [journal("j1", "1987")]),
                       .journal("j1"))
    }

    func testJournalScopePerPlace() {
        XCTAssertEqual(PlaceRouting.journalScope(for: .allEntries), .all)
        XCTAssertEqual(PlaceRouting.journalScope(for: .journal("j1")), .journal("j1"))
        XCTAssertNil(PlaceRouting.journalScope(for: .capture))
        XCTAssertNil(PlaceRouting.journalScope(for: .trash))
        XCTAssertNil(PlaceRouting.journalScope(for: .debug))
    }

    func testRouterLaunchesOnCapture() {
        XCTAssertEqual(AppRouter().place, .capture)
        XCTAssertTrue(AppRouter().detailPath.isEmpty)
    }

    func testRouterGoBackPopsOnceAndIsSafeWhenEmpty() {
        let router = AppRouter()
        router.detailPath = [.entry("A"), .entry("B")]
        XCTAssertTrue(router.canGoBack)
        router.goBack()
        XCTAssertEqual(router.detailPath, [.entry("A")])
        router.goBack()
        XCTAssertFalse(router.canGoBack)
        router.goBack()                       // must not trap
        XCTAssertEqual(router.detailPath, [])
    }

    // Pins the WIRING, not just the pure `PlaceRouting.detailPath` it calls — reducing
    // `select` to `self.place = place` (dropping the clear rule entirely) or emptying
    // the body (dropping the place update too) must both fail this.
    func testSelectingADifferentPlaceClearsThePathAndUpdatesPlace() {
        let router = AppRouter()
        router.place = .allEntries
        router.detailPath = [.entry("A"), .entry("B")]
        router.select(.trash)
        XCTAssertEqual(router.place, .trash)
        XCTAssertEqual(router.detailPath, [])
    }

    func testReselectingTheSamePlaceOnTheRouterKeepsThePath() {
        let router = AppRouter()
        router.place = .capture
        router.detailPath = [.entry("A")]
        router.select(.capture)
        XCTAssertEqual(router.place, .capture)
        XCTAssertEqual(router.detailPath, [.entry("A")],
                       "tapping the place you are already in must not throw away where you are")
    }

    // Table-driven over every fixed (non-journal) row so a single-field typo or a
    // whole-row corruption anywhere in the locked list is caught in one assertion,
    // rather than relying on scattered single-field checks elsewhere in this file.
    func testFixedRowsMatchTheLockedTitlesSymbolsAndIdentifiers() {
        let rows = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        let expected: [(place: Place, title: String, systemImage: String?, accessibilityIdentifier: String)] = [
            (.capture, "Capture", "mic.circle", "sidebar.capture"),
            (.allEntries, "All Entries", "books.vertical", "sidebar.allEntries"),
            (.trash, "Trash", "trash", "sidebar.trash"),
            (.debug, "Debug", "ladybug", "sidebar.debug"),
        ]
        for expectation in expected {
            guard let row = rows.first(where: { $0.place == expectation.place }) else {
                XCTFail("missing row for \(expectation.place)")
                continue
            }
            XCTAssertEqual(row.title, expectation.title, "\(expectation.place) title")
            XCTAssertEqual(row.systemImage, expectation.systemImage, "\(expectation.place) systemImage")
            XCTAssertEqual(row.accessibilityIdentifier, expectation.accessibilityIdentifier,
                           "\(expectation.place) accessibilityIdentifier")
        }
    }
}
