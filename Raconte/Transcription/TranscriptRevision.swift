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

/// How a span's frame bounds relate to the audio (design §4.2). Unrecognized raw
/// values decode to `.none` rather than throwing — the same F10 leniency as
/// `RevisionSource`, but here there is no case to preserve the raw spelling in,
/// because `.none` is already the correct fallback: no anchor means no frame bounds.
enum SpanAnchor: String, Sendable, Equatable {
    case exact, inherited, none
}

/// Why a draft stopped accepting further writes (design §4.2). Unrecognized raw
/// values decode to `.unknown`.
enum DraftCloseReason: String, Sendable, Equatable {
    case sessionEnd, hourCap, machineArrival, recovered, unknown
}

/// One attributed run of text within a `TranscriptRevision` (design §4.2).
struct TranscriptSpan: Codable, Sendable, Equatable {
    var text: String               // strict
    var anchor: SpanAnchor         // absent OR unknown raw ⇒ .none
    var frameStart: Int64?         // nil iff anchor == .none
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
        anchor = rawAnchor.flatMap(SpanAnchor.init(rawValue:)) ?? .none

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
        try container.encode(anchor.rawValue, forKey: .anchor)
        try container.encodeIfPresent(frameStart, forKey: .frameStart)
        try container.encodeIfPresent(frameEnd, forKey: .frameEnd)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(sourceRevisionID, forKey: .sourceRevisionID)
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

    init(id: String,
         fileNumber: Int,
         source: RevisionSource,
         createdAt: Date,
         characterCount: Int,
         firstLine: String,
         isForked: Bool) {
        self.id = id
        self.fileNumber = fileNumber
        self.source = source
        self.createdAt = createdAt
        self.characterCount = characterCount
        self.firstLine = firstLine
        self.isForked = isForked
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileNumber, source, createdAt, characterCount, firstLine, isForked
    }

    /// Every field here is identity for the summary it names — there is no additive
    /// field yet, so all are strict. `source` still decodes an unrecognized raw value
    /// to `.unknown(raw)` rather than throwing (F10); only the *key* is required.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileNumber = try container.decode(Int.self, forKey: .fileNumber)
        source = RevisionSource(string: try container.decode(String.self, forKey: .source))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        firstLine = try container.decode(String.self, forKey: .firstLine)
        isForked = try container.decode(Bool.self, forKey: .isForked)
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
    }
}

/// `transcript/head.json` (design §4.2): the fast-path pointer at the tip of the
/// chain, plus enough bookkeeping for a reader to validate itself without re-walking
/// every revision file on every read.
struct TranscriptHead: Codable, Sendable, Equatable {
    var current: TranscriptHeadSummary?
    var revisionFiles: [Int]
    var unreadableFiles: [Int]     // what makes head validation a fixed point (F6)
    var revisionCount: Int

    init(current: TranscriptHeadSummary?,
         revisionFiles: [Int],
         unreadableFiles: [Int],
         revisionCount: Int) {
        self.current = current
        self.revisionFiles = revisionFiles
        self.unreadableFiles = unreadableFiles
        self.revisionCount = revisionCount
    }

    private enum CodingKeys: String, CodingKey {
        case current, revisionFiles, unreadableFiles, revisionCount
    }

    /// `current` is the one lenient field — a brand-new capture with no revisions yet
    /// has no current summary, and that must decode to `nil`, not throw. The three
    /// bookkeeping arrays/count are identity for a head file: a head record missing
    /// them is not a valid fixed point and must fail loudly.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = (try? container.decodeIfPresent(TranscriptHeadSummary.self, forKey: .current)) ?? nil
        revisionFiles = try container.decode([Int].self, forKey: .revisionFiles)
        unreadableFiles = try container.decode([Int].self, forKey: .unreadableFiles)
        revisionCount = try container.decode(Int.self, forKey: .revisionCount)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(current, forKey: .current)
        try container.encode(revisionFiles, forKey: .revisionFiles)
        try container.encode(unreadableFiles, forKey: .unreadableFiles)
        try container.encode(revisionCount, forKey: .revisionCount)
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
