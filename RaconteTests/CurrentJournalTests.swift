import XCTest
@testable import Raconte

/// M3 T1: the current-journal preference.
final class CurrentJournalTests: XCTestCase {

    private func journal(_ id: String, _ name: String = "J") -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSelectionPersistsAndResolvesAgainstTheRegistry() {
        let prefs = InMemoryJournalPreferenceStore()
        let registry = JournalRegistry(journals: [journal("A"), journal("B", "Trip")])

        let current = CurrentJournal(store: prefs)
        XCTAssertNil(current.storedID)
        XCTAssertNil(current.resolve(in: registry))

        current.select(journal("B", "Trip"))
        // A separate instance over the same storage — this is a persisted preference.
        XCTAssertEqual(CurrentJournal(store: prefs).resolve(in: registry)?.name, "Trip")
        XCTAssertEqual(CurrentJournal(store: prefs).storedID, "B")
    }

    func testDanglingIDResolvesToNilWithoutErasingTheStoredValue() {
        let prefs = InMemoryJournalPreferenceStore()
        let current = CurrentJournal(store: prefs)
        current.select("GONE")
        XCTAssertNil(current.resolve(in: JournalRegistry(journals: [journal("A")])))
        XCTAssertEqual(current.storedID, "GONE", "kept — the journal may arrive via sync")
        XCTAssertEqual(current.resolve(in: JournalRegistry(journals: [journal("GONE", "Back")]))?.name,
                       "Back")
    }

    func testSelectingNilClearsTheStoredValue() {
        let prefs = InMemoryJournalPreferenceStore()
        let current = CurrentJournal(store: prefs)
        current.select("A")
        current.select(nil)
        XCTAssertNil(current.storedID)
    }

    func testEmptyStoredValueIsTreatedAsUnset() {
        let prefs = InMemoryJournalPreferenceStore(values: [CurrentJournal.defaultsKey: ""])
        XCTAssertNil(CurrentJournal(store: prefs).storedID)
    }

    func testRealUserDefaultsBackingRoundTrips() throws {
        let suiteName = "RaconteCurrentJournalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let current = CurrentJournal(store: UserDefaultsJournalPreferenceStore(defaults: defaults))
        current.select("A")
        XCTAssertEqual(defaults.string(forKey: CurrentJournal.defaultsKey), "A")
        XCTAssertEqual(current.storedID, "A")
        current.select(nil)
        XCTAssertNil(defaults.string(forKey: CurrentJournal.defaultsKey))
    }
}
