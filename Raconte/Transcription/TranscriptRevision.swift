import Foundation

/// What produced a revision (design §4.2). Stored as its case name string on disk so
/// a foreign build's revision — one written by a newer version of this app, or another
/// device in a future sync — still round-trips: an unrecognized value is preserved
/// verbatim in `.unknown(raw)` rather than dropped.
enum RevisionSource: Sendable, Equatable {
    case machineLive, machineRetranscribe, userEdit, merge, `import`
    case unknown(String)

    init(string: String) {
        switch string {
        case "machineLive": self = .machineLive
        case "machineRetranscribe": self = .machineRetranscribe
        case "userEdit": self = .userEdit
        case "merge": self = .merge
        case "import": self = .import
        default: self = .unknown(string)
        }
    }

    /// Exact round-trip, including an unrecognized source's original spelling.
    var string: String {
        switch self {
        case .machineLive: return "machineLive"
        case .machineRetranscribe: return "machineRetranscribe"
        case .userEdit: return "userEdit"
        case .merge: return "merge"
        case .import: return "import"
        case .unknown(let raw): return raw
        }
    }

    /// One predicate in one place (design §2.1): whether this revision's *origin* is a
    /// human decision, not whether a human has ever touched the text. An unrecognized
    /// source counts as MACHINE lineage — the conservative default, since treating an
    /// unknown origin as human-authored would let it silently outrank a real edit in
    /// whatever precedence rule reads this later.
    var isHumanLineage: Bool {
        switch self {
        case .userEdit, .merge, .import: return true
        case .machineLive, .machineRetranscribe, .unknown: return false
        }
    }
}

/// How a span's frame bounds relate to the audio (design §4.2). Mirrors
/// `RevisionSource`'s `init(string:)`/`.string` pattern (F10, and Gate A finding I4): an
/// unrecognized raw value round-trips verbatim as `.unknown(raw)` rather than being
/// silently rewritten to `"none"` — a foreign span like `{"anchor":"approximate",
/// "frameStart":100,...}` keeps both its original anchor spelling AND its frames on
/// re-encode. Only an ABSENT key decodes to `.none` (see `TranscriptSpan.init(from:)`).
enum SpanAnchor: Sendable, Equatable {
    case exact, inherited, none
    case unknown(String)

    init(string: String) {
        switch string {
        case "exact": self = .exact
        case "inherited": self = .inherited
        case "none": self = .none
        default: self = .unknown(string)
        }
    }

    var string: String {
        switch self {
        case .exact: return "exact"
        case .inherited: return "inherited"
        case .none: return "none"
        case .unknown(let raw): return raw
        }
    }

    /// Whether this anchor claims usable frame bounds at all. `.none` obviously
    /// doesn't; an `.unknown` anchor answers the same way — frames under an anchoring
    /// scheme this build doesn't understand aren't safe to interpret, generalizing the
    /// "frameStart nil iff anchor == .none" invariant to "nil iff no usable bounds".
    var hasUsableBounds: Bool {
        switch self {
        case .exact, .inherited: return true
        case .none, .unknown: return false
        }
    }
}

/// Why a draft stopped accepting further writes (design §4.2). Unrecognized raw
/// values decode to `.unknown`.
enum DraftCloseReason: String, Sendable, Equatable {
    case sessionEnd, hourCap, machineArrival, recovered, unknown
}

/// One attributed run of text within a `TranscriptRevision` (design §4.2).
struct TranscriptSpan: Codable, Sendable, Equatable {
    var text: String               // strict
    var anchor: SpanAnchor         // absent key ⇒ .none; unknown raw ⇒ .unknown(raw)
    var frameStart: Int64?         // nil iff anchor.hasUsableBounds == false
    var frameEnd: Int64?
    var confidence: Double?        // key omitted entirely when nil
    var sourceRevisionID: String?  // key omitted when == containing revision's id

    init(text: String,
         anchor: SpanAnchor,
         frameStart: Int64? = nil,
         frameEnd: Int64? = nil,
         confidence: Double? = nil,
         sourceRevisionID: String? = nil) {
        self.text = text
        self.anchor = anchor
        self.frameStart = frameStart
        self.frameEnd = frameEnd
        self.confidence = confidence
        self.sourceRevisionID = sourceRevisionID
    }

