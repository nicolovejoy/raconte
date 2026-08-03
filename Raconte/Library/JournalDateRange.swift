import Foundation

/// A journal's date span, derived from its entries — never stored. Min and max
/// `effectiveDate` (`EntryMetadata.effectiveDate`, which already normalizes
/// reduced-precision backdates: a year-only 1998 entry bounds the range at Jan 1 1998).
///
/// Each bound carries the precision of the entry that set it, so display can fall back
/// to `DatePrecision.formatted` for a single-entry journal instead of always spelling
/// out a day that was never actually known.
struct JournalDateRange: Equatable {
    var minDate: Date
    var minPrecision: DatePrecision
    var maxDate: Date
    var maxPrecision: DatePrecision

    /// Derives the range from `entries`. Trashed entries never contribute — same rule
    /// the library scan already applies when it excludes them from `items`. `nil` for a
    /// journal with no (non-trashed) entries.
    static func compute(from entries: [EntryListItem]) -> JournalDateRange? {
        var range: JournalDateRange?
        for entry in entries where !entry.isTrashed {
            let date = entry.effectiveDate
            let precision = entry.originalDatePrecision
            guard var current = range else {
                range = JournalDateRange(minDate: date, minPrecision: precision,
                                         maxDate: date, maxPrecision: precision)
                continue
            }
            if date < current.minDate { current.minDate = date; current.minPrecision = precision }
            if date > current.maxDate { current.maxDate = date; current.maxPrecision = precision }
            range = current
        }
        return range
    }
}

extension JournalDateRange {
    /// Terse, collapsed display: a single precision-aware date when the range is a
    /// point (`DatePrecision.formatted`, so a lone year-only entry reads "1998" rather
    /// than "Jan 1, 1998"); "March – July 1998" within one calendar year; "1998–2003"
    /// across years. Deliberately ignores precision once there's more than one entry —
    /// month names are compatible with any precision they might have been formed from.
    func formatted(calendar: Calendar = .current) -> String {
        if minDate == maxDate {
            return minPrecision.formatted(minDate)
        }
        let minYear = calendar.component(.year, from: minDate)
        let maxYear = calendar.component(.year, from: maxDate)
        if minYear == maxYear {
            let minMonth = minDate.formatted(.dateTime.month(.wide))
            let maxMonth = maxDate.formatted(.dateTime.month(.wide))
            if minMonth == maxMonth {
                return "\(minMonth) \(minYear)"
            }
            return "\(minMonth) – \(maxMonth) \(minYear)"
        }
        return "\(minYear)–\(maxYear)"
    }
}
