import Foundation

/// Pure on-disk layout logic (design §1/§6): path construction, segment naming
/// and index padding, `.part` truncation math, and cumulative frame-offset math.
/// No filesystem access — the FS actor (`SegmentStore`, T3) uses these.
enum SegmentLayout {
    static let manifestFileName = "manifest.json"
    static let entryMetadataFileName = "entry.json"
    static let segmentsDirName = "segments"
    static let finalDirName = "final"
    static let transcriptDirName = "transcript"
    static let liveTranscriptFileName = "live.jsonl"
    static let markerLogFileName = "markers.jsonl"
    static let canonicalTranscriptPrefix = "canonical-"
    static let transcriptHeadFileName = "head.json"
    static let transcriptDraftFileName = "draft.json"
    static let entryLogFileName = "entry-log.jsonl"
    static let finalRecordingName = "recording.m4a"
    static let partExtension = "part"
    static let pcmExtension = "pcm"
    static let sidecarExtension = "json"
    /// Zero-padded 6-digit decimal keeps `readdir` order == chronological order.
    static let segmentIndexWidth = 6

    // MARK: Naming

    /// e.g. index 42 -> "000042".
    static func segmentBaseName(index: Int) -> String {
        precondition(index >= 0, "segment index must be non-negative")
        return String(format: "%0\(segmentIndexWidth)d", index)
    }

    static func pcmFileName(index: Int) -> String {
        "\(segmentBaseName(index: index)).\(pcmExtension)"
    }

    static func pcmPartFileName(index: Int) -> String {
        "\(pcmFileName(index: index)).\(partExtension)"
    }

    static func sidecarFileName(index: Int) -> String {
        "\(segmentBaseName(index: index)).\(sidecarExtension)"
    }

    /// Parses the leading zero-padded index from any segment filename
    /// (`000042.pcm`, `000042.pcm.part`, `000042.json`). Returns nil if the
    /// leading component isn't a run of digits.
    static func segmentIndex(fromFileName fileName: String) -> Int? {
        let head = fileName.prefix { $0 != "." }
        guard !head.isEmpty, head.allSatisfy(\.isNumber) else { return nil }
        return Int(head)
    }

    // MARK: Ordering

    /// True iff the sorted indices are gap-free and start at 0 (0, 1, ..., n-1).
    static func indicesAreGapFree(_ indices: [Int]) -> Bool {
        let sorted = indices.sorted()
        for (expected, actual) in sorted.enumerated() where expected != actual {
            return false
        }
        return true
    }

    // MARK: URLs

    static func captureDirectory(capturesRoot: URL, captureID: String) -> URL {
        capturesRoot.appendingPathComponent(captureID, isDirectory: true)
    }

    static func manifestURL(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(manifestFileName)
    }

    static func manifestPartURL(captureDirectory: URL) -> URL {
        partURL(for: manifestURL(captureDirectory: captureDirectory))
    }

    /// User-owned metadata for the capture (M3 T1). A sibling of the manifest rather
    /// than part of it: the manifest belongs to the capture machine, this belongs to the
    /// user, and the two must be writable independently.
    static func entryMetadataURL(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(entryMetadataFileName)
    }

    static func segmentsDirectory(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(segmentsDirName, isDirectory: true)
    }

    static func finalDirectory(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(finalDirName, isDirectory: true)
    }

    static func finalRecordingURL(captureDirectory: URL) -> URL {
        finalDirectory(captureDirectory: captureDirectory).appendingPathComponent(finalRecordingName)
    }

    static func finalRecordingPartURL(captureDirectory: URL) -> URL {
        partURL(for: finalRecordingURL(captureDirectory: captureDirectory))
    }

    /// Where M2 T3 writes `live.jsonl` and the canonical transcript. Declared here
    /// ahead of T3 because issue #8's guard has to know the directory exists as a
    /// concept before anything writes into it — a delete rule added *after* the
    /// writer is a delete rule that shipped one release too late.
    static func transcriptDirectory(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(transcriptDirName, isDirectory: true)
    }

