import Foundation

/// One calendar year's worth of library rows, in the order `items` already carries them.
/// Presentation grouping only — `EntryListItem` has no year field of its own.
struct EntryYearGroup: Identifiable, Equatable {
    var year: Int
    var items: [EntryListItem]
    var id: Int { year }
}

extension EntryListItem {
    /// Groups by the calendar year of `effectiveDate`.
    ///
    /// Assumes `items` is already sorted descending by `effectiveDate`
    /// (`sortedByEffectiveDate` / `EntryListFilter.apply`, which the library screen always
    /// runs through) — same-year rows are then contiguous, so this is one linear pass
    /// rather than a group-then-resort. Callers that pass unsorted input get groups split
    /// wherever the year changes, which is still correct, just not maximally compact.
    static func groupedByYear(_ items: [EntryListItem],
                              calendar: Calendar = .gregorianCurrent) -> [EntryYearGroup] {
        var groups: [EntryYearGroup] = []
        for item in items {
            let year = calendar.component(.year, from: item.effectiveDate)
            if let last = groups.indices.last, groups[last].year == year {
                groups[last].items.append(item)
            } else {
                groups.append(EntryYearGroup(year: year, items: [item]))
            }
        }
        return groups
    }
}
