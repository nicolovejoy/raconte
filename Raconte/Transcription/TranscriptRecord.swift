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
struct TranscriptRun: Codable, Sendable, Equatable {
    var text: String
    var captureFrameStart: Int64
    var captureFrameEnd: Int64
    /// Present only when the transcriber attributed one. `nil` is not "zero".
    var confidence: Double?
}

/// One committed result, as written to `transcript/live.jsonl` (design §3).
///
/// **Volatile results never appear here.** They are a UI-only layer; writing a
/// hypothesis the transcriber may withdraw would put retracted words in a journal.
struct TranscriptRecord: Codable, Sendable, Equatable {
    /// Monotonic within a file, starting at 0. Survives a torn trailing line, so a
    /// reader can tell "the last record is missing" from "the file is complete".
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
}
