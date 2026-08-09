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
    /// Voice-attributed paragraphs (T7 plan step 2), for the detail screen only.
    /// `nil` means "render as today" — no attribution was asked for
    /// (`AttributionMode.skip`, the scanner's default), the marker log is absent or
    /// unreadable (design §7: an unreadable log assigns no voices, ever), or the
    /// attribution came back with nothing usable to show. Never conflate this with
    /// `text == nil`: a transcript can render fine with `paragraphs == nil`.
    var paragraphs: [TranscriptAttribution.Paragraph]? = nil

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

/// Whether `EntryTranscriptLoader.load` also computes voice attribution.
///
/// The scanner (`LibraryScanner.transcriptSummary`) must keep the `.skip` default —
/// it runs the loader once per row on every rescan, and a `markers.jsonl` read for
/// data the list never shows is a cost paid for nothing (hazard 1). Only the detail
/// screen, through `LibraryScreenModel.transcript(for:)`, asks for `.compute`.
enum AttributionMode: Sendable {
    case skip
    /// `sampleRate` scales `MarkerSnapping.windowFrames` — it comes from
    /// `Manifest.format.sampleRate`, not a constant, so a capture recorded at a
    /// non-48kHz rate still snaps against a window sized in real seconds.
    case compute(sampleRate: Double)
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
    /// `attribution` gates a second read (`markers.jsonl`) and the pure
    /// snap-then-attribute chain — see `AttributionMode`. Marker-source rules (design
    /// §7): an absent or unreadable marker log, or a log with nothing usable in it, or
    /// an attribution result with nothing in it, are all `paragraphs == nil` — never
    /// inferred as "single voice".
    ///
    /// Synchronous and nonisolated: it touches disk, so callers on the main actor must
    /// reach it through an `async` hop (`LibraryScreenModel.transcript(for:)`).
    static func load(captureDirectory: URL, expectedRecords: Int?,
                     attribution: AttributionMode = .skip) -> EntryTranscript {
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
            let consolidator = LiveTranscriptReader.consolidate(loaded.records)
            var paragraphs: [TranscriptAttribution.Paragraph]?
            if case .compute(let sampleRate) = attribution {
                paragraphs = attributedParagraphs(captureDirectory: captureDirectory,
                                                  committed: consolidator.committed,
                                                  sampleRate: sampleRate)
            }
            return EntryTranscript(
                state: .present,
                text: consolidator.committedText,
                degradations: degradations,
                paragraphs: paragraphs)
        }
    }

    /// `markers.jsonl` → snap → attribute, applying the marker-source rules (design
    /// §7). Split out so the `.present` branch above stays one read of each log.
    private static func attributedParagraphs(captureDirectory: URL,
                                              committed: [TranscriptResult],
                                              sampleRate: Double) -> [TranscriptAttribution.Paragraph]? {
        let markerLoad = MarkerLogReader.load(captureDirectory: captureDirectory)
        switch markerLoad.source {
        case .absent, .unreadable:
            // `.unreadable` is deliberately folded in with `.absent` here — never
            // rendered as "single voice, nothing to see" (design §7, the journals.json
            // lesson repeated for markers).
            return nil
        case .present:
            guard !markerLoad.markers.isEmpty else { return nil }
            let intervals = MarkerSnapping.intervals(fromCommitted: committed)
            let window = MarkerSnapping.windowFrames(sampleRate: sampleRate)
            let snapped = MarkerSnapping.snap(markers: markerLoad.markers,
                                              intervals: intervals, windowFrames: window)
            let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: snapped)
            // Markers with no transcript (hazard 4): `attribute` returns `[]`, which
            // must render as "not transcribed", not as an empty paragraph list.
            return paragraphs.isEmpty ? nil : paragraphs
        }
    }
}