    private enum CodingKeys: String, CodingKey {
        case text, anchor, frameStart, frameEnd, confidence, sourceRevisionID
    }

    /// Hand-written for the same reason as `StructureMarker`/`TranscriptRecord`:
    /// Swift's synthesized decoder ignores property defaults, and this type mixes
    /// strict identity fields with lenient additive ones. `text` is the only field
    /// whose absence is a real defect; everything else — including an unrecognized
    /// `anchor` — degrades to the safest reading rather than throwing.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)

        let rawAnchor = (try? container.decodeIfPresent(String.self, forKey: .anchor)) ?? nil
        anchor = rawAnchor.map(SpanAnchor.init(string:)) ?? .none

        frameStart = (try? container.decodeIfPresent(Int64.self, forKey: .frameStart)) ?? nil
        frameEnd = (try? container.decodeIfPresent(Int64.self, forKey: .frameEnd)) ?? nil
        confidence = (try? container.decodeIfPresent(Double.self, forKey: .confidence)) ?? nil
        sourceRevisionID = (try? container.decodeIfPresent(String.self, forKey: .sourceRevisionID)) ?? nil
    }

    /// `encodeIfPresent` for every optional field (§9.5 economies) — a span with no
    /// confidence or cross-revision attribution carries no such keys at all.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(anchor.string, forKey: .anchor)
        try container.encodeIfPresent(frameStart, forKey: .frameStart)
        try container.encodeIfPresent(frameEnd, forKey: .frameEnd)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(sourceRevisionID, forKey: .sourceRevisionID)
    }

    /// The span's real attribution (design §9.5 economy, Gate A finding I5): encoding
    /// omits `sourceRevisionID` when it equals the containing revision's own id — the
    /// overwhelmingly common case, a span that originates where it lives — so a reader
    /// must resolve an absent value back to that revision's id rather than reading
    /// "absent" as "unattributed". The one reader for that rule, so every future
    /// consumer agrees with it. Write-side enforcement (never writing a redundant equal
    /// id) is deferred to whichever of T6c/T6e first constructs spans.
    func resolvedSourceRevisionID(in revision: TranscriptRevision) -> String {
        sourceRevisionID ?? revision.id
    }
}

/// One immutable node in the revision chain (design §4.2). Content-addressed by `id`
/// (a ULID); `parentID` and `basedOnMachineID` are how a chain and its human/machine
/// lineage are reconstructed, not stored structure.
struct TranscriptRevision: Codable, Sendable, Equatable {
    var id: String                 // ULID — strict
    var source: RevisionSource     // strict KEY presence; unknown raw → .unknown(raw)
    var createdAt: Date            // strict
    var spans: [TranscriptSpan]    // KEY must be present; may be empty — strict key
    var parentID: String?          // lenient (absent = root)
    var basedOnMachineID: String?  // lenient
    var generator: String?         // lenient …
    var locale: String?
    var coverageFrames: Int64?
    var skippedRanges: [FrameRange]?
    var deviceID: String?
    var closedBy: DraftCloseReason?

