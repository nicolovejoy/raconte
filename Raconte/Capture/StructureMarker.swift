import Foundation

/// One capture-time observation about the audio that the audio does not contain
/// (design §0).
///
/// `frame` is the **raw** tap frame on the capture-frame axis — the same axis as
/// `StampedChunk.startFrame` and `SegmentSidecar.startFrameOffset`, i.e. position in
/// `final/recording.m4a`. It is stored untouched forever; snapping to a word gap
/// (`MarkerSnapping`) is derived on read and re-derivable, so a better snapping rule
/// later improves every marker already on disk.
struct StructureMarker: Codable, Sendable, Equatable {

    // Hashable so the UI can key per-kind state (#63's flash overlays) — synthesized,
    // no effect on the string wire format below.
    enum Kind: Sendable, Equatable, Hashable {
        case voice
        case paragraph
        /// Correction (T7 Task 6, locked decision 5 — raw taps are immutable):
        /// retracts an earlier record via `retractsSeq`. A retract of a seq that does
        /// not exist is ignored, not an error (`MarkerCorrections.effectiveMarkers`).
        case correctionRetract
        /// Correction: the voice at an existing boundary was wrong. Carries `frame` +
        /// the correct `voice`, exactly like a raw `.voice` tap's fields, but written
        /// as its own kind so it is never confused with a raw observation.
        case correctionVoice
        /// Correction: a boundary the owner never tapped (Q3, new scope). Carries
        /// `frame` — the covering span's own start frame, computed by the writer from
        /// the word the owner picked, never a value scrubbed to by hand.
        case correctionBoundaryAdd
        /// Preserved and ignored (design §4): a kind written by a newer build must
        /// survive a read-rewrite cycle on this one. Costs one enum case; prevents a
        /// device on an older build from deleting a marker kind it doesn't understand.
        /// Reachable the moment M4 syncs.
        case unknown(String)

        init(string: String) {
            switch string {
            case "voice": self = .voice
            case "paragraph": self = .paragraph
            case "correctionRetract": self = .correctionRetract
            case "correctionVoice": self = .correctionVoice
            case "correctionBoundaryAdd": self = .correctionBoundaryAdd
            default: self = .unknown(string)
            }
        }

        /// Exact round-trip, including an unknown kind's original spelling.
        var string: String {
            switch self {
            case .voice: return "voice"
            case .paragraph: return "paragraph"
            case .correctionRetract: return "correctionRetract"
            case .correctionVoice: return "correctionVoice"
            case .correctionBoundaryAdd: return "correctionBoundaryAdd"
            case .unknown(let raw): return raw
            }
        }
    }

    var seq: Int
    var frame: Int64
    var kind: Kind
    /// Voice id — present only on `.voice` and `.correctionVoice` markers. Stored as a
    /// free string rather than a Bool (owner decision 3), so a third voice costs no
    /// migration; the two values the UI writes are `Voice.littleNico` / `Voice.bigNico`.
    var voice: String?
    /// The seq of the record this one retracts — present only on `.correctionRetract`
    /// markers (T7 Task 6). A free-standing field rather than reusing `frame` (which a
    /// retract has no honest value for) or `seq` itself (always this record's OWN
    /// identity, assigned by the writer, never the target's).
    var retractsSeq: Int?

    init(seq: Int, frame: Int64, kind: Kind, voice: String? = nil, retractsSeq: Int? = nil) {
        self.seq = seq
        self.frame = frame
        self.kind = kind
        self.voice = voice
        self.retractsSeq = retractsSeq
    }

    private enum CodingKeys: String, CodingKey {
        case seq, frame, kind, voice, retractsSeq
    }

    /// Hand-written because Swift's synthesized decoder **ignores property defaults**
    /// (T3 rev 3, verified): a `var voice: String? = nil` would still be fine, but any
    /// future non-optional additive field would throw `keyNotFound` and — combined with
    /// a parser that skips undecodable lines — silently erase the log rather than error.
    ///
    /// Identity fields (`seq`, `frame`, `kind`) strict; additive fields lenient. An
    /// unrecognized `kind` *value* is `.unknown`; a missing `kind` *key* throws, because
    /// a marker with no kind is not a marker.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        frame = try container.decode(Int64.self, forKey: .frame)
        kind = Kind(string: try container.decode(String.self, forKey: .kind))
        // `try?` and not `try`: a garbage voice costs the attribute, never the frame.
        voice = (try? container.decodeIfPresent(String.self, forKey: .voice)) ?? nil
        retractsSeq = (try? container.decodeIfPresent(Int.self, forKey: .retractsSeq)) ?? nil
    }

    /// `encodeIfPresent` for `voice`/`retractsSeq`, so a paragraph line carries neither
    /// key at all (design §4's example lines).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(frame, forKey: .frame)
        try container.encode(kind.string, forKey: .kind)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encodeIfPresent(retractsSeq, forKey: .retractsSeq)
    }
}

extension StructureMarker {
    /// Exactly two voices in the UI; storage stays a string (owner decision 3).
    enum Voice {
        static let littleNico = "ln"
        static let bigNico = "bn"
    }
}
