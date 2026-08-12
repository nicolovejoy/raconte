import Foundation

/// T7 §7: the per-entry metadata audit log, `entry-log.jsonl` — a sibling of `entry.json`
/// (`SegmentLayout.entryLogURL`), **not** inside `transcript/`. Local-only, unsynced, and
/// deleted with the entry it audits (§7, struck reason C5): the trash sweep stages and
/// later purges the whole capture directory, so there is no separate lifetime to manage.
///
/// **Written and exported, never shown** (owner ruling, Q10). This file is diagnostics
/// and future export only — no view reads it, and none should be added casually.

/// Why an edit happened. `.unknown` is the decode fallback for a cause written by a
/// future build this one doesn't recognize — never a throw, per the same reasoning as
/// `RevisionSource.unknown(String)`, except a plain case suffices here: the raw spelling
/// isn't load-bearing for anything this file's (still nonexistent) reader does yet.
enum EntryLogCause: String, Codable, Sendable, Equatable {
    case userEdit
    case detection
    case carryOver
    case sweep
    case recovery
    case sync
    /// `EntryMetadata.setOriginalDate` refused a future date and the caller discarded the
    /// `false` (§7.1 nit) — logged anyway, since a refused attempt is itself informative.
    case rejected
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EntryLogCause(rawValue: raw) ?? .unknown
    }
}

/// One line of `entry-log.jsonl` (§7.1). No `seq` (design rev 2, B2/F9 — this log never
/// resumes numbering, so there is nothing to collide) and no `deviceID` (F19 — the log is
/// local-only, so it never needs to say which device wrote it).
///
/// `from`/`to` are always the field's **on-disk encoding as a string** — one typing rule
/// for every field: `"1998-03"` for a `PartialDate`, ISO8601 for `trashedAt`, a ULID for
/// `journalID`, `"true"`/`"false"` for the two `Bool` fields.
struct EntryLogRecord: Codable, Sendable, Equatable {
    var at: Date
    /// `"journalID" | "originalDate" | "trashedAt" | "detectedDate" | "detectionRan"
    /// | "multiVoice"` — `EntryMetadata`'s six fields (`EntryMetadata.swift:47/57/61/76/
    /// 87/97`). Not an enum: keeping this a bare string means a field renamed on the
    /// `EntryMetadata` side doesn't need a parallel rename here to keep compiling, and an
    /// export consumer gets exactly what shipped rather than a case this build didn't know
    /// about.
    var field: String
    var from: String?
    var to: String?
    var cause: EntryLogCause
    /// `BackdateOrigin`'s raw value when `field == "originalDate"` — forward-declared,
    /// like `EntryMetadata.trashedAt` once was for trash (M3 plan): the type this refers
    /// to does not exist yet anywhere in the codebase, so nothing writes this key today.
    /// Landing the field now means the shape doesn't churn once it does.
    var origin: String?
}

extension EntryLogRecord {
    /// Field-by-field diff between two `EntryMetadata` values (§7.2 rule 1), one record
    /// per changed field, in `EntryMetadata`'s declaration order. Each `from`/`to` is the
    /// field's on-disk string encoding — §7.1's one typing rule for every field.
    ///
    /// `EntryMetadata` has **six** fields (`journalID`, `originalDate`, `trashedAt`,
    /// `detectedDate`, `detectionRan`, `multiVoice` — `EntryMetadata.swift:47/57/61/76/
    /// 87/97`). If this ever silently stops covering all of them, nothing here notices —
    /// this function has no way to see a field it wasn't written to check. The guard
    /// against that drift is `testEntryMetadataFieldCountIsPinnedSoNewFieldsGetLogged`
    /// (`EntryLogTests.swift`), a `Mirror`-based count pinned at 6: if it fires, add the
    /// new field's case below before bumping the count.
    static func diff(from before: EntryMetadata, to after: EntryMetadata,
                      at: Date, cause: EntryLogCause) -> [EntryLogRecord] {
        var records: [EntryLogRecord] = []
        func add(_ field: String, _ from: String?, _ to: String?) {
            records.append(EntryLogRecord(at: at, field: field, from: from, to: to,
                                          cause: cause, origin: nil))
        }
        if before.journalID != after.journalID {
            add("journalID", before.journalID, after.journalID)
        }
        if before.originalDate != after.originalDate {
            add("originalDate", before.originalDate?.isoString, after.originalDate?.isoString)
        }
        if before.trashedAt != after.trashedAt {
            add("trashedAt", before.trashedAt.map(encodeDate), after.trashedAt.map(encodeDate))
        }
        if before.detectedDate != after.detectedDate {
            add("detectedDate", before.detectedDate?.isoString, after.detectedDate?.isoString)
        }
        if before.detectionRan != after.detectionRan {
            add("detectionRan", String(before.detectionRan), String(after.detectionRan))
        }
        if before.multiVoice != after.multiVoice {
            add("multiVoice", String(before.multiVoice), String(after.multiVoice))
        }
        return records
    }

    private static func encodeDate(_ date: Date) -> String {
        CaptureCoding.iso8601Formatter().string(from: date)
    }
}