    init(id: String,
         source: RevisionSource,
         createdAt: Date,
         spans: [TranscriptSpan],
         parentID: String? = nil,
         basedOnMachineID: String? = nil,
         generator: String? = nil,
         locale: String? = nil,
         coverageFrames: Int64? = nil,
         skippedRanges: [FrameRange]? = nil,
         deviceID: String? = nil,
         closedBy: DraftCloseReason? = nil) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.spans = spans
        self.parentID = parentID
        self.basedOnMachineID = basedOnMachineID
        self.generator = generator
        self.locale = locale
        self.coverageFrames = coverageFrames
        self.skippedRanges = skippedRanges
        self.deviceID = deviceID
        self.closedBy = closedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, createdAt, spans, parentID, basedOnMachineID, generator,
             locale, coverageFrames, skippedRanges, deviceID, closedBy
    }

    /// Hand-written because Swift's synthesized decoder ignores property defaults
    /// (verified repeatedly elsewhere in this codebase — see `TranscriptRecord`,
    /// `StructureMarker`). `id`/`source`/`createdAt`/`spans` are identity: a revision
    /// missing any of them is not a revision and decoding must fail loudly rather than
    /// silently drop it. Everything else is additive and decodes to `nil` if absent —
    /// a future field or an older revision file must not make every revision file
    /// unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = RevisionSource(string: try container.decode(String.self, forKey: .source))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        spans = try container.decode([TranscriptSpan].self, forKey: .spans)

        parentID = (try? container.decodeIfPresent(String.self, forKey: .parentID)) ?? nil
        basedOnMachineID = (try? container.decodeIfPresent(String.self, forKey: .basedOnMachineID)) ?? nil
        generator = (try? container.decodeIfPresent(String.self, forKey: .generator)) ?? nil
        locale = (try? container.decodeIfPresent(String.self, forKey: .locale)) ?? nil
        coverageFrames = (try? container.decodeIfPresent(Int64.self, forKey: .coverageFrames)) ?? nil
        skippedRanges = (try? container.decodeIfPresent([FrameRange].self, forKey: .skippedRanges)) ?? nil
        deviceID = (try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? nil

        let rawClosedBy = (try? container.decodeIfPresent(String.self, forKey: .closedBy)) ?? nil
        closedBy = rawClosedBy.map { DraftCloseReason(rawValue: $0) ?? .unknown }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source.string, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(spans, forKey: .spans)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(basedOnMachineID, forKey: .basedOnMachineID)
        try container.encodeIfPresent(generator, forKey: .generator)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(coverageFrames, forKey: .coverageFrames)
        try container.encodeIfPresent(skippedRanges, forKey: .skippedRanges)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(closedBy?.rawValue, forKey: .closedBy)
    }
}

/// The head file's cached digest of the current revision (design §4.2) — enough to
/// render a library row without opening the revision file it summarizes.
struct TranscriptHeadSummary: Codable, Sendable, Equatable {
    var id: String
    var fileNumber: Int
    var source: RevisionSource
    var createdAt: Date
    var characterCount: Int
    var firstLine: String
    var isForked: Bool
    /// The row's ACTUAL preview (T7 Task 3 fix round 1, Important 3): whitespace-
    /// collapsed across EVERY line — not just the first — and truncated with a visible
    /// "…" via the same `EntrySnippet.make` the live.jsonl-fallback path already uses,
    /// computed once here so the row never needs the full body to reproduce it.
    /// `firstLine` above is UNCHANGED and stays first-line-only, 120 chars, no
    /// ellipsis — it has its own consumer (`detachedMachineRevisions`'s history-panel
    /// list item, §12.8), and this is a separate cache slot for the primary row
    /// preview, not a redefinition of what `firstLine` means. Additive + LENIENT
    /// (absent decodes to `firstLine` as a safe, if less accurate, stand-in) rather
    /// than strict: this type decodes inside `TranscriptHead.init(from:)`'s `current`
    /// field, which is already wrapped in `try?` — a required-field addition here
    /// would make an old head's `current` silently decode to `nil` while the OUTER
    /// `TranscriptHead`'s other fields still decode fine, corrupting the TRUST
    /// condition itself (a head with no `current` but otherwise-matching bookkeeping
    /// would wrongly look trustworthy) rather than just staling the preview. Self-heals
    /// the same way every other cache miss in this format does: the next rebuild —
    /// forced by any trust-invalidating event, or a real write — recomputes and
    /// persists the accurate value.
    var snippet: String

    init(id: String,
         fileNumber: Int,
         source: RevisionSource,
         createdAt: Date,
         characterCount: Int,
         firstLine: String,
         isForked: Bool,
         snippet: String) {
        self.id = id
        self.fileNumber = fileNumber
        self.source = source
        self.createdAt = createdAt
        self.characterCount = characterCount
        self.firstLine = firstLine
        self.isForked = isForked
        self.snippet = snippet
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileNumber, source, createdAt, characterCount, firstLine, isForked, snippet
    }

