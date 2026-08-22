import XCTest
@testable import Raconte

/// Exhaustive pin for `JournalDeleteEligibility.blockedReason` (#80, Task B3 review
/// finding): the JournalEditorUITests suite only ever exercises the fresh-launch
/// default journal (which is also the last remaining one) or a brand-new empty
/// non-last journal, so it cannot discriminate the entries-only branch from the
/// last-journal branch, and it never reaches the trashed-only case at all — nothing in
/// this project's UI harness trashes an entry while that entry's journal editor is
/// open. These tests assert the SPECIFIC reason string per case, not just non-nil vs.
/// nil, so a branch collapsing into the wrong reason (or the wrong branch firing at
/// all) is caught, not just "some refusal happened."
final class JournalDeleteEligibilityTests: XCTestCase {
    private let lastJournalReason =
        "This is your only journal. Raconte always needs at least one to capture into."
    private let hasContentReason =
        "Delete every entry in this journal — including anything still in "
        + "Trash — before you can delete the journal itself."

    func testLastRemainingJournalIsBlockedEvenWhenEmpty() {
        XCTAssertEqual(
            JournalDeleteEligibility.blockedReason(journalCount: 1, entryCount: 0, trashedCount: 0),
            lastJournalReason)
    }

    func testNonLastJournalWithLiveEntriesIsBlocked() {
        XCTAssertEqual(
            JournalDeleteEligibility.blockedReason(journalCount: 2, entryCount: 3, trashedCount: 0),
            hasContentReason)
    }

    /// The orphan-on-restore case (#80, owner ruling 1): a journal holding ONLY a
    /// trashed entry is not empty, since restoring that entry later would file it into
    /// a journal that no longer exists. This is the one case nothing else in the suite
    /// (unit or UI) pins — it is the entire reason this function was extracted.
    func testNonLastJournalWithOnlyATrashedEntryIsBlocked() {
        XCTAssertEqual(
            JournalDeleteEligibility.blockedReason(journalCount: 2, entryCount: 0, trashedCount: 1),
            hasContentReason)
    }

    /// When a journal is both the last one AND holds entries (the fresh-launch default
    /// journal, in practice), the last-journal reason wins — not a load-bearing choice,
    /// but pinned so a refactor can't silently flip which message shows.
    func testBothReasonsTrueReturnsTheLastJournalReason() {
        XCTAssertEqual(
            JournalDeleteEligibility.blockedReason(journalCount: 1, entryCount: 2, trashedCount: 1),
            lastJournalReason)
    }

    func testNonLastEmptyJournalIsDeletable() {
        XCTAssertNil(
            JournalDeleteEligibility.blockedReason(journalCount: 2, entryCount: 0, trashedCount: 0))
    }
}
