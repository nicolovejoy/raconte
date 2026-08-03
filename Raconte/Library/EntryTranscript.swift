import Foundation

/// What one capture's live transcript log says, in the form every screen reads it.
///
/// One implementation for both consumers. The library row and the detail screen each
/// used to load, switch on the source, and consolidate for themselves, and they had
/// already drifted: only the scanner computed truncation, so an entry whose tail was
/// lost to a kill said so in the list and said nothing on the screen showing the text.
struct EntryTranscript: Sendable, Equatable {
    var state: EntryTranscriptState
    /// The full committed text, consolidated. `nil` unless `state == .present`; empty
    /// when the log is readable and holds no committed text — a real, distinct answer.
    var text: String?
    var degradations: EntryDegradation

    /// The library row's one-line preview. `nil` when there is nothing to preview.
    var snippet: String? {
        guard let text else { return nil }
        return EntrySnippet.make(from: text)
    }

    /// Fewer lines on disk than the manifest's `TranscriptRef.committedRecords` — the
    /// tail was lost to a kill. Both screens surface this; the row as a marker, the
    /// detail screen as a note under the prose.
    var isTruncated: Bool { degradations.contains(.transcriptTruncated) }
}

enum EntryTranscriptLoader {
    /// Read `transcript/live.jsonl` and fold it through `TranscriptConsolidator`.
    ///
    /// Reading raw does **not** reproduce the live view (issue #10): the log cannot
    /// express a later result revising an earlier one or an empty result revoking a
    /// span, so a revised phrase appears twice and a retracted one appears at all.
    /// `LiveTranscriptReader.consolidate` is the single implementation of those rules.
    ///
    /// `expectedRecords` is `TranscriptRef.committedRecords`, written only on a clean
    /// close — its absence is what makes tail loss expected rather than a defect.
    ///
    /// Synchronous and nonisolated: it touches disk, so callers on the main actor must
    /// reach it through an `async` hop (`LibraryScreenModel.transcript(for:)`).
    static func load(captureDirectory: URL, expectedRecords: Int?) -> EntryTranscript {
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        switch loaded.source {
        case .absent:
            return EntryTranscript(state: .absent, text: nil, degradations: [])
        case .unreadable:
            // Not "no transcript". The log is there and we failed at it.
            return EntryTranscript(state: .unreadable, text: nil,
                                   degradations: [.transcriptUnreadable])
        case .present:
            var degradations: EntryDegradation = []
            if case .truncated = LiveTranscriptReader.completeness(lines: loaded.completeLines,
                                                                   expected: expectedRecords) {
                degradations.insert(.transcriptTruncated)
            }
            return EntryTranscript(
                state: .present,
                text: LiveTranscriptReader.consolidate(loaded.records).committedText,
                degradations: degradations)
        }
    }
}