enum EntryLogError: Error, Equatable {
    case posix(operation: String, code: Int32)
    /// A record encoded to something containing a raw newline, which JSONL cannot
    /// represent. Unreachable through the public API (JSON escapes control characters);
    /// kept as the guard that would catch an accidental pretty-printing encoder.
    case multilineRecord
    /// The existing log could not be read, so whether its tail is torn is unknown.
    /// Refusing to append rather than guessing — see `EntryLogWriter.append`.
    case unreadableExistingLog(String)
}

/// Appends one record. Deliberately **not** a persistent-handle writer like
/// `MarkerLogWriter`/`LiveTranscriptWriter`: those exist because capture-time writes land
/// many times a second and a handle amortizes the open cost. Metadata edits are rare —
/// one call per owner action — so a bare open → write → close per append (§7.2) is
/// simpler and costs nothing this log will ever notice.
enum EntryLogWriter {
    /// Torn-tail fuse per §7.2, required explicitly rather than by analogy to
    /// `LiveTranscriptWriter`/`MarkerLogWriter`: this writer has no in-memory `tornTail`
    /// flag to carry across calls (it never stays open), so the check happens fresh on
    /// every append by reading the existing file's last byte.
    static func append(_ record: EntryLogRecord, captureDirectory: URL) throws {
        let url = SegmentLayout.entryLogURL(captureDirectory: captureDirectory)

        // Deliberately no `createDirectory` here (unlike `LiveTranscriptWriter.open`,
        // which owns `transcript/`'s creation): `append` only ever runs after
        // `EntryMetadataStore.write`'s `AtomicFile.replace` has already succeeded into
        // this same capture directory (§7.2 rule 2), so the directory necessarily
        // exists by the time this runs. Creating it here would be a write-path
        // `createDirectory` reaching into a directory that might have just been staged
        // away for trash — exactly the shape Gate A finding C2 caught (append
        // resurrecting a staged-away capture). If the directory is genuinely gone, this
        // throws (rule 4: the caller swallows it silently).
        let needsFuse: Bool
        switch EntryLogReader.loadBytes(at: url) {
        case .absent:
            needsFuse = false
        case .unreadable(let reason):
            throw EntryLogError.unreadableExistingLog(reason)
        case .present(let data):
            // Torn-tail fuse (§7.2 rule 3), read fresh on every append since this
            // writer never stays open across calls: the previous run's last byte tells
            // us whether it finished its last line cleanly.
            needsFuse = data.last != nil && data.last != UInt8(ascii: "\n")
        }

        var data = try CaptureCoding.lineEncoder().encode(record)
        guard !data.contains(UInt8(ascii: "\n")) else { throw EntryLogError.multilineRecord }
        data.append(UInt8(ascii: "\n"))

        let descriptor = Foundation.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { throw EntryLogError.posix(operation: "open", code: errno) }
        defer { close(descriptor) }

        if needsFuse {
            try Self.writeAll(fd: descriptor, data: Data([UInt8(ascii: "\n")]))
        }
        try Self.writeAll(fd: descriptor, data: data)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 { throw EntryLogError.posix(operation: "write", code: errno) }
                offset += n
            }
        }
    }
}

/// Whether the log is missing, unreadable, or readable — three answers, deliberately
/// (issue #11's rule, restated for this log though no reader consumes it yet).
enum EntryLogSource: Equatable {
    case absent
    case unreadable(String)
    case present(Data)
}

/// Reads `entry-log.jsonl`. No `seq`, so unlike `MarkerLogReader`/`LiveTranscriptReader`
/// there is nothing to renumber past and no completeness API — tail loss here is
/// undetectable and accepted (§7.1), same as the design states outright.
enum EntryLogReader {
    struct LoadResult: Equatable {
        var source: EntryLogSource = .absent
        var records: [EntryLogRecord] = []
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
        load(url: SegmentLayout.entryLogURL(captureDirectory: captureDirectory))
    }

    static func loadBytes(at url: URL) -> EntryLogSource {
        do {
            return .present(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    struct ParseResult: Equatable {
        var records: [EntryLogRecord] = []
        var completeLines: Int = 0
    }

    /// A trailing line with no terminating newline is incomplete and dropped — the
    /// expected shape after a force-kill, not an error. An interior line that fails to
    /// decode is skipped rather than truncating the read.
    static func parse(_ data: Data) -> ParseResult {
        guard !data.isEmpty else { return ParseResult() }

        let newline = UInt8(ascii: "\n")
        let complete: Data
        if data.last == newline {
            complete = data
        } else if let lastNewline = data.lastIndex(of: newline) {
            complete = data[..<data.index(after: lastNewline)]
        } else {
            return ParseResult()
        }

        let decoder = CaptureCoding.decoder()
        let lines = complete.split(separator: newline, omittingEmptySubsequences: true)
        return ParseResult(
            records: lines.compactMap { try? decoder.decode(EntryLogRecord.self, from: Data($0)) },
            completeLines: lines.count)
    }
}
