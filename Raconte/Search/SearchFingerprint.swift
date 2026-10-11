import Foundation

/// Cheap change detection per entry for the search index. `live.jsonl` is never read, only
/// stat'ed. No transcript body is decoded when `head.json` is trusted; otherwise
/// `validatedHead` rebuilds the head in memory, which costs what the library scan already
/// pays. Read-only.
enum SearchFingerprint {
    /// Take the fingerprint BEFORE reading the body it describes (see `SearchIndexer.reconcile`).
    /// `nil` when the directory has neither a canonical head nor a live log.
    static func compute(directory: URL) -> String? {
        // Same precedence as `EntryTranscriptLoader`: a canonical current wins.
        if let head = TranscriptRevisionStore.validatedHead(captureDirectory: directory),
           let current = head.current {
            return "rev:\(current.id):\(current.characterCount)"
        }
        let live = SegmentLayout.liveTranscriptURL(captureDirectory: directory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: live.path),
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return "live:\(size.int64Value):\(Int64(modified.timeIntervalSince1970 * 1000))"
    }
}
