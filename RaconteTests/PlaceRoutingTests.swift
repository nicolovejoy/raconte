import XCTest
@testable import Raconte

@MainActor
final class PlaceRoutingTests: XCTestCase {

    private func journal(_ id: String, _ name: String,
                        createdAt: Date = Date(timeIntervalSince1970: 0)) -> Journal {
        Journal(id: id, name: name, createdAt: createdAt)
    }

    // Cardinality ≥ 2 on purpose: one journal cannot distinguish "a row per journal"
    // from "a row for the first journal". Journals are fed in REVERSE createdAt order
    // (#79) — the insertion-order journal array does not already happen to match
    // display order, so this actually pins `SidebarModel.rows` sorting rather than
    // passing by coincidence.
    func testRowsAreCaptureThenEveryJournalInDisplayOrderThenAllEntriesThenTrash() {
        let older = journal("j1", "1987", createdAt: Date(timeIntervalSince1970: 100))
        let newer = journal("j2", "France", createdAt: Date(timeIntervalSince1970: 200))
        let rows = SidebarModel.rows(journals: [newer, older],
                                     dateRanges: ["j1": "1987"],
                                     includesDebug: false)
        XCTAssertEqual(rows.map(\.place),
                       [.home, .capture, .journal("j1"), .journal("j2"), .allEntries, .trash, .about],
                       "j1 (older) must render before j2 (newer) despite arriving second")
        XCTAssertEqual(rows[2].title, "1987")
        XCTAssertEqual(rows[2].subtitle, "1987")
        XCTAssertNil(rows[3].subtitle, "a journal with no entries shows no range, not an empty one")
        XCTAssertEqual(rows[2].journalID, "j1")
        XCTAssertNil(rows[1].journalID, "only journal rows draw a cover")
    }

