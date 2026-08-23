import Foundation

/// Pure computation of the delete-blocked reason for a journal (#80). Extracted from
/// `JournalEditorView.deleteBlockedReason` (review finding on Task B3) so every branch
/// is exhaustively unit-tested — most importantly the trashed-only case, which no UI
/// test can reach: nothing in this project's UI harness trashes an entry while that
/// entry's journal editor is open on screen.
///
/// **Must stay in agreement with `LibraryScreenModel.isJournalEmpty`'s "zero live
/// entries AND zero trashed entries" definition of empty.** That method is the actual
/// authority the delete path enforces — `LibraryScreenModel.deleteJournal` rescans and
/// re-checks it before ever touching the store. This function only decides what the
/// BUTTON looks like before that authoritative check ever runs (a stale or wrong
/// `disabled` state here is a UX defect, never a data-safety one — a confirm-tap still
/// routes through the real guard and can still be refused). A future change to
/// `isJournalEmpty`'s definition will not automatically flow here; keep the two in
/// sync by hand.
enum JournalDeleteEligibility {
    /// `nil` means deletable. When more than one reason applies at once (a lone
    /// journal that also holds entries), the last-journal message wins — deliberate,
    /// not load-bearing: either message is truthful, and this is simply the one that
    /// was picked. Not in scope for change without an owner ruling.
    ///
    /// `hasIndeterminateContent` is `LibraryScreenModel.hasIndeterminateContent(forJournal:)`
    /// — read from the model rather than re-derived here, so the two cannot drift the way
    /// the counts above can. It is last in precedence: when a journal plainly holds
    /// entries, saying so is more useful than "something on disk can't be read".
    static func blockedReason(journalCount: Int, entryCount: Int, trashedCount: Int,
                              hasIndeterminateContent: Bool = false) -> String? {
        if journalCount <= 1 {
            return "This is your only journal. Raconte always needs at least one to capture into."
        }
        if entryCount > 0 || trashedCount > 0 {
            return "Delete every entry in this journal — including anything still in "
                 + "Trash — before you can delete the journal itself."
        }
        if hasIndeterminateContent {
            return "A recording on this device hasn’t settled yet, or its details can’t be "
                 + "read, so Raconte can’t tell whether it belongs here. Try again in a moment."
        }
        return nil
    }
}
