import XCTest
@testable import Raconte

/// M3 T2, pure half: dates, order, filters and the snippet. No filesystem — every rule
/// the library screens depend on is decidable from values alone.
final class EntryListItemTests: XCTestCase {

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func item(_ id: String,
                      capturedAt: Double,
                      journalID: String? = nil,
                      originalDate: Double? = nil,
                      trashedAt: Double? = nil,
                      journal: Journal? = nil,
                      snippet: String? = nil,
                      transcript: EntryTranscriptState = .absent,
                      degradations: EntryDegradation = []) -> EntryListItem {
        EntryListItem(
            captureID: id,
            capturedAt: date(capturedAt),
            durationSeconds: 1,
            metadata: EntryMetadata(journalID: journalID,
                                    originalDate: originalDate.map(date),
                                    trashedAt: trashedAt.map(date)),
            journal: journal,
            snippet: snippet,
            transcript: transcript,
            degradations: degradations)
    }

    // MARK: effectiveDate

    func testEffectiveDateIsCapturedAtWhenNotBackdated() {
        let entry = item("A", capturedAt: 1_000)
        XCTAssertEqual(entry.effectiveDate, date(1_000))
        XCTAssertNil(entry.originalDate)
        XCTAssertFalse(entry.isBackdated)
    }

    func testEffectiveDateIsTheBackdateWhenSet() {
        let entry = item("A", capturedAt: 1_000, originalDate: 10)
        XCTAssertEqual(entry.effectiveDate, date(10))
        XCTAssertEqual(entry.capturedAt, date(1_000), "capturedAt is never rewritten by a backdate")
        XCTAssertTrue(entry.isBackdated)
    }

    /// The rule is defined once, in `EntryMetadata`. This pins the item to it so the two
    /// cannot drift into disagreeing about what a library row is sorted by.
    func testEffectiveDateAgreesWithEntryMetadata() {
        for original in [nil, 10.0, 5_000.0] as [Double?] {
            let metadata = EntryMetadata(originalDate: original.map(date))
            let entry = EntryListItem(captureID: "A", capturedAt: date(1_000), metadata: metadata)
            XCTAssertEqual(entry.effectiveDate, metadata.effectiveDate(capturedAt: date(1_000)))
        }
    }

    /// A backdate that happens to equal the capture instant is still a backdate. The
    /// sidecar keeps them distinguishable and so must the item.
    func testBackdateEqualToCapturedAtIsStillABackdate() {
        let entry = item("A", capturedAt: 1_000, originalDate: 1_000)
        XCTAssertTrue(entry.isBackdated)
        XCTAssertEqual(entry.effectiveDate, entry.capturedAt)
    }

    // MARK: Sorting

    func testSortsByEffectiveDateDescendingNotByCaptureTime() {
        // The 1987 entry was recorded most recently and must sort last.
        let recent = item("C", capturedAt: 3_000)
        let backdated = item("D", capturedAt: 4_000, originalDate: 10)
        let older = item("A", capturedAt: 1_000)
        let sorted = EntryListItem.sortedByEffectiveDate([older, backdated, recent])
        XCTAssertEqual(sorted.map(\.captureID), ["C", "A", "D"])
    }

    func testEqualEffectiveDatesBreakTiesOnCaptureIDDescending() {
        let a = item("01AAA", capturedAt: 9_000, originalDate: 100)
        let b = item("01BBB", capturedAt: 1, originalDate: 100)
        let c = item("01CCC", capturedAt: 5, originalDate: 100)
        XCTAssertEqual(EntryListItem.sortedByEffectiveDate([a, b, c]).map(\.captureID),
                       ["01CCC", "01BBB", "01AAA"])
        // Total order, so the result does not depend on input order.
        XCTAssertEqual(EntryListItem.sortedByEffectiveDate([c, a, b]).map(\.captureID),
                       ["01CCC", "01BBB", "01AAA"])
    }

    // MARK: Filtering — trash