    func testDebugRowIsLastAndOnlyWhenIncluded() {
        let without = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
        XCTAssertFalse(without.contains { $0.place == .debug })
        XCTAssertEqual(without.last?.place, .about, "#89: About is last when Debug is not listed")
        let with = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        XCTAssertEqual(with.last?.place, .debug)
        XCTAssertEqual(with.dropLast().last?.place, .about, "#89: About sits between Trash and Debug")
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

    func testReselectingTheSamePlacePopsTheDetailPathToRoot() {
        let path: [LibraryDestination] = [.entry("A")]
        XCTAssertEqual(PlaceRouting.detailPath(afterSelecting: .capture, from: .capture, path: path),
                       [],
                       "re-selecting the place you're already in pops to its root — the universal "
                       + "sidebar idiom, and what makes ⌘1-4 do something when Capture has a pushed "
                       + "recent-row or receipt-open entry under it")
    }

    func testAJournalPlaceForAMissingJournalFallsBackToCapture() {
        XCTAssertEqual(PlaceRouting.resolve(.journal("gone"), journals: [journal("j1", "1987")]),
                       .capture)
        XCTAssertEqual(PlaceRouting.resolve(.journal("j1"), journals: [journal("j1", "1987")]),
                       .journal("j1"))
    }

    func testAboutResolvesToItself() {
        XCTAssertEqual(PlaceRouting.resolve(.about, journals: []), .about)
    }

    // #67 item 2: a background journals pull (CloudKit) must not pop the entry the
    // owner is reading. `resolve` alone can't express this — it always lands
    // `.capture` for a vanished journal, which is right when nothing was pushed but
    // wrong once a pushed `.entry` exists, because `select`-shaped rerouting always
    // clears the path. `reroute` carries the path decision `resolve` cannot.

    func testRerouteLeavesAPresentJournalAndItsPathAlone() {
        let path: [LibraryDestination] = [.entry("A")]
        let r = PlaceRouting.reroute(.journal("j1"), journals: [journal("j1", "1987")], detailPath: path)
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .journal("j1"), detailPath: path))
    }

    func testRerouteWithAnEmptyPathMatchesTheExistingCaptureFallback() {
        let r = PlaceRouting.reroute(.journal("gone"), journals: [journal("j1", "1987")], detailPath: [])
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .capture, detailPath: []),
                       "must match PlaceRouting.resolve's .capture fallback (testAJournalPlace…) "
                       + "when nothing was pushed")
    }

    func testRerouteWithAPushedEntryGoesToAllEntriesAndKeepsThePath() {
        let path: [LibraryDestination] = [.entry("A")]
        let r = PlaceRouting.reroute(.journal("gone"), journals: [journal("j1", "1987")], detailPath: path)
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .allEntries, detailPath: path),
                       "the journal vanished but the entry the owner is reading still exists — land "
                       + "on All Entries (which contains it, now unfiled) rather than popping them out")
    }

    // The doc comment on `Reroute` used to claim a pushed path always survives because
    // "the entry still exists (now unfiled) and All Entries contains it" — false for a
    // path ending in `.journalEditor(J)` where J is the journal that vanished: that
    // screen is now editing nothing. Only a path ending in `.entry(...)` survives.

    func testRerouteWithAPushedJournalEditorForTheVanishedJournalClearsThePath() {
        let path: [LibraryDestination] = [.journalEditor("gone")]
        let r = PlaceRouting.reroute(.journal("gone"), journals: [journal("j1", "1987")], detailPath: path)
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .capture, detailPath: []),
                       "a journal editor pushed for the journal that just vanished is a dead screen, "
                       + "not a survivor — it must clear exactly like the empty-path fallback")
    }

    func testRerouteWithAnEntryThenAJournalEditorOnTopStillClearsThePath() {
        let path: [LibraryDestination] = [.entry("A"), .journalEditor("gone")]
        let r = PlaceRouting.reroute(.journal("gone"), journals: [journal("j1", "1987")], detailPath: path)
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .capture, detailPath: []),
                       "only the LAST element of the path decides survival — an .entry lower in the "
                       + "stack does not rescue a .journalEditor pushed on top of it")
    }

    func testRerouteOnAPlaceThatNeverVanishesIsUnaffectedByAPushedPath() {
        let path: [LibraryDestination] = [.entry("A")]
        let r = PlaceRouting.reroute(.allEntries, journals: [], detailPath: path)
        XCTAssertEqual(r, PlaceRouting.Reroute(place: .allEntries, detailPath: path))
    }

    func testJournalScopePerPlace() {
        XCTAssertEqual(PlaceRouting.journalScope(for: .allEntries), .all)
        XCTAssertEqual(PlaceRouting.journalScope(for: .journal("j1")), .journal("j1"))
        XCTAssertNil(PlaceRouting.journalScope(for: .capture))
        XCTAssertNil(PlaceRouting.journalScope(for: .trash))
        XCTAssertNil(PlaceRouting.journalScope(for: .about))
        XCTAssertNil(PlaceRouting.journalScope(for: .debug))
    }

    func testRouterLaunchesOnHome() {
        // #108: Home replaces Capture as PlaceRouting.launchPlace.
        XCTAssertEqual(AppRouter().place, .home)
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

    // Cardinality ≥ 2: a non-empty path proves the pop actually happens; an
    // already-empty path proves re-selecting is a true no-op (place unchanged, no
    // spurious churn) rather than something that only happens to look right when the
    // path was empty to begin with.
    func testReselectingTheSamePlaceOnTheRouterPopsToRoot() {
        let router = AppRouter()
        router.place = .capture
        router.detailPath = [.entry("A")]
        router.select(.capture)
        XCTAssertEqual(router.place, .capture)
        XCTAssertEqual(router.detailPath, [],
                       "re-selecting the current place must pop to root — on Mac this is what ⌘1-4 "
                       + "do, and a Capture place with a pushed recent-row/receipt entry under it "
                       + "must not be a dead click")
    }

    func testReselectingTheSamePlaceWithAnAlreadyEmptyPathIsANoOp() {
        let router = AppRouter()
        router.place = .capture
        router.detailPath = []
        router.select(.capture)
        XCTAssertEqual(router.place, .capture)
        XCTAssertEqual(router.detailPath, [])
    }

    // Table-driven over every fixed (non-journal) row so a single-field typo or a
    // whole-row corruption anywhere in the locked list is caught in one assertion,
    // rather than relying on scattered single-field checks elsewhere in this file.
    // #108: Home is the first row, ahead of Capture — reachable via the sidebar this
    // task, launch place itself flips in Task 3.
    func testSidebarRowsListHomeFirst() {
        let rows = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
        XCTAssertEqual(rows.first?.place, .home)
        XCTAssertEqual(rows.first?.accessibilityIdentifier, "sidebar.home")
        XCTAssertEqual(rows.map(\.place).prefix(2), [.home, .capture])
    }

    func testResolveHomeIsIdentity() {
        XCTAssertEqual(PlaceRouting.resolve(.home, journals: []), .home)
    }

    func testHomeHasNoJournalScope() {
        XCTAssertNil(PlaceRouting.journalScope(for: .home))
    }

    func testFixedRowsMatchTheLockedTitlesSymbolsAndIdentifiers() {
        let rows = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        let expected: [(place: Place, title: String, systemImage: String?, accessibilityIdentifier: String)] = [
            (.home, "Home", "house", "sidebar.home"),
            (.capture, "Capture", "mic.circle", "sidebar.capture"),
            (.allEntries, "All Entries", "books.vertical", "sidebar.allEntries"),
            (.trash, "Trash", "trash", "sidebar.trash"),
            (.about, "About", "info.circle", "sidebar.about"),
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
