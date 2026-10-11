import Foundation

/// The search screen's date filter, over an entry's effective date.
///
/// **Every bound is a unit, not an instant** — the rule `JournalSpan` states, and its
/// helpers do the expansion here: `from` reaches back to the first instant of the day,
/// month or year it names, and `to` runs up to (excluding) the first instant after its
/// unit. Comparing against a raw `PartialDate` anchor would put 31 December outside its
/// own year.
enum SearchDateFilter: Sendable, Equatable {
    case anyTime
    case thisYear
    case lastYear
    /// Either end may be open. Both nil filters nothing.
    case custom(from: PartialDate?, to: PartialDate?)

    /// `calendar` must be the one the date was anchored in (`EntryMetadata.effectiveDate`),
    /// or a year-precision backdate can land in the neighbouring year.
    func contains(_ date: Date, calendar: Calendar, now: Date) -> Bool {
        switch self {
        case .anyTime:
            return true
        case .thisYear:
            return Self.year(calendar.component(.year, from: now), contains: date, calendar: calendar)
        case .lastYear:
            return Self.year(calendar.component(.year, from: now) - 1, contains: date, calendar: calendar)
        case .custom(let from, let to):
            if let from, date < JournalSpan.lowerBound(from, calendar: calendar) { return false }
            if let to, date >= JournalSpan.exclusiveUpperBound(to, calendar: calendar) { return false }
            return true
        }
    }

    private static func year(_ year: Int, contains date: Date, calendar: Calendar) -> Bool {
        let unit = PartialDate(year: year)
        return date >= JournalSpan.lowerBound(unit, calendar: calendar)
            && date < JournalSpan.exclusiveUpperBound(unit, calendar: calendar)
    }

    var title: String {
        switch self {
        case .anyTime: return "Any time"
        case .thisYear: return "This year"
        case .lastYear: return "Last year"
        case .custom(nil, nil): return "Custom"
        case .custom(let from?, nil): return "From \(from.formatted())"
        case .custom(nil, let to?): return "Until \(to.formatted())"
        case .custom(let from?, let to?):
            let start = from.formatted(), end = to.formatted()
            return start == end ? start : "\(start) – \(end)"
        }
    }
}
