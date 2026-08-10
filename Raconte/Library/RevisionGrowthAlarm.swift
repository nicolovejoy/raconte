import Foundation

/// #39's revision-count growth alarm (owner ruling, T7 Task 3 brief work item 3): the
/// signal worth surfacing is how many times an entry has been edited, not how many
/// bytes its chain occupies — a long recording with one clean promotion is unremarkable;
/// an entry with dozens of revisions is the one worth a second look.
///
/// A pure predicate ONLY. This task builds no UI for it — Task 8 owns where/how it
/// renders (the revision-history panel and the diagnostics screen, per the ruling in
/// the Task 3 brief). Deliberately takes a bare `Int` rather than `EntryChainSnapshot`
/// or `CaptureSnapshot`: either surface's own revision count — the history panel's
/// `EntryChainSnapshot.revisionCount` (a per-entry, user-action read) or the
/// diagnostics screen's cheap `CaptureSnapshot.canonicalRevisions.count` (a corpus-wide
/// scan stat, no chain decode) — can be tested against the same threshold without this
/// type needing to know, or care, which one produced it.
enum RevisionGrowthAlarm {
    /// Chosen by the owner as "a lot of edits" for one entry, not derived from a
    /// measurement — a single named constant so every future caller reads the same
    /// number rather than each choosing its own.
    static let threshold = 50

    /// `true` at or above `threshold`. `>=`, not `>`: an entry that has JUST reached 50
    /// revisions is already the case the alarm exists to surface, not one revision away
    /// from it.
    static func isElevated(revisionCount: Int) -> Bool {
        revisionCount >= threshold
    }
}
