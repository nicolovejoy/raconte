import Foundation

extension Calendar {
    /// Gregorian, in the system's current time zone. `.current` follows the user's
    /// calendar *preference* (e.g. Islamic Umm al-Qura), but the year/month semantics
    /// of `originalDate`/`DatePrecision` and the library's year grouping are defined in
    /// Gregorian terms — under a non-Gregorian `.current`, normalizing or grouping by
    /// `.year` would land on the wrong year entirely. Only the calendar *identifier* is
    /// pinned; the time zone still follows the system, matching every other date
    /// display in the app.
    static var gregorianCurrent: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

/// Precision a `PartialDate` was set at (M3 issue #14 part 1) — paper journals are often
/// dated only to a year, or a year and month.
///
/// `DatePrecision.normalized(_:calendar:)` and `.formatted(_:)`, which used to live here
/// and operate on a bare `Date`, are gone (M3 issue #14 part 2) — both are now
/// `PartialDate.anchorDate(calendar:)` and `PartialDate.formatted(dayStyle:calendar:)`,
/// which have the components to do the job correctly instead of re-deriving them from an
/// already-collapsed `Date` in the viewer's timezone.
enum DatePrecision: String, Codable, Sendable, CaseIterable {
    case day
    case yearMonth
    case year
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
    ///
    /// A `PartialDate` (M3 issue #14 part 2), not a `Date` — stored on disk as a plain
    /// "1998" / "1998-03" / "1998-03-04" string, never an absolute instant. The old
    /// `Date? + DatePrecision?` pair was timezone-fragile: a year-only "1998" anchored to
    /// an instant re-derives its year in whatever calendar/timezone reads it back, so it
    /// could display as 1997 after a westward timezone change.
    var originalDate: PartialDate?

    /// Soft-delete tombstone (M3 T5). The field lands now so the format does not churn
    /// once trash ships; nothing writes it yet.
    var trashedAt: Date?

    /// The date `SpokenDateParser` read off the transcript's opening (M3 issue #15), or
    /// nil when detection has not run or found nothing.
    ///
    /// **This field is the once-only latch**, not a cache. Detection writes it the first
    /// time it runs and never revises it, so re-running over the same entry is a no-op —
    /// which is what lets the hook be "whenever the transcript first exists" rather than
    /// fragile exactly-once plumbing. It also survives the owner clearing the backdate:
    /// a cleared backdate must stay cleared, and re-deriving it from the same transcript
    /// on the next pass is precisely the bug the latch prevents.
    ///
    /// It is *not* `originalDate`. `originalDate` is what the entry is dated; this is
    /// only what the recording said, kept so the UI can tell the owner which of the two
    /// he is looking at.
    var detectedDate: PartialDate?

    /// The latch itself (issue #21), decoded independently of `detectedDate`'s value.
    /// `detectedDate` decodes leniently to nil on damage — correct in isolation, since a
    /// broken derived field must not take the whole sidecar down — but if the latch were
    /// `detectedDate != nil`, that same leniency would look identical to "detection never
    /// ran," reopening it and letting a later pass resurrect a backdate the owner
    /// deliberately cleared. This decodes `true` whenever the on-disk `detectedDate` key
    /// was present, whether or not its value parsed, so damage fails the latch closed
    /// instead of open. `SpokenDateDetection.apply` sets it alongside `detectedDate`;
    /// nothing else should.
    var detectionRan: Bool

    init(journalID: String? = nil, originalDate: PartialDate? = nil, trashedAt: Date? = nil,
         detectedDate: PartialDate? = nil, detectionRan: Bool? = nil) {
        self.journalID = journalID
        self.originalDate = originalDate
        self.trashedAt = trashedAt
        self.detectedDate = detectedDate
        // Defaults to "ran iff we have a value" for callers that don't think about the
        // flag at all — the only place that constructs the ran-but-valueless state is the
        // decoder itself.
        self.detectionRan = detectionRan ?? (detectedDate != nil)
    }

    /// What an absent `entry.json` means. An unfiled, un-backdated, live entry.
    static let defaults = EntryMetadata()

    var isTrashed: Bool { trashedAt != nil }

    /// True when the sidecar carries nothing a default wouldn't supply — i.e. writing it
    /// is optional. Callers may use this to avoid creating a file with no information in
    /// it, which also keeps `holdsIrreplaceableArtifacts` honest.
    var isDefault: Bool { self == Self.defaults }

    /// The backdate in force is the one the recording named, unedited. False once the
    /// owner touches it (that changes `originalDate` alone) and false when detection
    /// found a date it was not allowed to apply because a manual backdate already existed.
    var backdateWasDetected: Bool {
        originalDate != nil && originalDate == detectedDate
    }

    /// `originalDate.precision`, defaulted for the "absent ⇒ `.day`" rule. Use this, not
    /// `originalDate?.precision`, wherever the value must be a real precision rather than
    /// an optional.
    var effectivePrecision: DatePrecision { originalDate?.precision ?? .day }

