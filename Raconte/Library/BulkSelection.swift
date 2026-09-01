import Foundation

/// The selection behind select mode in the library and Trash screens (#128, Task 1).
///
/// A value type over a flat `Set` of capture ids — flat on purpose: the entry list is
/// grouped by year and month, and a selection keyed by id spans that grouping for free.
///
/// Held as `@State` on the VIEW, never on `LibraryScreenModel` — the deliberate inverse
/// of the capture-screen invariant ("nothing that must happen while a capture is running
/// may hang off a view's lifecycle"): selection *should* die when you navigate away.
/// Nothing about it must survive the view.
struct BulkSelection: Equatable {
    /// Whether select mode is on. Entering and leaving the mode is the view's decision
    /// ("Select" / "Done"); the flag lives here so one `@State` value carries the whole
    /// select-mode story.
    var isActive = false

    private var ids: Set<String> = []

    /// Select `id` if it is not selected; deselect it if it is.
    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// Union, not replacement: "Select All" applies to what is currently on screen, and
    /// an id selected before a filter narrowed the screen survives — this only ever adds.
    mutating func selectAll(_ newIDs: some Sequence<String>) {
        ids.formUnion(newIDs)
    }

    /// Empties the selection. Leaves `isActive` alone — clearing what is selected and
    /// leaving select mode are separate decisions (a failed bulk operation clears and
    /// re-selects the failed ids while staying in the mode).
    mutating func clear() {
        ids.removeAll()
    }

    func isSelected(_ id: String) -> Bool { ids.contains(id) }

    var count: Int { ids.count }

    var isEmpty: Bool { ids.isEmpty }

    /// The selection as a stable, deterministic array — what the bulk operations on
    /// `LibraryScreenModel` are handed, so two runs over the same selection process the
    /// same ids in the same order.
    var sortedIDs: [String] { ids.sorted() }
}
