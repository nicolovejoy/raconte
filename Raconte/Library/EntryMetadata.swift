import Foundation

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

    /// Soft-delete tombstone (M3 T5). The field lands now so the format does not churn
    /// once trash ships; nothing writes it yet.
    var trashedAt: Date?

    init(journalID: String? = nil, originalDate: Date? = nil, trashedAt: Date? = nil) {
        self.journalID = journalID
        self.originalDate = originalDate
        self.trashedAt = trashedAt
    }

    /// What an absent `entry.json` means. An unfiled, un-backdated, live entry.
    static let defaults = EntryMetadata()

    var isTrashed: Bool { trashedAt != nil }

    /// True when the sidecar carries nothing a default wouldn't supply — i.e. writing it
    /// is optional. Callers may use this to avoid creating a file with no information in
    /// it, which also keeps `holdsIrreplaceableArtifacts` honest.
    var isDefault: Bool { self == Self.defaults }

    /// The entry's effective date: the backdate if set, otherwise the capture's own.
    func effectiveDate(capturedAt: Date) -> Date { originalDate ?? capturedAt }

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
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
    }

    /// Encoded without nil keys (the default `KeyEncodingStrategy` behaviour for
    /// `Optional`), so an unfiled entry's sidecar is literally `{}` and adding a field
    /// later cannot change what an old file means.
}