    /// The entry's effective date: the backdate if set (`PartialDate.anchorDate`),
    /// otherwise the capture's own.
    func effectiveDate(capturedAt: Date, calendar: Calendar = .gregorianCurrent) -> Date {
        guard let originalDate else { return capturedAt }
        return originalDate.anchorDate(calendar: calendar)
    }

    /// The one place a backdate is written (disallow-future-backdates). Rejects — leaves
    /// `originalDate` unchanged — rather than clamping to `now`: silently rewriting a
    /// future dial to "today" would record a value the owner never entered. Every write
    /// site must go through this rather than assigning the stored property directly, or
    /// the guard is just UI-deep again. Clearing (`date == nil`) always succeeds.
    @discardableResult
    mutating func setOriginalDate(_ date: PartialDate?, now: Date = Date(),
                                   calendar: Calendar = .gregorianCurrent) -> Bool {
        if let date, date.isFuture(now: now, calendar: calendar) { return false }
        originalDate = date
        return true
    }

    /// `precision` only exists as a decode-time key now — the pre-#14-part-2 on-disk
    /// field a legacy `originalDate` (an ISO8601 instant) needs alongside it to convert
    /// into a `PartialDate`. New sidecars never write it.
    private enum CodingKeys: String, CodingKey {
        case journalID, originalDate, trashedAt, detectedDate, detectionRan
        case legacyPrecision = "precision"
    }

    /// Hand-written per the house decoder rule (§11 of the M2 design): Swift's
    /// synthesized decoder ignores property defaults, so *every* key would be required —
    /// including the all-defaults `{}` this type's own contract calls valid.
    ///
    /// `journalID`/`trashedAt` stay additive/lenient (`decodeIfPresent`). `originalDate`
    /// is the one identity-like field, per the M3 issue #14 part 2 brief — it is
    /// user-authored content, not a soft default, so a value that is present but
    /// unparseable throws rather than silently becoming "not backdated". Its decode has
    /// two valid shapes, both JSON strings: the new `"1998-03-04"`-style partial-date
    /// string, or a pre-#14-part-2 sidecar's ISO8601 instant (paired with a sibling
    /// `precision` key, defaulted to `.day` when absent — the only precision that field
    /// ever had before #14 part 1). Anything else — wrong JSON type, or a string that
    /// matches neither grammar — throws, surfacing through `EntryMetadataStore`'s
    /// existing unreadable path exactly like any other damaged field.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journalID = try container.decodeIfPresent(String.self, forKey: .journalID)
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        originalDate = try Self.decodeOriginalDate(container)
        // Additive and lenient, unlike `originalDate` above: this is derived from a
        // transcript that is still on disk, so a value we cannot read costs a re-derive
        // and nothing else. Throwing here would make one damaged derived field render
        // the whole sidecar unreadable — losing the journal, the backdate and the trash
        // state with it.
        detectedDate = (try? container.decodeIfPresent(PartialDate.self, forKey: .detectedDate)) ?? nil
        // The latch (issue #21): true whenever `detectedDate`'s key was present at all —
        // independent of whether the value above just decoded — or whenever an explicit
        // `detectionRan` key says so. The explicit key exists only to carry a closed latch
        // forward through a re-encode of an entry whose `detectedDate` is unreadable (see
        // `encode(to:)`), since that re-encode has no valid value to write back as the
        // signal.
        detectionRan = container.contains(.detectedDate)
            || ((try? container.decodeIfPresent(Bool.self, forKey: .detectionRan)) ?? false)
    }

    private static func decodeOriginalDate(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PartialDate? {
        guard container.contains(.originalDate) else { return nil }
        let string = try container.decode(String.self, forKey: .originalDate)
        if let partial = try? PartialDate(parsing: string) {
            return partial
        }
        guard let date = CaptureCoding.iso8601Formatter().date(from: string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.originalDate],
                debugDescription:
                    "originalDate is neither a partial-date string nor a legacy ISO8601 date: \(string)"))
        }
        let precision = try container.decodeIfPresent(DatePrecision.self, forKey: .legacyPrecision) ?? .day
        return PartialDate(from: date, precision: precision, calendar: .gregorianCurrent)
    }

    /// Encoded without nil keys (the default `KeyEncodingStrategy` behaviour for
    /// `Optional`), so an unfiled entry's sidecar is literally `{}` and adding a field
    /// later cannot change what an old file means. `legacyPrecision` is never written —
    /// a read-modify-write of an old-format sidecar upgrades it to the new string form
    /// in place, with no separate migration pass.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(journalID, forKey: .journalID)
        try container.encodeIfPresent(originalDate, forKey: .originalDate)
        try container.encodeIfPresent(trashedAt, forKey: .trashedAt)
        try container.encodeIfPresent(detectedDate, forKey: .detectedDate)
        // Only when the latch is closed with no value to carry it: `detectedDate`'s own
        // key presence already signals "ran" on the next read whenever it has a value, so
        // writing this alongside a real `detectedDate` would be redundant on every normal
        // entry. It is needed exactly when `detectedDate` is nil but the latch must still
        // read as closed — the ran-but-unreadable state a corrupted decode produces.
        if detectionRan && detectedDate == nil {
            try container.encode(true, forKey: .detectionRan)
        }
    }
}
