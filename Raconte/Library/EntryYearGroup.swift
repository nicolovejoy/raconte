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
/// `month == nil` means "this run of rows has no month to name" — a `.year`-precision
/// backdate (final-review finding 1). The library renders no header row for such a
/// group; the enclosing year `Section` header already covers it. Never fabricate one
/// from `anchorDate`'s January fill — same refusal `PartialDate.weekdayText` documents.
struct EntryMonthGroup: Identifiable, Equatable {
    var month: String?
    var items: [EntryListItem]
    var id: String { month ?? "" }
}

extension EntryListItem {
    /// Groups by the calendar month name of `effectiveDate`, same linear-pass-over-
    /// already-sorted-input contract as `groupedByYear` (contiguous same-key rows
    /// merge; non-contiguous ones split rather than re-sort). Callers pass one year
    /// group's `items`, never the whole library — the month name alone (no year) is only
    /// unambiguous within a single year's rows.
    ///
    /// An entry backdated at `.year` precision has no month of its own — `month` comes
    /// back `nil` for it rather than the January `anchorDate` fills in for the missing
    /// component (final-review finding 1). It gets its own nil-keyed group like any
    /// other key change: not merged into an adjacent named month, and not made to split
    /// one unless it actually sits between that month's rows in sort order.
    static func monthGroups(of items: [EntryListItem],
                            calendar: Calendar = .gregorianCurrent) -> [EntryMonthGroup] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL"
        var groups: [EntryMonthGroup] = []
        for item in items {
            let month: String?
            if let originalDate = item.originalDate, originalDate.month == nil {
                month = nil
            } else {
                month = formatter.string(from: item.effectiveDate)
            }
            if let last = groups.indices.last, groups[last].month == month {
                groups[last].items.append(item)
            } else {
                groups.append(EntryMonthGroup(month: month, items: [item]))
            }
        }
        return groups
    }
}
