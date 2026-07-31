import Foundation

enum LiveTranscriptError: Error, Equatable {
    case posix(operation: String, code: Int32)
    case notOpen
    /// A record encoded to something containing a raw newline, which JSONL cannot
    /// represent. Thrown rather than trapped: this is the derived path, and §0's rule
    /// is that transcription may fail at any moment *without* touching capture.
    case multilineRecord
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

        let existing = (try? Data(contentsOf: url)) ?? Data()
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

        try Self.writeAll(fd: fd.value, data: data)
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
    static func read(url: URL) -> [TranscriptRecord] {
        parse((try? Data(contentsOf: url)) ?? Data()).records
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

    static func read(captureDirectory: URL) -> [TranscriptRecord] {
        read(url: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
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
