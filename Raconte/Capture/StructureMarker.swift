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

    enum Kind: Sendable, Equatable {
        case voice
        case paragraph
        /// Preserved and ignored (design §4): a kind written by a newer build must
        /// survive a read-rewrite cycle on this one. Costs one enum case; prevents a
        /// device on an older build from deleting a marker kind it doesn't understand.
        /// Reachable the moment M4 syncs.
        case unknown(String)

        init(string: String) {
            switch string {
            case "voice": self = .voice
            case "paragraph": self = .paragraph
            default: self = .unknown(string)
            }
        }

        /// Exact round-trip, including an unknown kind's original spelling.
        var string: String {
            switch self {
            case .voice: return "voice"
            case .paragraph: return "paragraph"
            case .unknown(let raw): return raw
            }
        }
    }

    var seq: Int
    var frame: Int64
    var kind: Kind
    /// Voice id — present only on `.voice` markers. Stored as a free string rather than
    /// a Bool (owner decision 3), so a third voice costs no migration; the two values
    /// the UI writes are `Voice.littleNico` / `Voice.bigNico`.
    var voice: String?

    init(seq: Int, frame: Int64, kind: Kind, voice: String? = nil) {
        self.seq = seq
        self.frame = frame
        self.kind = kind
        self.voice = voice
    }

    private enum CodingKeys: String, CodingKey {
        case seq, frame, kind, voice
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
    }

    /// `encodeIfPresent` for `voice`, so a paragraph line carries no `voice` key at all
    /// (design §4's example lines).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(frame, forKey: .frame)
        try container.encode(kind.string, forKey: .kind)
        try container.encodeIfPresent(voice, forKey: .voice)
    }
}

extension StructureMarker {
    /// Exactly two voices in the UI; storage stays a string (owner decision 3).
    enum Voice {
        static let littleNico = "ln"
        static let bigNico = "bn"
    }
}