    /// `id`/`fileNumber`/`source`/`createdAt`/`characterCount`/`firstLine`/`isForked`
    /// are identity for the summary they name — strict. `source` still decodes an
    /// unrecognized raw value to `.unknown(raw)` rather than throwing (F10); only the
    /// *key* is required. `snippet` is the one additive, lenient field — see its own
    /// doc comment for why leniency (not strictness) is the safe choice here.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileNumber = try container.decode(Int.self, forKey: .fileNumber)
        source = RevisionSource(string: try container.decode(String.self, forKey: .source))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        firstLine = try container.decode(String.self, forKey: .firstLine)
        isForked = try container.decode(Bool.self, forKey: .isForked)
        snippet = (try? container.decodeIfPresent(String.self, forKey: .snippet)) ?? firstLine
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileNumber, forKey: .fileNumber)
        try container.encode(source.string, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(characterCount, forKey: .characterCount)
        try container.encode(firstLine, forKey: .firstLine)
        try container.encode(isForked, forKey: .isForked)
        try container.encode(snippet, forKey: .snippet)
    }
}

/// One canonical revision file's number and its on-disk byte size, at the time this
/// was recorded (T7 Task 3 fix round 1, Important 1) — the cheap integrity
/// fingerprint `TranscriptRevisionStore.validatedHead`'s trust condition checks
/// against a fresh stat before serving a cached `TranscriptHead` as-is. A file's NAME
/// staying put is not proof its BYTES did — truncation, a partial/interrupted write,
/// or a cloud-eviction placeholder all change size while leaving `revisionFiles`/
/// `unreadableFiles` (both keyed on filename, never content) none the wiser.
/// Deliberately does NOT catch same-size corruption — an accepted, owner-ruled
/// residual gap (see `TranscriptRevisionStoreTests
/// .testSameSizeCorruptionIsAnAcceptedGapNotCaughtByTheIntegrityCheck`).
struct RevisionFileSize: Codable, Sendable, Equatable {
    var file: Int
    var byteSize: Int64

    init(file: Int, byteSize: Int64) {
        self.file = file
        self.byteSize = byteSize
    }

    private enum CodingKeys: String, CodingKey {
        case file, byteSize
    }

    /// Hand-written (T7 Task 3 fix round 2), matching this wire-format family's
    /// additive-lenient / identity-strict convention (`TranscriptHead`,
    /// `TranscriptHeadSummary`, `TranscriptRevision`) even though both fields here are
    /// identity-strict TODAY and a synthesized decoder would behave identically right
    /// now. The reason is the family's own repeated lesson (§11: Swift's synthesized
    /// decoder ignores property defaults, which would have silently erased every
    /// `live.jsonl` record rather than erroring): `[RevisionFileSize]` decodes inside
    /// `TranscriptHead.init(from:)`'s `fileSizes` field, itself wrapped in `try?` for
    /// leniency (fix round 1). A synthesized decoder here means the NEXT additive
    /// field added to this type is strict by default with no decision point — a
    /// single array element failing to decode blanks the WHOLE `fileSizes` array back
    /// to `[]`, which is the exact "every head permanently untrusted" bug fix round 1
    /// just fixed, arriving again silently. A hand-written `init(from:)` forces that
    /// decision to be made explicitly, in this one place, when it matters.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(Int.self, forKey: .file)
        byteSize = try container.decode(Int64.self, forKey: .byteSize)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(byteSize, forKey: .byteSize)
    }
}

/// `transcript/head.json` (design §4.2): the fast-path pointer at the tip of the
/// chain, plus enough bookkeeping for a reader to validate itself without re-walking
/// every revision file on every read.
struct TranscriptHead: Codable, Sendable, Equatable {
    var current: TranscriptHeadSummary?
    var revisionFiles: [Int]       // every canonical-<n> filename seen, readable or not
    var unreadableFiles: [Int]     // what makes head validation a fixed point (F6)
    var revisionCount: Int
    /// True when `transcript/` itself could not be listed at build time — as opposed
    /// to a specific `canonical-<n>.json` failing to decode, which is what
    /// `unreadableFiles` tracks. Additive (T6b, after the format froze at Gate A):
    /// absent on a pre-existing `head.json` decodes to `false`, the only value such a
    /// head could have meant.
    var listingUnreadable: Bool
    /// The integrity fingerprint (T7 Task 3 fix round 1, Important 1) — one entry per
    /// file named in `revisionFiles`, readable or not. Additive + LENIENT (absent
    /// decodes to `[]`, matching a head written before this field existed), but that
    /// absence is DELIBERATELY treated as UNTRUSTED by
    /// `TranscriptRevisionStore.sizesStillMatch` rather than as "nothing to check" —
    /// the owner's explicit ruling: a head with no recorded sizes forces one rebuild,
    /// which then persists the sizes and self-heals per §4.8's disposable-cache
    /// philosophy, exactly like every other trust-invalidating cause already does.
    var fileSizes: [RevisionFileSize]

