import Foundation

/// #175: the pre-fill for the backdate toggle when nothing has been carried this session.
/// #183 adds `automatic`, the launch/journal-switch default that also decides the toggle.
///
/// `CaptureScreenModel.carriedBackdates` is in-memory by design (a sitting's convenience,
/// not a preference), so the first backdated entry after a relaunch used to open at today.
/// This reads the journal's own history instead. Rulings, all owner's (issue #175):
/// - the source is the most recently CAPTURED backdated entry, never the latest backdate —
///   "continue where I left off", which also does the right thing when an older gap is
///   being back-filled after newer pages;
/// - untrashed only, and an entry with no backdate is skipped, not read as its capture day;
/// - `.day` advances one day (`PartialDate.nextDay`), coarser precisions carry unchanged;
/// - never past today: the sidecar would refuse it (`EntryMetadata.setOriginalDate`), so a
///   next day in the future becomes today at `.day`.
///
/// Pure: `now` is injected so the clamp is testable on a fixed date.
enum BackdateSeed {
    static func seed(from entries: [EntryListItem], journalID: String,
                     now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> PartialDate? {
        let source = entries
            .filter { $0.journalID == journalID && !$0.isTrashed && $0.originalDate != nil }
            .max { $0.capturedAt < $1.capturedAt }
        guard let previous = source?.originalDate else { return nil }
        guard let next = previous.nextDay(calendar: calendar) else { return previous }
        if next.isFuture(now: now, calendar: calendar) {
            return PartialDate(from: now, precision: .day, calendar: calendar)
        }
        return next
    }

    /// #183 (rules 2 and 3): the seed to apply WITHOUT the owner touching the toggle, or
    /// nil when the toggle should start off. Decided by the journal's LATEST untrashed
    /// capture, whatever its date: only when that capture itself is backdated does the
    /// toggle start on — and then at `seed`, which that same capture is the source of.
    /// An undated latest capture means the owner has moved on to dating by capture day,
    /// so the toggle starts off; a manual toggle-on still gets `seed` (rule 5).
    static func automatic(from entries: [EntryListItem], journalID: String,
                          now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> PartialDate? {
        let latest = entries
            .filter { $0.journalID == journalID && !$0.isTrashed }
            .max { $0.capturedAt < $1.capturedAt }
        guard latest?.originalDate != nil else { return nil }
        return seed(from: entries, journalID: journalID, now: now, calendar: calendar)
    }
}
