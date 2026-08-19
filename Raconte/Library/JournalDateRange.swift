import Foundation

/// A journal's date span, derived from its entries — never stored. Min and max
/// `effectiveDate` (`EntryMetadata.effectiveDate`, which already normalizes
/// reduced-precision backdates: a year-only 1998 entry bounds the range at Jan 1 1998).
///
/// Each bound carries the precision of the entry that set it, so display can fall back
/// to `PartialDate.formatted` for a single-entry journal instead of always spelling
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

extension DatePrecision {
    /// The coarser of two precisions. Lifted out of `JournalDateRange`'s private scope
    /// so `JournalSpan` can share it rather than carry a second rank table that would
    /// drift (standing branch rule: call the shared primitive, never copy it).
    static func coarser(_ a: DatePrecision, _ b: DatePrecision) -> DatePrecision {
        func rank(_ p: DatePrecision) -> Int {
            switch p {
            case .day: return 0
            case .yearMonth: return 1
            case .year: return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}

extension JournalDateRange {
    /// Terse, collapsed display: a single precision-aware date when the range is a
    /// point (`PartialDate.formatted`, so a lone year-only entry reads "1998" rather
    /// than "Jan 1, 1998"); "March – July 1998" within one calendar year when both
    /// bounds actually carry a month (`.yearMonth`/`.day`); "1998–2003" across years.
    /// A `.year`-precision bound never contributes a month it doesn't have — a 1998
    /// year-only entry alongside a July 1998 day entry collapses to "1998", not
    /// "January – July 1998".
    func formatted(calendar: Calendar = .current) -> String {
        if minDate == maxDate {
            let precision = DatePrecision.coarser(minPrecision, maxPrecision)
            return PartialDate(from: minDate, precision: precision, calendar: calendar)
                .formatted(calendar: calendar)
        }
        let minYear = calendar.component(.year, from: minDate)
        let maxYear = calendar.component(.year, from: maxDate)
        guard minPrecision != .year, maxPrecision != .year else {
            return minYear == maxYear ? "\(minYear)" : "\(minYear)–\(maxYear)"
        }
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
