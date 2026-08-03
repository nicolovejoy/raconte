import XCTest
@testable import Raconte

/// M3 T3: the pure "which journal does capture file into" decision. Covers the owner's
/// default-journal rule (first launch → auto-create "Journal") and the dangling-selection
/// case (T1's `CurrentJournal.resolve` semantics) without touching disk or UserDefaults.
final class JournalSelectionTests: XCTestCase {

    private func journal(_ id: String, _ name: String = "J") -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    func test_emptyRegistry_noStoredID_needsDefault() {
        let outcome = JournalSelection.resolve(registry: JournalRegistry(), storedID: nil)
        XCTAssertEqual(outcome, .needsDefault)
    }

    func test_emptyRegistry_withStaleStoredID_stillNeedsDefault() {
        // A stored id from a wiped registry (or a different device's install) cannot
        // resolve against nothing — falling back to "create a default" is the only
        // option that avoids "no journal selected".
        let outcome = JournalSelection.resolve(registry: JournalRegistry(), storedID: "stale-id")
        XCTAssertEqual(outcome, .needsDefault)
    }

    func test_storedID_matchesExisting_selectsIt() {
        let registry = JournalRegistry(journals: [journal("a"), journal("b")])
        let outcome = JournalSelection.resolve(registry: registry, storedID: "b")
        XCTAssertEqual(outcome, .existing("b"))
    }

    func test_storedID_nil_fallsBackToFirstJournal() {
        let registry = JournalRegistry(journals: [journal("a"), journal("b")])
        let outcome = JournalSelection.resolve(registry: registry, storedID: nil)
        XCTAssertEqual(outcome, .existing("a"))
    }

    func test_storedID_dangling_fallsBackToFirstJournal() {
        // The dangling-selection case: a journal that existed when the id was stored is
        // gone now (T1's `CurrentJournal.resolve` never clears the stored id itself —
        // that's a separate concern from what capture should file into today).
        let registry = JournalRegistry(journals: [journal("a"), journal("b")])
        let outcome = JournalSelection.resolve(registry: registry, storedID: "deleted-id")
        XCTAssertEqual(outcome, .existing("a"))
    }
}
