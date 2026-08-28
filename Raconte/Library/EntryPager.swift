import Foundation

/// #101: which way a page turn moves through the entry list.
/// The list is newest-first (`EntryListItem.sortedByEffectiveDate`), so
/// `.previous` moves toward newer (up, index-1) and `.next` toward older
/// (down, index+1). Design: docs/plans/2026-08-26-101-entry-paging-design.md.
enum PagingDirection: Sendable {
    case previous
    case next
}

/// #101: the paging pure core. No SwiftUI, no model types — arrays of ids in,
/// optional id out — so the direction mapping and the whole render/enable gate
/// are unit-tested without a view in sight.
enum EntryPager {

    /// nil when `captureID` is not in `orderedIDs` (the entry left its list's
    /// scope — both controls disable) or the neighbor falls off either end
    /// (design decision 2: disable at the ends, no wrap).
    static func neighborID(of captureID: String,
                           in orderedIDs: [String],
                           direction: PagingDirection) -> String? {
        guard let index = orderedIDs.firstIndex(of: captureID) else { return nil }
        let target = direction == .previous ? index - 1 : index + 1
        guard orderedIDs.indices.contains(target) else { return nil }
        return orderedIDs[target]
    }

    /// The whole gate in one testable place: paging exists only when the CURRENT
    /// place has a journal scope (an entry list to page — a capture-pushed detail
    /// has none) AND the top of the path is the entry itself (never a journal
    /// editor sitting above it). Used by the Mac menu commands directly; the
    /// detail view reaches the same verdict through its `pagingEnabled` input
    /// plus `neighborID` (same components, same answer).
    static func pagingTarget(place: Place,
                             detailPath: [LibraryDestination],
                             orderedIDs: [String],
                             direction: PagingDirection) -> String? {
        guard PlaceRouting.journalScope(for: place) != nil,
              case .entry(let current)? = detailPath.last
        else { return nil }
        return neighborID(of: current, in: orderedIDs, direction: direction)
    }
}

/// #101: the Mac menu's view of paging. Lives here rather than in RaconteApp.swift
/// so everything #101 adds outside the view layer sits in one file. `@MainActor`
/// matches AppServices' own isolation.
@MainActor
extension AppServices {

    /// nil ⇒ the corresponding menu item is disabled. Recomputed on each Commands
    /// body evaluation; even a stale verdict is safe — `pageEntry` re-derives it.
    func entryPagingTarget(_ direction: PagingDirection) -> String? {
        EntryPager.pagingTarget(place: router.place,
                                detailPath: router.detailPath,
                                orderedIDs: library.items.map(\.captureID),
                                direction: direction)
    }

    func pageEntry(_ direction: PagingDirection) {
        guard let target = entryPagingTarget(direction) else { return }
        router.replaceTopEntry(with: target)
    }
}
