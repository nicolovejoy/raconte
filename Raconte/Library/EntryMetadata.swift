import Foundation

/// Precision `originalDate` was set at (M3 issue #14 part 1) — paper journals are often
/// dated only to a year, or a year and month. Meaningless when `originalDate` is `nil`.
enum DatePrecision: String, Codable, Sendable, CaseIterable {
    case day
    case yearMonth
    case year

    /// Collapses `date` to the first instant this precision can represent — year → Jan 1,
    /// yearMonth → the 1st — in the current calendar. `.day` returns `date` unchanged.
    /// The one place this happens: `EntryMetadata.effectiveDate(capturedAt:)` calls it,
    /// and every sort/date-range/display call site goes through that, not `originalDate`
    /// directly, so there is exactly one rule for what a reduced-precision date "is".
    func normalized(_ date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .day: return date
        case .yearMonth: return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        case .year: return calendar.date(from: calendar.dateComponents([.year], from: date)) ?? date
        }
    }

    /// Format `date` at this precision — "1998", "March 1998", or a calendar date.
    /// `dayStyle` only matters for `.day`; the other two have exactly one rendering each.
    func formatted(_ date: Date, dayStyle: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        switch self {
        case .day: return date.formatted(date: dayStyle, time: .omitted)
        case .yearMonth: return date.formatted(.dateTime.year().month(.wide))
        case .year: return date.formatted(.dateTime.year())
        }
    }
}

/// User-owned metadata for one capture, stored as `entry.json` **beside** the manifest.
///
/// Not in the manifest, on purpose (M3 plan, "architecture stance"): the manifest is
/// capture-machine territory, written by `SegmentStore` on every transition and hardened
/// by the recovery suite. This is user-mutable, edited long after the capture is over,
/// and must be writable without any code path that could disturb those guarantees.
///
/// **Every field is optional and every default is a semantic, not a value.** In
/// particular `originalDate == nil` means "the capture's own date", and the default is
/// deliberately *not* materialized: writing `capturedAt` into the sidecar would make an
/// un-backdated entry indistinguishable from one the user backdated to exactly its
/// capture time, and would freeze a date the capture path may still correct.
struct EntryMetadata: Codable, Sendable, Equatable {
    /// The journal this entry is filed in. `nil` is unfiled — a real state, reachable by
    /// capturing before any journal exists.
    var journalID: String?

    /// The date the entry is *about*, when it differs from when it was recorded (reading
    /// a 1987 paper journal aloud). `nil` ⇒ use the capture's own date.
    var originalDate: Date?

    /// Precision `originalDate` was set at. `nil` ⇒ `.day` — the only precision this
    /// field had before M3 issue #14, so an old sidecar with a backdate and no precision
    /// key keeps meaning exactly what it always meant. Meaningless when `originalDate`
    /// is `nil`; nothing reads it in that case.
    var precision: DatePrecision?

    /// Soft-delete tombstone (M3 T5). The field lands now so the format does not churn
    /// once trash ships; nothing writes it yet.
    var trashedAt: Date?

    init(journalID: String? = nil, originalDate: Date? = nil, precision: DatePrecision? = nil,
         trashedAt: Date? = nil) {
        self.journalID = journalID
        self.originalDate = originalDate
        self.precision = precision
        self.trashedAt = trashedAt
    }

    /// What an absent `entry.json` means. An unfiled, un-backdated, live entry.
    static let defaults = EntryMetadata()

    var isTrashed: Bool { trashedAt != nil }

    /// True when the sidecar carries nothing a default wouldn't supply — i.e. writing it
    /// is optional. Callers may use this to avoid creating a file with no information in
    /// it, which also keeps `holdsIrreplaceableArtifacts` honest.
    var isDefault: Bool { self == Self.defaults }

    /// `precision`, defaulted for the "absent ⇒ `.day`" rule. Use this, not `precision`
    /// directly, wherever the value must be a real precision rather than an optional.
    var effectivePrecision: DatePrecision { precision ?? .day }

    /// The entry's effective date: the backdate if set (normalized to its precision —
    /// see `DatePrecision.normalized`), otherwise the capture's own.
    func effectiveDate(capturedAt: Date) -> Date {
        guard let originalDate else { return capturedAt }
        return effectivePrecision.normalized(originalDate)
    }

    /// Hand-written per the house decoder rule (§11 of the M2 design): Swift's
    /// synthesized decoder ignores property defaults, so *every* key would be required —
    /// including the all-defaults `{}` this type's own contract calls valid.
    ///
    /// There are no identity fields here to keep strict. Everything is additive by
    /// construction, so everything is `decodeIfPresent`, `{}` decodes to `.defaults`, and
    /// unknown keys from a newer build are ignored rather than fatal. Strictness has not
    /// been abandoned, only relocated: a key that is *present with the wrong type* still
    /// throws, and the store surfaces that as unreadable rather than as defaults —
    /// exactly the absent/unreadable distinction transcripts settled on.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journalID = try container.decodeIfPresent(String.self, forKey: .journalID)
        originalDate = try container.decodeIfPresent(Date.self, forKey: .originalDate)
        precision = try container.decodeIfPresent(DatePrecision.self, forKey: .precision)
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
    }

    /// Encoded without nil keys (the default `KeyEncodingStrategy` behaviour for
    /// `Optional`), so an unfiled entry's sidecar is literally `{}` and adding a field
    /// later cannot change what an old file means.
}
