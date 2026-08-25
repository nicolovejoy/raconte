import Foundation

/// A CloudKit `recordName`, typed (M4 §2, `docs/plans/2026-08-17-m4-sync-implementation-plan.md`
/// "Locked decisions"). Every shape is prefixed and parseable — this amends the design
/// doc's original bare-ULID column for `Journal`/`Entry` (semantics unchanged, only the
/// wire name), because a bare ULID cannot be told apart from any other record's id by
/// `init?(rawValue:)` alone. Six shapes, one Crockford-base32 ULID or two per shape,
/// joined by `.`:
///
///     Journal       j.<journalULID>
///     Entry         e.<captureID>
///     AudioAsset    a.<captureID>.0
///     Revision      r.<revisionULID>            (the revision's own id, never its file number)
///     LiveLog       l.<captureID>
///     MarkerStream  m.<captureID>.<deviceID>
///     Image         i.<captureID>.<imageID>
///
/// `.audio` always addresses index `0`: the record model keeps the door open to
/// multiple audio assets per entry (design §0.3, "AudioAsset is its own record, 1..n
/// capable"), but nothing multi-recording is built (design §9) — so this type has no
/// index parameter yet, and `init?(rawValue:)` rejects any other index as garbage
/// rather than silently accepting a shape it doesn't actually model.
///
/// `.image` (image-capture design, "Sync mapping") embeds BOTH the captureID and the
/// image's own ULID, deliberately unlike `.revision(id:)`, which names only its own id:
/// a revision is independently addressable across a capture move (its `entryRef` is
/// what recovers the captureID on ingest), while an image is not — there is no
/// cross-capture image reference whose identity has to survive, so the captureID rides
/// in the name and no field has to be read back to know which entry an image belongs
/// to. Shape-identical to `.markerStream`'s two-ULID form, which is why
/// `init?(rawValue:)` keys them apart on the prefix alone.
enum SyncRecordName: Equatable, Hashable, Sendable {
    case journal(id: String)
    case entry(captureID: String)
    case audio(captureID: String)
    case revision(id: String)
    case liveLog(captureID: String)
    case markerStream(captureID: String, deviceID: String)
    case image(captureID: String, imageID: String)

    private static let journalPrefix = "j"
    private static let entryPrefix = "e"
    private static let audioPrefix = "a"
    private static let revisionPrefix = "r"
    private static let liveLogPrefix = "l"
    private static let markerStreamPrefix = "m"
    private static let imagePrefix = "i"
    private static let audioIndexSuffix = "0"
    private static let separator: Character = "."

    var rawValue: String {
        switch self {
        case .journal(let id):
            return "\(Self.journalPrefix)\(Self.separator)\(id)"
        case .entry(let captureID):
            return "\(Self.entryPrefix)\(Self.separator)\(captureID)"
        case .audio(let captureID):
            return "\(Self.audioPrefix)\(Self.separator)\(captureID)\(Self.separator)\(Self.audioIndexSuffix)"
        case .revision(let id):
            return "\(Self.revisionPrefix)\(Self.separator)\(id)"
        case .liveLog(let captureID):
            return "\(Self.liveLogPrefix)\(Self.separator)\(captureID)"
        case .markerStream(let captureID, let deviceID):
            return "\(Self.markerStreamPrefix)\(Self.separator)\(captureID)\(Self.separator)\(deviceID)"
        case .image(let captureID, let imageID):
            return "\(Self.imagePrefix)\(Self.separator)\(captureID)\(Self.separator)\(imageID)"
        }
    }

    /// Total: any string either parses to exactly one of the six shapes above or
    /// returns nil. Rejects a bare ULID (no prefix, no dot — it has nothing to key a
    /// `switch` off of), an unknown prefix, the wrong component count for a known
    /// prefix, an empty component (`"j."`, `"j..x"`), and — since every id/captureID/
    /// deviceID component is validated with `ULID.isWellFormed` (the shared "reject
    /// obvious garbage in a decoded identity field" helper, `ULID.swift`) — any
    /// component that merely *looks* dot-shaped but isn't a real 26-char Crockford id.
    init?(rawValue: String) {
        let components = rawValue
            .split(separator: Self.separator, omittingEmptySubsequences: false)
            .map(String.init)
        guard let prefix = components.first, components.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        switch prefix {
        case Self.journalPrefix:
            guard components.count == 2, ULID.isWellFormed(components[1]) else { return nil }
            self = .journal(id: components[1])
        case Self.entryPrefix:
            guard components.count == 2, ULID.isWellFormed(components[1]) else { return nil }
            self = .entry(captureID: components[1])
        case Self.audioPrefix:
            guard components.count == 3, ULID.isWellFormed(components[1]),
                  components[2] == Self.audioIndexSuffix else { return nil }
            self = .audio(captureID: components[1])
        case Self.revisionPrefix:
            guard components.count == 2, ULID.isWellFormed(components[1]) else { return nil }
            self = .revision(id: components[1])
        case Self.liveLogPrefix:
            guard components.count == 2, ULID.isWellFormed(components[1]) else { return nil }
            self = .liveLog(captureID: components[1])
        case Self.markerStreamPrefix:
            guard components.count == 3, ULID.isWellFormed(components[1]),
                  ULID.isWellFormed(components[2]) else { return nil }
            self = .markerStream(captureID: components[1], deviceID: components[2])
        case Self.imagePrefix:
            guard components.count == 3, ULID.isWellFormed(components[1]),
                  ULID.isWellFormed(components[2]) else { return nil }
            self = .image(captureID: components[1], imageID: components[2])
        default:
            return nil
        }
    }
}

/// One artifact's state as seen by a tree scan: which record it maps to, and a digest
/// of the source bytes that record's content is built from (T3 digest definitions —
/// see `SyncTreeScanner`). `bytes` is the length of exactly the bytes `sha256` was
/// computed over, for every case — deliberately, so a planner bug that compares only
/// `bytes` (same length, different content) is distinguishable from one that also
/// compares `sha256`.
struct SyncArtifactState: Equatable, Sendable {
    var name: SyncRecordName
    var sha256: String
    var bytes: Int
}
