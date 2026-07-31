import Foundation

enum LiveTranscriptError: Error, Equatable {
    case posix(operation: String, code: Int32)
    case notOpen
    /// A record encoded to something containing a raw newline, which JSONL cannot
    /// represent. Thrown rather than trapped: this is the derived path, and §0's rule
    /// is that transcription may fail at any moment *without* touching capture.
    case multilineRecord
    /// A log exists but could not be read, so its tail is unknown. Refusing to open is
    /// the whole point — see `LiveTranscriptWriter.open()`.
    case unreadableExistingLog(String)
}

/// Whether the log is missing, unreadable, or readable — three answers, deliberately.
///
/// Collapsing them is issue #11, and it is the same mistake as #8: a failed read
/// interpreted as "nothing there" and then acted on. `DirectorySnapshot` already
/// learned this and carries an explicit `manifestCorrupt` rather than guessing.
enum LiveTranscriptSource: Equatable {
    /// No file. The honest "no transcript yet".
    case absent
    /// The file exists and we could not read it. **Not** the same as empty: any UI that
    /// offers "no transcript, re-derive?" would be wrong here, and a writer that resumed
    /// numbering from zero would append colliding `seq` values into it.
    case unreadable(String)
    case present(Data)
}

/// Append-only writer for `transcript/live.jsonl` (design §3).
///
/// **Durability deliberately matches the audio path rather than exceeding it.**
/// `SegmentStore.append` does a plain `writeAll` with no fsync and syncs at segment
/// close; this does the same. Rev 1 of the design specified fsync-per-record, which
/// is stricter than the audio it annotates, puts a synchronous barrier at speaking
/// cadence, and is self-defeating — it would make the torn-line case it plans for
/// nearly unreachable while buying durability the audio itself doesn't have.
///
/// There is no `.part` staging because there is no rewrite. A force-kill can leave a
/// half-written trailing line; `LiveTranscriptReader` discards it and every complete
/// prior line stays valid.
final class LiveTranscriptWriter {

    private let url: URL
    private let fd = FileDescriptorBox()
    private(set) var recordsWritten = 0
    /// Next `seq` to assign. Continues from the file's existing tail so reopening an
    /// interrupted capture doesn't restart numbering.
    private(set) var nextSeq = 0
    /// A write failed partway and left an unterminated line behind.
    private var tornTail = false