    /// The live pass's append-only log. One JSON object per line, committed results
    /// only. No `.part` sibling: there is no rewrite, so there is nothing to stage.
    static func liveTranscriptURL(captureDirectory: URL) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent(liveTranscriptFileName)
    }

    /// Capture-time structure markers (T6 §14): raw tap frames, append-only JSONL.
    /// Lives in `transcript/` so issue #8's guard already covers it with zero changes.
    static func markerLogURL(captureDirectory: URL) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent(markerLogFileName)
    }

    /// `canonical-<n>.json`. Revisions are addressable and never rewritten — a
    /// retranscription writes `n+1` rather than replacing `n`, so a user edit in an
    /// earlier revision is always still on disk.
    static func canonicalTranscriptURL(captureDirectory: URL, revision: Int) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent("\(canonicalTranscriptPrefix)\(revision).json")
    }

    /// T6 §4.1: the current revision-chain head pointer. Lives in `transcript/` so
    /// issue #8's guard already covers it with zero changes.
    static func transcriptHeadURL(captureDirectory: URL) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent(transcriptHeadFileName)
    }

    /// T6 §4.1: the in-progress edit draft, if any. Lives in `transcript/` alongside
    /// `head.json` and the `canonical-<n>.json` revisions.
    static func transcriptDraftURL(captureDirectory: URL) -> URL {
        transcriptDirectory(captureDirectory: captureDirectory)
            .appendingPathComponent(transcriptDraftFileName)
    }

    /// T7's audit log. A sibling of `entry.json`, NOT inside `transcript/` — the
    /// audit log records edits to user-owned metadata, not to the derived transcript,
    /// so it belongs beside the file it audits rather than beside the revisions.
    static func entryLogURL(captureDirectory: URL) -> URL {
        captureDirectory.appendingPathComponent(entryLogFileName)
    }

    /// Inverse of `canonicalTranscriptURL`'s file name, for the recovery scan.
    static func canonicalRevision(fromFileName fileName: String) -> Int? {
        guard fileName.hasPrefix(canonicalTranscriptPrefix), fileName.hasSuffix(".json") else {
            return nil
        }
        let digits = fileName.dropFirst(canonicalTranscriptPrefix.count).dropLast(5)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        // Reject leading zeros: `canonical-007.json` and `canonical-7.json` are
        // different files, and mapping both to revision 7 would alias two revisions
        // into one in a scheme whose whole point is that revisions are addressable.
        guard digits == "0" || !digits.hasPrefix("0") else { return nil }
        return Int(digits)
    }

    static func pcmURL(segmentsDirectory: URL, index: Int) -> URL {
        segmentsDirectory.appendingPathComponent(pcmFileName(index: index))
    }

    static func pcmPartURL(segmentsDirectory: URL, index: Int) -> URL {
        segmentsDirectory.appendingPathComponent(pcmPartFileName(index: index))
    }

    static func sidecarURL(segmentsDirectory: URL, index: Int) -> URL {
        segmentsDirectory.appendingPathComponent(sidecarFileName(index: index))
    }

    /// The transient `.part` sibling of any target URL (e.g. `manifest.json` ->
    /// `manifest.json.part`, `000042.pcm` -> `000042.pcm.part`).
    static func partURL(for url: URL) -> URL {
        url.appendingPathExtension(partExtension)
    }

    // MARK: Frame / byte math

    /// Whole frames a file holds: floor(fileSize / bytesPerFrame). A trailing
    /// partial frame (crash mid-write) is excluded.
    static func wholeFrameCount(fileSize: Int, bytesPerFrame: Int) -> Int {
        precondition(bytesPerFrame > 0, "bytesPerFrame must be positive")
        return fileSize / bytesPerFrame
    }

    /// Byte length after dropping any trailing partial frame — the target for
    /// `ftruncate` when normalizing a `.pcm.part` (design §3).
    static func truncatedByteCount(fileSize: Int, bytesPerFrame: Int) -> Int {
        wholeFrameCount(fileSize: fileSize, bytesPerFrame: bytesPerFrame) * bytesPerFrame
    }

    static func hasTrailingPartialFrame(fileSize: Int, bytesPerFrame: Int) -> Bool {
        precondition(bytesPerFrame > 0, "bytesPerFrame must be positive")
        return fileSize % bytesPerFrame != 0
    }

    /// Cumulative `startFrameOffset` for each segment given per-segment frame
    /// counts in index order: offset[i] == sum(frameCounts[0..<i]).
    static func startFrameOffsets(frameCounts: [Int]) -> [Int] {
        var running = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(frameCounts.count)
        for count in frameCounts {
            offsets.append(running)
            running += count
        }
        return offsets
    }
}

/// JSON (de)serialization for manifest/sidecar with ISO8601 fractional-second
/// dates (design §1 timestamps carry milliseconds). Factory functions rather
/// than shared `static let`s: `JSONEncoder`/`Decoder` are non-Sendable, so
/// sharing them is rejected under complete strict concurrency.
enum CaptureCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(iso8601Formatter().string(from: date))
        }
        return encoder
    }

    /// Same dates and key ordering as `encoder()`, minus `.prettyPrinted`. JSONL
    /// requires one record per line, and the manifest/sidecar encoder emits multi-line
    /// JSON — a pretty-printed record would make the reader's line split tear every
    /// record in half. `LiveTranscriptWriter` asserts single-line output, which is how
    /// this was caught rather than shipped.
    static func lineEncoder() -> JSONEncoder {
        let encoder = encoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let string = try dec.singleValueContainer().decode(String.self)
            guard let date = iso8601Formatter().date(from: string) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath,
                    debugDescription: "Invalid ISO8601 date: \(string)"))
            }
            return date
        }
        return decoder
    }

    // Fresh formatter per call — avoids shared non-Sendable global state. `internal`
    // rather than `private`: `EntryMetadata`'s decoder needs the exact same formatter to
    // recognize a pre-#14 `originalDate` string during the string→string format switch.
    static func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
