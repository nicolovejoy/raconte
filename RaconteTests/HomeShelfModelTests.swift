import XCTest
@testable import Raconte

/// #108 Home bookshelf: the pure ranking model behind the face-out / spine split.
final class HomeShelfModelTests: XCTestCase {

    // Journals created in display order A, B, C (strictly increasing createdAt so
    // displayOrdered is deterministic — advance the date between mints, never reuse
    // one Date; ULID ties at equal ms are a coin flip).
    private func makeJournal(_ name: String, createdAt: Date) -> Journal {
        Journal(id: ULID.make(), name: name, createdAt: createdAt)
    }

    private func makeItem(journalID: String?, capturedAt: Date) -> EntryListItem {
        var item = EntryListItem(captureID: ULID.make(), capturedAt: capturedAt)
        item.journalID = journalID
        return item
    }

    func testRanksJournalsByNewestCaptureActivity() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)
        let c = makeJournal("C", createdAt: t + 2)

        // A's newest entry: t+1. B's newest: t+30 (B also has an OLDER t+2 entry —
        // proves "newest per journal", not "any entry"). C's newest: t+10.
        // Expect faceOut order (limit 3): [B, C, A].
        let entries = [
            makeItem(journalID: a.id, capturedAt: t + 1),
            makeItem(journalID: b.id, capturedAt: t + 30),
            makeItem(journalID: b.id, capturedAt: t + 2),
            makeItem(journalID: c.id, capturedAt: t + 10),
        ]

        let shelf = HomeShelf.make(journals: [a, b, c], entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["B", "C", "A"])
        XCTAssertEqual(shelf.spines, [])
        XCTAssertEqual(shelf.lastActivity[a.id], t + 1)
        XCTAssertEqual(shelf.lastActivity[b.id], t + 30)
        XCTAssertEqual(shelf.lastActivity[c.id], t + 10)
    }

    func testFaceOutLimitSplitsIntoSpines() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let journals = (0..<5).map { makeJournal("J\($0)", createdAt: t + Double($0)) }
        // 5 journals with strictly descending activity; limit 3 →
        // faceOut == first 3 by activity, spines == remaining 2, still
        // activity-ordered.
        let entries = journals.enumerated().map { index, journal in
            makeItem(journalID: journal.id, capturedAt: t + 100 - Double(index))
        }

        let shelf = HomeShelf.make(journals: journals, entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["J0", "J1", "J2"])
        XCTAssertEqual(shelf.spines.map(\.name), ["J3", "J4"])
    }

    func testJournalsWithNoEntriesRankLastInDisplayOrder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)
        let c = makeJournal("C", createdAt: t + 2)

        // A (no entries), B (one entry), C (no entries) → [B, A, C]:
        // B first, then the empty ones in display order. lastActivity has no
        // key for A or C.
        let entries = [makeItem(journalID: b.id, capturedAt: t + 5)]

        let shelf = HomeShelf.make(journals: [a, b, c], entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["B", "A", "C"])
        XCTAssertNil(shelf.lastActivity[a.id])
        XCTAssertNil(shelf.lastActivity[c.id])
        XCTAssertEqual(shelf.lastActivity[b.id], t + 5)
    }

    func testBackdatingDoesNotReorder() {
        // Both journals' capturedAt live in the same modern range (2026) so the
        // backdate below actively OPPOSES capture order — an implementation that
        // (wrongly) ranked by effectiveDate would flip to [B, A] here, catching the
        // bug a same-decade backdate would miss.
        let t = Date(timeIntervalSince1970: 1_770_000_000) // ~2026
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)

        // A's entry captured t+20 (2026) but with originalDate backdated to 2020 —
        // EARLIER than B's own capturedAt. B's entry captured t+10 (2026), no
        // backdate. Capture-time ranking keeps A first; effectiveDate ranking would
        // put B first.
        var aEntry = makeItem(journalID: a.id, capturedAt: t + 20)
        aEntry.originalDate = PartialDate(year: 2020, month: 1, day: 1)
        let bEntry = makeItem(journalID: b.id, capturedAt: t + 10)

        let shelf = HomeShelf.make(journals: [a, b], entries: [aEntry, bEntry], faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["A", "B"])
    }

    func testFewerJournalsThanLimitMeansNoSpines() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)

        // 2 journals, limit 3 → both faceOut, spines empty.
        let shelf = HomeShelf.make(journals: [a, b], entries: [], faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["A", "B"])
        XCTAssertEqual(shelf.spines, [])
    }

    func testEntriesWithDanglingOrNilJournalIDCountForNoJournal() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)

        // One entry with journalID nil, one with a ULID matching no journal;
        // both journals A and B are otherwise empty → ranking falls back to
        // display order [A, B], lastActivity empty.
        let entries = [
            makeItem(journalID: nil, capturedAt: t + 5),
            makeItem(journalID: ULID.make(), capturedAt: t + 6),
        ]

        let shelf = HomeShelf.make(journals: [a, b], entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["A", "B"])
        XCTAssertTrue(shelf.lastActivity.isEmpty)
    }

    func testActivityTieBreaksByDisplayOrder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = makeJournal("A", createdAt: t)
        let b = makeJournal("B", createdAt: t + 1)

        // A and B each newest-active at the SAME Date instance → [A, B]
        // (display order), deterministically.
        let shared = t + 50
        let entries = [
            makeItem(journalID: a.id, capturedAt: shared),
            makeItem(journalID: b.id, capturedAt: shared),
        ]

        let shelf = HomeShelf.make(journals: [a, b], entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut.map(\.name), ["A", "B"])
    }

    func testZeroJournalsProducesEmptyShelf() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Fresh install / all-journals-deleted edge case: an entry can still exist
        // with a journalID that matches no journal (same fallback as the
        // dangling-journalID case above) — must not crash, must produce an empty
        // shelf in every dimension.
        let entries = [makeItem(journalID: ULID.make(), capturedAt: t)]

        let shelf = HomeShelf.make(journals: [], entries: entries, faceOutLimit: 3)
        XCTAssertEqual(shelf.faceOut, [])
        XCTAssertEqual(shelf.spines, [])
        XCTAssertTrue(shelf.lastActivity.isEmpty)
    }
}