    init(captureDirectory: URL) {
        self.url = SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)
    }

    deinit { fd.closeIfOpen() }

    /// Create `transcript/` and open the log for appending.
    ///
    /// `O_APPEND` is what makes this safe across a crash-and-reopen: every write goes
    /// to the current end of file as one atomic positioning+write, so a torn tail from
    /// a previous run is appended *after*, never overwritten and never interleaved.
    func open() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Reopening must not reuse a descriptor slot — two append handles on one file
        // is a leak and a corruption source.
        fd.closeIfOpen()

        // Refuse to open a log we cannot read.
        //
        // This was the sharpest edge of issue #11, and it was a *writer* bug rather than
        // the reader nicety it was filed as: `(try? Data(contentsOf:)) ?? Data()` treated
        // an unreadable existing log as an empty one, so `nextSeq` restarted at 0 and
        // every subsequent append wrote a `seq` that collided with a record already in
        // the file. Unreachable while nothing constructs a writer; reachable the moment a
        // capture reopens after an interruption or a relaunch.
        //
        // Failing here costs the live transcript for this capture, which is derived and
        // re-derivable. Continuing costs the integrity of the one already on disk.
        let existing: Data
        switch LiveTranscriptReader.loadBytes(at: url) {
        case .absent:
            existing = Data()
        case .unreadable(let reason):
            throw LiveTranscriptError.unreadableExistingLog(reason)
        case .present(let data):
            existing = data
        }

        // Resume numbering past whatever survived the last run.
        //
        // `max(lastDecodableSeq + 1, completeLineCount)` rather than just the former:
        // a complete-but-undecodable line still *occupied* a sequence number, and the
        // record it held may be exactly the one a reader is trying to notice is
        // missing. Taking the line count as a floor guarantees seq never collides with
        // a record we failed to read.
        let survivors = LiveTranscriptReader.parse(existing)
        nextSeq = max(survivors.records.last.map { $0.seq + 1 } ?? 0, survivors.completeLines)

        let descriptor = Foundation.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            throw LiveTranscriptError.posix(operation: "open", code: errno)
        }
        fd.value = descriptor

        // Terminate a torn tail before appending anything.
        //
        // `O_APPEND` writes at the current end of file, so without this the first new
        // record lands *directly onto* the unterminated line a kill left behind,
        // fusing the two into one undecodable line and losing the new record as well
        // as the old. Closing the line keeps the damage to exactly the bytes that were
        // already lost. Costs one byte, and only when the previous run was killed.
        if let last = existing.last, last != UInt8(ascii: "\n") {
            try Self.writeAll(fd: descriptor, data: Data([UInt8(ascii: "\n")]))
        }
    }

    /// Append one committed record. Assigns `seq`; the caller supplies everything else.
    @discardableResult
    func append(_ record: TranscriptRecord) throws -> TranscriptRecord {
        guard fd.value >= 0 else { throw LiveTranscriptError.notOpen }
        var stamped = record
        stamped.seq = nextSeq

        var data = try CaptureCoding.lineEncoder().encode(stamped)
        // A JSONL line must not contain a raw newline or the reader's line split would
        // tear a valid record in half. This check already earned its keep once: the
        // manifest encoder is `.prettyPrinted`, so the obvious reuse was wrong.
        //
        // It throws rather than trapping. A `precondition` here would take the whole
        // app down mid-recording for a fault on the *derived* path — exactly the
        // coupling §0 forbids. Losing one record costs a re-derive; losing the process
        // costs the recording.
        guard !data.contains(UInt8(ascii: "\n")) else { throw LiveTranscriptError.multilineRecord }
        data.append(UInt8(ascii: "\n"))

        // A previous append that died mid-write (ENOSPC is the live case — the capture
        // path has its own disk-full handling) left an unterminated fragment. Without
        // this, the next record lands directly onto it and one undecodable line
        // swallows both. `open()` handles the same hazard across a process boundary;
        // ignoring it *within* one process was the gap.
        if tornTail {
            try Self.writeAll(fd: fd.value, data: Data([UInt8(ascii: "\n")]))
            tornTail = false
        }

        do {
            try Self.writeAll(fd: fd.value, data: data)
        } catch {
            tornTail = true
            throw error
        }
        nextSeq += 1
        recordsWritten += 1
        return stamped
    }

    /// Flush to stable storage. Called at the same commit boundaries the audio path
    /// uses — segment close and capture end — not per record.
    func sync() throws {
        guard fd.value >= 0 else { return }
        if fsync(fd.value) != 0 {
            throw LiveTranscriptError.posix(operation: "fsync", code: errno)
        }
    }

    /// Final sync + close. Safe to call twice.
    func close() throws {
        guard fd.value >= 0 else { return }
        try sync()
        fd.closeIfOpen()
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 { throw LiveTranscriptError.posix(operation: "write", code: errno) }
                offset += n
            }
        }
    }
}

/// Reads `transcript/live.jsonl`, discarding anything the last run didn't finish
/// writing (design §3).
enum LiveTranscriptReader {

    /// Every complete record, in file order.
    ///
    /// A trailing line with no terminating newline is by definition incomplete and is
    /// dropped — that is the expected shape after a force-kill, not an error. An
    /// *interior* line that fails to decode is skipped rather than truncating the read
    /// — losing one line beats discarding every valid line after it.
    ///
    /// Single-writer is a precondition, not a guarantee this type enforces. `O_APPEND`
    /// makes the *offset* atomic, but `writeAll` loops over short writes, so two
    /// concurrent writers could interleave mid-record and fuse two lines. The session
    /// actor owns exactly one writer per capture, which is what makes that unreachable.
    /// Everything a caller needs to decide what it is looking at.
    ///
    /// There is deliberately **no** convenience that returns a bare `[TranscriptRecord]`.
    /// One existed, it swallowed every failure into `[]`, and that is issue #11 — a
    /// reachable API that makes the wrong thing effortless gets used.
    struct LoadResult: Equatable {
        var source: LiveTranscriptSource = .absent
        var records: [TranscriptRecord] = []
        /// Complete lines in the file, decodable or not. Differs from `records.count`
        /// when a line is intact but undecodable, which is what `nextSeq` must respect
        /// and what tail-loss detection compares against.
        var completeLines: Int = 0

