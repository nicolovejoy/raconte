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

/// One calendar month's worth of rows within a single `EntryYearGroup`'s `items` — the
/// library's month sub-headers (Task 11, spec "cover header band... month dividers within
/// the year sections"). Full month name (e.g. "July"), not "year year" qualified: this is
/// only ever run over one year group's `items` at a time, so the year is already the
/// enclosing `Section`'s own header and would be redundant here.
struct EntryMonthGroup: Identifiable, Equatable {
    var month: String
    var items: [EntryListItem]
    var id: String { month }
}

extension EntryListItem {
    /// Groups by the calendar month name of `effectiveDate`, same linear-pass-over-
    /// already-sorted-input contract as `groupedByYear` (contiguous same-month rows
    /// merge; non-contiguous ones split rather than re-sort). Callers pass one year
    /// group's `items`, never the whole library — the month name alone (no year) is only
    /// unambiguous within a single year's rows.
    static func monthGroups(of items: [EntryListItem],
                            calendar: Calendar = .gregorianCurrent) -> [EntryMonthGroup] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL"
        var groups: [EntryMonthGroup] = []
        for item in items {
            let month = formatter.string(from: item.effectiveDate)
            if let last = groups.indices.last, groups[last].month == month {
                groups[last].items.append(item)
            } else {
                groups.append(EntryMonthGroup(month: month, items: [item]))
            }
        }
        return groups
    }
}