    init(current: TranscriptHeadSummary?,
         revisionFiles: [Int],
         unreadableFiles: [Int],
         revisionCount: Int,
         listingUnreadable: Bool = false,
         fileSizes: [RevisionFileSize] = []) {
        self.current = current
        self.revisionFiles = revisionFiles
        self.unreadableFiles = unreadableFiles
        self.revisionCount = revisionCount
        self.listingUnreadable = listingUnreadable
        self.fileSizes = fileSizes
    }

    private enum CodingKeys: String, CodingKey {
        case current, revisionFiles, unreadableFiles, revisionCount, listingUnreadable, fileSizes
    }

    /// `current`, `listingUnreadable`, and `fileSizes` are the lenient fields — a
    /// brand-new capture with no revisions yet has no current summary, a head written
    /// before `listingUnreadable` existed has no opinion on it, and a head written
    /// before `fileSizes` existed has none recorded; all three must decode to their
    /// safe default rather than throw. The three original bookkeeping arrays/count are
    /// identity for a head file: a head record missing them is not a valid fixed point
    /// and must fail loudly.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = (try? container.decodeIfPresent(TranscriptHeadSummary.self, forKey: .current)) ?? nil
        revisionFiles = try container.decode([Int].self, forKey: .revisionFiles)
        unreadableFiles = try container.decode([Int].self, forKey: .unreadableFiles)
        revisionCount = try container.decode(Int.self, forKey: .revisionCount)
        listingUnreadable = (try? container.decodeIfPresent(Bool.self, forKey: .listingUnreadable)) ?? false
        fileSizes = (try? container.decodeIfPresent([RevisionFileSize].self, forKey: .fileSizes)) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(current, forKey: .current)
        try container.encode(revisionFiles, forKey: .revisionFiles)
        try container.encode(unreadableFiles, forKey: .unreadableFiles)
        try container.encode(revisionCount, forKey: .revisionCount)
        try container.encode(listingUnreadable, forKey: .listingUnreadable)
        try container.encode(fileSizes, forKey: .fileSizes)
    }
}

/// `transcript/draft.json` (design §4.2): the mutable in-progress edit that has not
/// yet been closed into an immutable `TranscriptRevision`.
struct TranscriptDraft: Codable, Sendable, Equatable {
    var captureID: String          // strict — self-identifying tripwire (design §13 tail)
    var parentID: String?          // revision the draft was opened against
    var basedOnMachineID: String?
    var openedAt: Date             // strict
    var lastWriteAt: Date          // strict
    var text: String               // strict

    init(captureID: String,
         parentID: String? = nil,
         basedOnMachineID: String? = nil,
         openedAt: Date,
         lastWriteAt: Date,
         text: String) {
        self.captureID = captureID
        self.parentID = parentID
        self.basedOnMachineID = basedOnMachineID
        self.openedAt = openedAt
        self.lastWriteAt = lastWriteAt
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case captureID, parentID, basedOnMachineID, openedAt, lastWriteAt, text
    }

    /// `captureID` is deliberately strict, not merely present-because-required: design
    /// §13 uses it as a self-identifying tripwire, so a draft file that doesn't name
    /// its own capture is corrupt rather than merely old. `parentID`/`basedOnMachineID`
    /// are lenient — a draft opened against a fresh capture with no prior revision has
    /// neither.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureID = try container.decode(String.self, forKey: .captureID)
        parentID = (try? container.decodeIfPresent(String.self, forKey: .parentID)) ?? nil
        basedOnMachineID = (try? container.decodeIfPresent(String.self, forKey: .basedOnMachineID)) ?? nil
        openedAt = try container.decode(Date.self, forKey: .openedAt)
        lastWriteAt = try container.decode(Date.self, forKey: .lastWriteAt)
        text = try container.decode(String.self, forKey: .text)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureID, forKey: .captureID)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(basedOnMachineID, forKey: .basedOnMachineID)
        try container.encode(openedAt, forKey: .openedAt)
        try container.encode(lastWriteAt, forKey: .lastWriteAt)
        try container.encode(text, forKey: .text)
    }
}
