import Foundation

enum MarkerLogError: Error, Equatable {
    case posix(operation: String, code: Int32)
    case notOpen
    /// A marker encoded to something containing a raw newline, which JSONL cannot
    /// represent. Thrown rather than trapped: a marker is an annotation, and no
    /// annotation failure may take down a live recording (design §7).
    case multilineRecord
    /// A log exists but could not be read, so its tail is unknown. Refusing to open is
    /// the whole point — see `MarkerLogWriter.open()`.
    case unreadableExistingLog(String)
}

/// Whether the log is missing, unreadable, or readable — three answers, deliberately.
///
/// Collapsing them is issue #11, and design §7 restates it for markers: an unreadable
/// `markers.jsonl` must assign **no** voice attributes rather than being read as
/// "single-voice capture, nothing to see".
enum MarkerLogSource: Equatable {
    /// No file. The honest "no markers" — the common case, since a single-voice capture
    /// with no paragraph taps never creates one.
    case absent
    /// The file exists and we could not read it. **Not** the same as empty: a writer
    /// that resumed numbering from zero would append colliding `seq` values into it.
    case unreadable(String)
    case present(Data)
}

/// Append-only writer for `transcript/markers.jsonl` (design §4).
///
/// A deliberate structural copy of `LiveTranscriptWriter` rather than a generalization
/// of it: the design says "built like", and refactoring a shipped, reviewed writer
/// inside a feature step is the wrong risk. If a third JSONL log ever appears, factor
/// then. Durability matches the audio path — plain `writeAll`, no fsync per record,
/// `sync()` at commit boundaries — and `O_APPEND` is what makes a crash cost at most
/// the one line that was mid-write.
///
/// **Tail loss in this log is undetectable, by design.** The transcript can compare
/// against `TranscriptRef.committedRecords`; markers have no such count and no manifest
/// field, and `seq` cannot help — a torn tail is dropped on read, leaving a gapless
/// `0..<n` with no gap to notice. So there is deliberately **no** `completeness` API
/// here. The damage is bounded and visible: the final voice span runs long, which T7
/// surfaces and the owner can edit. Stated rather than papered over.
final class MarkerLogWriter {

    private let url: URL
    private let fd = FileDescriptorBox()
    private(set) var recordsWritten = 0
    /// Next `seq` to assign. Continues from the file's existing tail so reopening an
    /// interrupted capture doesn't restart numbering.
    private(set) var nextSeq = 0
    /// A write failed partway and left an unterminated line behind.
    private var tornTail = false

    init(captureDirectory: URL) {
        self.url = SegmentLayout.markerLogURL(captureDirectory: captureDirectory)
    }

    deinit { fd.closeIfOpen() }

    /// Create `transcript/` and open the log for appending.
    ///
    /// **Callers must open lazily, at the first append** — never at capture start. Any
    /// file under `transcript/` flips `holdsIrreplaceableArtifacts`, so a zero-byte log
    /// created eagerly would make every mis-tapped capture permanently undeletable
    /// (the T3 lesson, design appendix). This type does nothing on `init` for exactly
    /// that reason.
    ///
    /// `O_APPEND` is what makes this safe across a crash-and-reopen: every write goes to
    /// the current end of file as one atomic positioning+write, so a torn tail from a
    /// previous run is appended *after*, never overwritten and never interleaved.
    func open() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Reopening must not reuse a descriptor slot — two append handles on one file
        // is a leak and a corruption source.
        fd.closeIfOpen()

        // Refuse to open a log we cannot read. Reading an unreadable log as empty
        // restarts `nextSeq` at 0 and appends records whose `seq` collides with records
        // already in the file — the sharpest edge of issue #11, and a *writer* bug.
        // Failing here costs this capture's markers; continuing costs the integrity of
        // the ones already on disk.
        let existing: Data
        switch MarkerLogReader.loadBytes(at: url) {
        case .absent:
            existing = Data()
        case .unreadable(let reason):
            throw MarkerLogError.unreadableExistingLog(reason)
        case .present(let data):
            existing = data
        }

        // Resume numbering past whatever survived the last run.
        //
        // `max(lastDecodableSeq + 1, completeLineCount)` rather than just the former: a
        // complete-but-undecodable line still *occupied* a sequence number. Taking the
        // line count as a floor guarantees `seq` never collides with a record we failed
        // to read.
        let survivors = MarkerLogReader.parse(existing)
        nextSeq = max(survivors.markers.last.map { $0.seq + 1 } ?? 0, survivors.completeLines)