    func testDefaultFilterExcludesTrashed() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        XCTAssertEqual(EntryListFilter.default.apply(to: [live, trashed]).map(\.captureID), ["A"])
    }

    func testTrashedOnlyShowsOnlyTombstoned() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        let filter = EntryListFilter(trash: .trashedOnly)
        XCTAssertEqual(filter.apply(to: [live, trashed]).map(\.captureID), ["B"])
    }

    func testAllScopeShowsBoth() {
        let live = item("A", capturedAt: 100)
        let trashed = item("B", capturedAt: 200, trashedAt: 300)
        let filter = EntryListFilter(trash: .all)
        XCTAssertEqual(Set(filter.apply(to: [live, trashed]).map(\.captureID)), ["A", "B"])
    }

    /// An entry whose `entry.json` did not decode has an *unknown* trash state. It shows
    /// in the library and stays out of the Trash view: a visible entry that might be
    /// deleted is a nuisance; an invisible one looks exactly like data loss.
    func testUnreadableMetadataStaysVisibleInTheLibraryAndOutOfTrash() {
        let degraded = item("A", capturedAt: 100, degradations: [.metadataUnreadable])
        XCTAssertEqual(EntryListFilter.default.apply(to: [degraded]).map(\.captureID), ["A"])
        XCTAssertTrue(EntryListFilter(trash: .trashedOnly).apply(to: [degraded]).isEmpty)
    }

    // MARK: Filtering — journal

    func testJournalScopeFiltersOnTheRawID() {
        let filed = item("A", capturedAt: 100, journalID: "J1")
        let other = item("B", capturedAt: 200, journalID: "J2")
        let unfiled = item("C", capturedAt: 300)
        let items = [filed, other, unfiled]
        XCTAssertEqual(EntryListFilter(journal: .journal("J1")).apply(to: items).map(\.captureID), ["A"])
        XCTAssertEqual(EntryListFilter(journal: .unfiled).apply(to: items).map(\.captureID), ["C"])
        XCTAssertEqual(EntryListFilter(journal: .all).apply(to: items).count, 3)
    }

    /// A dangling reference still belongs to the journal it names. Filtering on the
    /// resolved `Journal` instead would make those entries reachable from no journal
    /// view at all — findable only by scrolling "all".
    func testDanglingJournalStillMatchesItsJournalScopeAndIsNotUnfiled() {
        let dangling = item("A", capturedAt: 100, journalID: "GONE",
                            degradations: [.journalUnresolved])
        XCTAssertTrue(dangling.hasDanglingJournal)
        XCTAssertNil(dangling.journal)
        XCTAssertEqual(EntryListFilter(journal: .journal("GONE")).apply(to: [dangling]).count, 1)
        XCTAssertTrue(EntryListFilter(journal: .unfiled).apply(to: [dangling]).isEmpty)
    }

    func testResolvedJournalIsNotDangling() {
        let journal = Journal(id: "J1", name: "1987 Journal", createdAt: date(0))
        let filed = item("A", capturedAt: 100, journalID: "J1", journal: journal)
        XCTAssertFalse(filed.hasDanglingJournal)
        XCTAssertEqual(filed.journal?.name, "1987 Journal")
    }

    func testUnfiledEntryIsNotDangling() {
        XCTAssertFalse(item("A", capturedAt: 100).hasDanglingJournal)
    }

    func testFilterCombinesJournalAndTrash() {
        let items = [item("A", capturedAt: 100, journalID: "J1"),
                     item("B", capturedAt: 200, journalID: "J1", trashedAt: 1),
                     item("C", capturedAt: 300, journalID: "J2", trashedAt: 1)]
        let filter = EntryListFilter(journal: .journal("J1"), trash: .trashedOnly)
        XCTAssertEqual(filter.apply(to: items).map(\.captureID), ["B"])
    }

    func testFilterAlsoSorts() {
        let items = [item("A", capturedAt: 100), item("B", capturedAt: 300), item("C", capturedAt: 200)]
        XCTAssertEqual(EntryListFilter.default.apply(to: items).map(\.captureID), ["B", "C", "A"])
    }

    // MARK: Snippet

    func testSnippetCollapsesWhitespace() {
        XCTAssertEqual(EntrySnippet.make(from: "  hello   there\nworld \t"), "hello there world")
    }

    func testEmptyTextHasNoSnippet() {
        XCTAssertNil(EntrySnippet.make(from: ""))
        XCTAssertNil(EntrySnippet.make(from: "   \n  "))
    }

    func testSnippetTruncatesAtAWordBoundary() {
        let text = String(repeating: "alpha beta ", count: 40)
        let snippet = try? XCTUnwrap(EntrySnippet.make(from: text, limit: 20))
        XCTAssertEqual(snippet, "alpha beta alpha…")
        XCTAssertFalse(snippet?.contains("  ") ?? true)
    }

    /// One unbroken token longer than the limit still has to be cut somewhere.
    func testSnippetTruncatesAWordThatExceedsTheLimitOnItsOwn() {
        XCTAssertEqual(EntrySnippet.make(from: String(repeating: "x", count: 30), limit: 5), "xxxxx…")
    }

    func testShortTextIsNotTruncated() {
        XCTAssertEqual(EntrySnippet.make(from: "short one", limit: 160), "short one")
    }

    // MARK: hasTranscriptText

    /// A readable-but-empty log is `.present` and still has nothing to show. Collapsing
    /// the two would render a blank snippet row for a capture that transcribed silence.
    func testPresentTranscriptWithNoTextHasNoText() {
        let entry = item("A", capturedAt: 100, snippet: nil, transcript: .present)
        XCTAssertFalse(entry.hasTranscriptText)
        XCTAssertEqual(entry.transcript, .present)
    }

    func testUnreadableTranscriptIsNotAbsent() {
        let entry = item("A", capturedAt: 100, transcript: .unreadable,
                         degradations: [.transcriptUnreadable])
        XCTAssertNotEqual(entry.transcript, .absent)
        XCTAssertFalse(entry.hasTranscriptText)
    }
}