        var isUnreadable: Bool {
            if case .unreadable = source { return true }
            return false
        }
    }

    static func load(url: URL) -> LoadResult {
        switch loadBytes(at: url) {
        case .absent:
            return LoadResult(source: .absent)
        case .unreadable(let reason):
            return LoadResult(source: .unreadable(reason))
        case .present(let data):
            let parsed = parse(data)
            return LoadResult(source: .present(data),
                              records: parsed.records,
                              completeLines: parsed.completeLines)
        }
    }

    static func load(captureDirectory: URL) -> LoadResult {
        load(url: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
    }

    /// Absent and unreadable are different answers and must stay different all the way
    /// down. `fileReadNoSuchFile` is the only one that means "nothing here"; a
    /// permissions failure, an I/O error, or a truncated read do not.
    static func loadBytes(at url: URL) -> LiveTranscriptSource {
        do {
            return .present(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Whether the file lost its trailing line to a kill.
    ///
    /// `seq` cannot answer this — a torn tail is dropped on read, leaving a gapless
    /// `0..<n` with no gap to notice. The manifest can: `TranscriptRef.committedRecords`
    /// records how many lines were written and is only ever written on a clean close, so
    /// its absence *is* the signal that the app was killed and a short tail is expected.
    /// No footer line and no format change: the field already exists.
    enum Completeness: Equatable {
        /// No `TranscriptRef` — the capture never closed cleanly. Tail loss is expected
        /// here and is not a defect.
        case unknown
        case complete
        case truncated(missing: Int)
    }

    static func completeness(lines: Int, expected: Int?) -> Completeness {
        guard let expected else { return .unknown }
        return lines >= expected ? .complete : .truncated(missing: expected - lines)
    }

    /// Replay: fold the log back through the consolidator (issue #10).
    ///
    /// Reading records raw does **not** reproduce the live view. The log is append-only
    /// and cannot express either thing the consolidator does — a later result *revising*
    /// an overlapping earlier one, and an empty-text result *deleting* a span. Read raw,
    /// a revised phrase appears twice and a revoked one appears at all.
    ///
    /// The fix is to keep exactly one implementation of those rules and let the file
    /// stay dumb: `TranscriptConsolidator.apply` already knows them, is unit-tested, and
    /// is what produced the log in the first place. Records replay in file order as
    /// non-volatile results, which is precisely what was written.
    static func consolidate(_ records: [TranscriptRecord]) -> TranscriptConsolidator {
        var consolidator = TranscriptConsolidator()
        for record in records {
            consolidator.apply(TranscriptResult(record))
        }
        return consolidator
    }

    /// Decoded records plus how many complete lines the file held — the two differ
    /// when a line is complete but undecodable, which is what `nextSeq` has to respect.
    struct ParseResult: Equatable {
        var records: [TranscriptRecord] = []
        var completeLines: Int = 0
    }

    /// Split out so `LiveTranscriptWriter.open()` can reuse the one read it already
    /// needs for the torn-tail check rather than reading the file twice.
    static func parse(_ data: Data) -> ParseResult {
        guard !data.isEmpty else { return ParseResult() }

        let newline = UInt8(ascii: "\n")
        // No trailing newline → the last line was never committed. Everything up to
        // the final newline is intact.
        let complete: Data
        if data.last == newline {
            complete = data
        } else if let lastNewline = data.lastIndex(of: newline) {
            complete = data[..<data.index(after: lastNewline)]
        } else {
            return ParseResult()   // a single torn line and nothing else
        }

        let decoder = CaptureCoding.decoder()
        let lines = complete.split(separator: newline, omittingEmptySubsequences: true)
        return ParseResult(
            records: lines.compactMap { try? decoder.decode(TranscriptRecord.self, from: Data($0)) },
            completeLines: lines.count)
    }

}

/// Boxes the log's fd so a dropped writer (the "kill" case) closes it, leaving the
/// bytes already written intact on disk. Mirrors `SegmentStore`'s box for the same
/// reason.
private final class FileDescriptorBox {
    var value: Int32 = -1
    func closeIfOpen() { if value >= 0 { close(value); value = -1 } }
    deinit { closeIfOpen() }
}
