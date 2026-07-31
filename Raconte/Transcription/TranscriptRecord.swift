import Foundation
import CoreMedia

/// A `CMTime` in a form that survives JSON (design §3). Kept as the raw rational
/// rather than seconds so a revision's analyzer timebase round-trips exactly.
struct TranscriptTimeStamp: Codable, Sendable, Equatable {
    var value: Int64
    var timescale: Int32

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    init(_ time: CMTime) {
        self.value = time.value
        self.timescale = time.timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

/// One attributed run within a committed result — the flattened `AttributedString`
/// run attributes (design §3).
///
/// Feeds the M3 `transcript_segments` table and playback scrubbing, but is not
/// literally that table: `entryId` and `revisionId` are assigned at M3 import time,
/// because M2 has no entry concept and no database.
/// Frame bounds are **optional, not merely imprecise.** The SDK documents that a
/// transcript's runs need carry no time range at all, and that timed runs need not be
/// contiguous:
///
/// > The time ranges in the string should be in ascending order, but not necessarily
/// > contiguous, and the string can include runs without a time range attribute.
///
/// So "every run is timed" is contradicted by Apple's own documentation, not just
/// unverified on device. Same for `confidence` — `ConfidenceAttribute` carries no
/// guarantee of presence per run.
struct TranscriptRun: Codable, Sendable, Equatable {
    var text: String
    var captureFrameStart: Int64?
    var captureFrameEnd: Int64?
    /// Present only when the transcriber attributed one. `nil` is not "zero".
    var confidence: Double?

    init(text: String,
         captureFrameStart: Int64? = nil,
         captureFrameEnd: Int64? = nil,
         confidence: Double? = nil) {
        self.text = text
        self.captureFrameStart = captureFrameStart
        self.captureFrameEnd = captureFrameEnd
        self.confidence = confidence
    }
}

/// One committed result, as written to `transcript/live.jsonl` (design §3).
///
/// **Volatile results never appear here.** They are a UI-only layer; writing a
/// hypothesis the transcriber may withdraw would put retracted words in a journal.
struct TranscriptRecord: Codable, Sendable, Equatable {
    /// Monotonic within a file, starting at 0.
    ///
    /// Detects *interior* loss only. A torn trailing line is dropped on read, leaving a
    /// gapless `0..<n` with nothing to compare against — `seq` cannot tell a truncated
    /// file from a complete one, and an earlier version of this comment claimed it
    /// could. Tail loss is detected by comparing the line count against
    /// `TranscriptRef.committedRecords`, which is written only on a clean close; see
    /// `LiveTranscriptReader.completeness(lines:expected:)`.
    var seq: Int
    var text: String

    /// The durable, cross-revision truth: position in `final/recording.m4a`.
    var captureFrameStart: Int64
    var captureFrameEnd: Int64

    /// Revision-local, and **never comparable across revisions**.
    /// `bestAvailableAudioFormat` is asset- and device-dependent, so a later
    /// retranscription may run at an entirely different rate.
    var analyzerStart: TranscriptTimeStamp?
    var analyzerEnd: TranscriptTimeStamp?

    var runs: [TranscriptRun]
    var generator: String
    var locale: String

    init(seq: Int,
         text: String,
         captureFrameStart: Int64,
         captureFrameEnd: Int64,
         analyzerStart: TranscriptTimeStamp? = nil,
         analyzerEnd: TranscriptTimeStamp? = nil,
         runs: [TranscriptRun] = [],
         generator: String,
         locale: String) {
        self.seq = seq
        self.text = text
        self.captureFrameStart = captureFrameStart
        self.captureFrameEnd = captureFrameEnd
        self.analyzerStart = analyzerStart
        self.analyzerEnd = analyzerEnd
        self.runs = runs
        self.generator = generator
        self.locale = locale
    }

    var frameRange: FrameRange {
        FrameRange(start: captureFrameStart, end: captureFrameEnd)
    }

    /// Hand-written because Swift's synthesized decoder **ignores property defaults**.
    ///
    /// Verified, not assumed: a `var runs: [TranscriptRun] = []` still throws
    /// `keyNotFound` on a line without a `"runs"` key. Only `Optional` properties get
    /// `decodeIfPresent` from synthesis; a default value buys nothing at decode time.
    ///
    /// That mattered because `LiveTranscriptReader.parse` deliberately skips a line it
    /// cannot decode — right for one torn line, catastrophic when *every* line fails.
    /// Adding a field to this struct would therefore not have produced a version error;
    /// it would have silently erased every existing log and reported an empty transcript.
    ///
    /// So the additive fields decode leniently while the identity fields stay strict: a
    /// line missing `runs` is an older record and reads fine, a line missing `text` is
    /// garbage and still fails. No per-record version field — this codebase has no
    /// migration machinery, and the standing rule is to version when there is something
    /// to migrate.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        text = try container.decode(String.self, forKey: .text)
        captureFrameStart = try container.decode(Int64.self, forKey: .captureFrameStart)
        captureFrameEnd = try container.decode(Int64.self, forKey: .captureFrameEnd)
        generator = try container.decode(String.self, forKey: .generator)
        locale = try container.decode(String.self, forKey: .locale)

        analyzerStart = try container.decodeIfPresent(TranscriptTimeStamp.self, forKey: .analyzerStart)
        analyzerEnd = try container.decodeIfPresent(TranscriptTimeStamp.self, forKey: .analyzerEnd)
        runs = try container.decodeIfPresent([TranscriptRun].self, forKey: .runs) ?? []
    }
}

extension TranscriptRecord {
    /// The record a committed result becomes on disk. `seq` is the writer's to assign.
    init(_ result: TranscriptResult, generator: String, locale: String) {
        self.init(seq: 0,
                  text: result.text,
                  captureFrameStart: result.range.start,
                  captureFrameEnd: result.range.end,
                  analyzerStart: result.analyzerStart.map(TranscriptTimeStamp.init),
                  analyzerEnd: result.analyzerEnd.map(TranscriptTimeStamp.init),
                  runs: result.runs,
                  generator: generator,
                  locale: locale)
    }
}

extension TranscriptResult {
    /// A logged record read back as the result that produced it.
    ///
    /// Always non-volatile: the log holds only committed mutations by construction, and
    /// `finalizedThroughFrame` is deliberately `nil` — promotion already happened live
    /// and was written out as its own record, so re-deriving it on replay would promote
    /// twice.
    init(_ record: TranscriptRecord) {
        self.init(text: record.text,
                  range: record.frameRange,
                  isVolatile: false,
                  confidence: nil,
                  finalizedThroughFrame: nil,
                  runs: record.runs,
                  analyzerStart: record.analyzerStart?.cmTime,
                  analyzerEnd: record.analyzerEnd?.cmTime)
    }
}