        let descriptor = Foundation.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            throw MarkerLogError.posix(operation: "open", code: errno)
        }
        fd.value = descriptor

        // Terminate a torn tail before appending anything.
        //
        // `O_APPEND` writes at the current end of file, so without this the first new
        // marker lands *directly onto* the unterminated line a kill left behind, fusing
        // the two into one undecodable line and losing the new marker as well as the
        // old. Closing the line keeps the damage to exactly the bytes already lost.
        if let last = existing.last, last != UInt8(ascii: "\n") {
            try Self.writeAll(fd: descriptor, data: Data([UInt8(ascii: "\n")]))
        }
    }

    /// Append one marker. Assigns `seq`; the caller supplies frame, kind, and voice.
    @discardableResult
    func append(_ marker: StructureMarker) throws -> StructureMarker {
        guard fd.value >= 0 else { throw MarkerLogError.notOpen }
        var stamped = marker
        stamped.seq = nextSeq

        var data = try CaptureCoding.lineEncoder().encode(stamped)
        // A JSONL line must not contain a raw newline or the reader's line split would
        // tear a valid record in half. Unreachable through the public API — JSON escapes
        // control characters — but it is what catches an accidental `encoder()`, which
        // is `.prettyPrinted` and would tear every line. It throws rather than trapping:
        // losing one marker costs an annotation, losing the process costs the recording.
        guard !data.contains(UInt8(ascii: "\n")) else { throw MarkerLogError.multilineRecord }
        data.append(UInt8(ascii: "\n"))

        // A previous append that died mid-write left an unterminated fragment. Without
        // this the next marker lands directly onto it and one undecodable line swallows
        // both. `open()` handles the same hazard across a process boundary; this is the
        // in-process half.
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
    /// uses — not per marker.
    func sync() throws {
        guard fd.value >= 0 else { return }
        if fsync(fd.value) != 0 {
            throw MarkerLogError.posix(operation: "fsync", code: errno)
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
                if n < 0 { throw MarkerLogError.posix(operation: "write", code: errno) }
                offset += n
            }
        }
    }
}

/// Reads `transcript/markers.jsonl`, discarding anything the last run didn't finish
/// writing (design §4).
enum MarkerLogReader {

    /// Everything a caller needs to decide what it is looking at.
    ///
    /// There is deliberately **no** convenience returning a bare `[StructureMarker]`:
    /// one existed on the transcript side, it swallowed every failure into `[]`, and
    /// that is issue #11. Here the same collapse would silently attribute a two-voice
    /// capture to nobody.
    struct LoadResult: Equatable {
        var source: MarkerLogSource = .absent
        var markers: [StructureMarker] = []
        /// Complete lines, decodable or not — what `nextSeq` must respect. Differs from
        /// `markers.count` when a line is intact but undecodable.
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
                              markers: parsed.markers,
                              completeLines: parsed.completeLines)
        }
    }

    static func load(captureDirectory: URL) -> LoadResult {
        load(url: SegmentLayout.markerLogURL(captureDirectory: captureDirectory))
    }

    /// Absent and unreadable are different answers and must stay different all the way
    /// down. `fileReadNoSuchFile` is the only one that means "nothing here"; a
    /// permissions failure, an I/O error, or a truncated read do not.
    static func loadBytes(at url: URL) -> MarkerLogSource {
        do {
            return .present(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Decoded markers plus how many complete lines the file held — the two differ when
    /// a line is complete but undecodable, which is what `nextSeq` has to respect.
    struct ParseResult: Equatable {
        var markers: [StructureMarker] = []
        var completeLines: Int = 0
    }

    /// Split out so `MarkerLogWriter.open()` can reuse the one read it already needs for
    /// the torn-tail check rather than reading the file twice.
    ///
    /// A trailing line with no terminating newline is by definition incomplete and is
    /// dropped — the expected shape after a force-kill, not an error. An *interior* line
    /// that fails to decode is skipped rather than truncating the read.
    static func parse(_ data: Data) -> ParseResult {
        guard !data.isEmpty else { return ParseResult() }

        let newline = UInt8(ascii: "\n")
        // No trailing newline → the last line was never committed. Everything up to the
        // final newline is intact.
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
            markers: lines.compactMap { try? decoder.decode(StructureMarker.self, from: Data($0)) },
            completeLines: lines.count)
    }
}

/// Boxes the log's fd so a dropped writer (the "kill" case) closes it, leaving the bytes
/// already written intact on disk. Mirrors `SegmentStore`'s box for the same reason.
private final class FileDescriptorBox {
    var value: Int32 = -1
    func closeIfOpen() { if value >= 0 { close(value); value = -1 } }
    deinit { closeIfOpen() }
}
