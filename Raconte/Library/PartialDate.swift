import Foundation

/// A user-authored date known only to some precision — a paper journal dated "1998",
/// "March 1998", or "March 4, 1998". Stored as a plain string ("1998", "1998-03",
/// "1998-03-04"), never an absolute instant: an instant has a timezone-dependent year,
/// so a year-only backdate stored as `Date` can re-derive a *different* year after a
/// westward timezone change. This type is the fix (M3 issue #14 part 2) — `EntryMetadata`
/// carries it instead of `Date? + DatePrecision?`.
///
/// The two weekday widths `PartialDate.weekdayText` supports — library rows want
/// abbreviated ("Wed"), the detail screen wants the full name ("Wednesday").
enum WeekdayStyle: Sendable, Equatable {
    case abbreviated
    case wide
}

/// `day` requires `month`; there is no such thing as "day 4 of an unknown month".
struct PartialDate: Sendable, Equatable, Hashable {
    let year: Int
    let month: Int?
    let day: Int?

    enum PartialDateError: Error, Equatable {
        /// Not a recognized "YYYY" / "YYYY-MM" / "YYYY-MM-DD" string, or the calendar
        /// date it names does not exist (Feb 30, month 13, unpadded components, ...).
        case malformed(String)
    }

    /// `day` without `month` is invalid — construction can't express a date the string
    /// grammar can't either.
    init(year: Int, month: Int? = nil, day: Int? = nil) {
        precondition(day == nil || month != nil, "PartialDate day requires a month")
        self.year = year
        self.month = month
        self.day = day
    }

