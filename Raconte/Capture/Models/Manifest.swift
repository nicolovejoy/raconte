import Foundation

/// One appended entry in the manifest's interruption log (design §1/§2).
/// `endedAt`/`resumed` are nil while an interruption is ongoing.
struct InterruptionLogEntry: Codable, Sendable, Equatable {
    var kind: String
    var beganAt: Date
    var endedAt: Date?
    var resumed: Bool?
}

/// Reference to the finalized AAC-LC file. Fields stay explicitly `null` until
/// finalization fills them (design §1 shows them as null, not absent).
struct FinalRef: Codable, Sendable, Equatable {
    var path: String
    var verifiedAt: Date?
    var durationFrames: Int?

    init(path: String = "final/recording.m4a", verifiedAt: Date? = nil, durationFrames: Int? = nil) {
        self.path = path
        self.verifiedAt = verifiedAt
        self.durationFrames = durationFrames
    }

    enum CodingKeys: String, CodingKey { case path, verifiedAt, durationFrames }

    // Custom encode so nil fields serialize as explicit `null` per the §1 schema.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(verifiedAt, forKey: .verifiedAt)
        try c.encode(durationFrames, forKey: .durationFrames)
    }
}

/// Capture-level journal and single source of truth for identity + state
/// (design §1/§2). Written atomically on every state transition and on
/// segment rotation. Advisory for segment *content* (the segments directory
/// is authoritative); authoritative only for identity, format, and state.
struct Manifest: Codable, Sendable, Equatable {
    var captureID: String
    var schemaVersion: Int
    var createdAt: Date
    var state: CaptureState
    /// Monotonic; disambiguates concurrent recoveries. Increments on every write.
    var stateSeq: Int
    var stateUpdatedAt: Date
    var format: AudioFormatDescriptor
    /// Count of finalized segments known to the manifest (may lag the filesystem).
    var segmentCount: Int
    /// Cumulative frames as of the last manifest write.
    var lastKnownFrameOffset: Int
    var interruptions: [InterruptionLogEntry]
    var final: FinalRef

    static let currentSchemaVersion = 1

    init(captureID: String,
         schemaVersion: Int = Manifest.currentSchemaVersion,
         createdAt: Date,
         state: CaptureState,
         stateSeq: Int,
         stateUpdatedAt: Date,
         format: AudioFormatDescriptor,
         segmentCount: Int = 0,
         lastKnownFrameOffset: Int = 0,
         interruptions: [InterruptionLogEntry] = [],
         final: FinalRef = FinalRef()) {
        self.captureID = captureID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.state = state
        self.stateSeq = stateSeq
        self.stateUpdatedAt = stateUpdatedAt
        self.format = format
        self.segmentCount = segmentCount
        self.lastKnownFrameOffset = lastKnownFrameOffset
        self.interruptions = interruptions
        self.final = final
    }
}