    /// Truncates `date` to `precision`'s components, in `calendar`'s terms — the seam
    /// writers use when they hold a `Date` from a picker plus a target precision.
    init(from date: Date, precision: DatePrecision, calendar: Calendar) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        switch precision {
        case .year:
            self.init(year: comps.year!)
        case .yearMonth:
            self.init(year: comps.year!, month: comps.month!)
        case .day:
            self.init(year: comps.year!, month: comps.month!, day: comps.day!)
        }
    }

    var precision: DatePrecision {
        if day != nil { return .day }
        if month != nil { return .yearMonth }
        return .year
    }

    // MARK: Parsing / formatting

    /// Strict grammar only: zero-padded 2-digit month/day, no timezone/offset, no
    /// trailing garbage. Anything else — "1998-3", "1998-13-01", "1998-02-30" — is
    /// rejected, the last of those via `DateComponents.isValidDate` rather than
    /// hand-rolled month-length tables.
    init(parsing string: String) throws {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        func fail() -> PartialDateError { .malformed(string) }

        switch parts.count {
        case 1:
            guard let year = Self.parseComponent(parts[0], digits: 4) else { throw fail() }
            self.init(year: year)
        case 2:
            guard let year = Self.parseComponent(parts[0], digits: 4),
                  let month = Self.parseComponent(parts[1], digits: 2), (1...12).contains(month)
            else { throw fail() }
            self.init(year: year, month: month)
        case 3:
            guard let year = Self.parseComponent(parts[0], digits: 4),
                  let month = Self.parseComponent(parts[1], digits: 2), (1...12).contains(month),
                  let day = Self.parseComponent(parts[2], digits: 2)
            else { throw fail() }
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            guard comps.isValidDate(in: Self.gregorian) else { throw fail() }
            self.init(year: year, month: month, day: day)
        default:
            throw fail()
        }
    }

    /// `nil` unless `substring` is exactly `digits` ASCII digit characters — rejects
    /// "1998-3" (unpadded), "+1998" (sign), and anything with stray whitespace.
    private static func parseComponent(_ substring: Substring, digits: Int) -> Int? {
        guard substring.count == digits, substring.allSatisfy(\.isASCIINumber) else { return nil }
        return Int(substring)
    }

    private static let gregorian = Calendar(identifier: .gregorian)

    /// "1998" / "1998-03" / "1998-03-04" — the sole on-disk and in-memory string form.
    var isoString: String {
        switch (month, day) {
        case (nil, _):
            return String(format: "%04d", year)
        case (let m?, nil):
            return String(format: "%04d-%02d", year, m)
        case (let m?, let d?):
            return String(format: "%04d-%02d-%02d", year, m, d)
        }
    }

    /// Precision-aware display — absorbs what `DatePrecision.formatted` used to do
    /// directly on a `Date`. `dayStyle` only matters at `.day` precision.
    func formatted(dayStyle: Date.FormatStyle.DateStyle = .abbreviated,
                    calendar: Calendar = .gregorianCurrent) -> String {
        let anchor = anchorDate(calendar: calendar)
        switch precision {
        case .day: return anchor.formatted(date: dayStyle, time: .omitted)
        case .yearMonth: return anchor.formatted(.dateTime.year().month(.wide))
        case .year: return anchor.formatted(.dateTime.year())
        }
    }

    /// The one Date-conversion rule (replaces `DatePrecision.normalized`): missing
    /// month/day fill as 1/1, hour = noon — noon, not midnight, so a reduced-precision
    /// date doesn't sit on a midnight boundary a more-westward timezone can roll into the
    /// previous day. Used for sorting, grouping, and range math; never round-tripped back
    /// into a `PartialDate`, which stays the string source of truth.
    func anchorDate(calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month ?? 1
        comps.day = day ?? 1
        comps.hour = 12
        return calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    /// The weekday name for this value — present only at `.day` precision (issue #48).
    /// `anchorDate`'s day-1 fill at `.yearMonth`/`.year` would name a weekday for a day
    /// nobody wrote down; that is exactly the fabricated-precision lie this type exists
    /// to prevent, so those precisions answer `nil` rather than a confident wrong guess.
    ///
    /// Reads `calendar.weekdaySymbols`/`shortWeekdaySymbols` — locale-aware (CLDR data
    /// keyed off the calendar's locale, `Locale.autoupdatingCurrent` when unset, same as
    /// every other unpinned date display in this app), never a hardcoded English name.
    /// Deliberately NOT `Date.FormatStyle`'s `.dateTime.weekday(_:)`: on this SDK
    /// (macOS 26.5) it memoizes the resolved ICU pattern across calls in a way that
    /// leaks width between styles — calling `.wide` and then `.abbreviated` in the same
    /// process can return "Wednesday" for the abbreviated call, order-dependently
    /// reproduced in `PartialDateTests`. `Calendar`'s own symbol arrays have no such
    /// cache and are the more direct API for "just the weekday name" regardless.
    func weekdayText(style: WeekdayStyle = .abbreviated,
                      calendar: Calendar = .gregorianCurrent) -> String? {
        guard precision == .day else { return nil }
        let weekdayIndex = calendar.component(.weekday, from: anchorDate(calendar: calendar))
        let symbols = style == .wide ? calendar.weekdaySymbols : calendar.shortWeekdaySymbols
        return symbols[weekdayIndex - 1]
    }

    /// Precision-aware future check (disallow-future-backdates): compares against `now`
    /// truncated to *this value's own precision*, not `now` itself — so a year-only
    /// "2026" is future only once the current year has rolled past it, and a day-only
    /// "2026-08-03" is future only once tomorrow arrives, not merely because `now` carries
    /// a later hour. `now` is a parameter, not `Date()` inline, so callers (and their
    /// tests) control the reference instant instead of this racing the real clock.
    func isFuture(now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> Bool {
        self > PartialDate(from: now, precision: precision, calendar: calendar)
    }
}

extension PartialDate: Comparable {
    /// Ordered via `anchorDate(calendar: .gregorianCurrent)` on both sides — so a
    /// `PartialDate` sorts consistently with any place that mixes it into a `Date`-keyed
    /// order (e.g. `EntryListItem.effectiveDate`), rather than comparing components
    /// directly and risking a different tiebreak rule.
    static func < (lhs: PartialDate, rhs: PartialDate) -> Bool {
        lhs.anchorDate(calendar: .gregorianCurrent) < rhs.anchorDate(calendar: .gregorianCurrent)
    }
}

extension PartialDate: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(parsing: string)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid partial date: \(string)", underlyingError: error))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}
