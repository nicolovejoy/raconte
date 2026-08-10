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
    ///
    /// **Exception (T7 Task 3, #40.1):** when `AttributionMode.skip` supplied this from
    /// a promoted canonical chain (the scanner's row path — see `EntryTranscriptLoader
    /// .load`), this is `TranscriptHeadSummary.snippet` — an ALREADY whitespace-
    /// collapsed-across-every-line, truncated-with-ellipsis preview (built once at
    /// cache-write time via the SAME `EntrySnippet.make` the live.jsonl-fallback path
    /// below calls) — NOT the full text, because getting the full text would require
    /// decoding the revision body the head cache exists to avoid opening. (Fix round 1,
    /// Important 3: an earlier version of this cached `firstLine` — first line only,
    /// no truncation signal — which silently collapsed every multi-line edited entry's
    /// row preview to its opening line; `snippet` is the dedicated fix.) Only ever a
    /// row's own concern: `.snippet` below re-applies `EntrySnippet.make` to it, which
    /// is provably idempotent on an already-snippeted string (re-collapsing a
    /// single-spaced string is a no-op, and re-truncating an already-≤160-char string
    /// never re-enters the truncation branch), so nothing double-processes it. Every
    /// other caller (`AttributionMode.compute`, the detail screen) still gets the
    /// genuine full text.
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
    ///
    /// T6c preference: a promoted revision chain, when it has a readable current
    /// revision, supplies the display text — read-path-never-writes (design §4.8), so
    /// this never mutates `transcript/`, it only changes which text comes back.
    /// Attribution (`.compute` mode) is UNCHANGED for v1: it still renders from
    /// `live.jsonl`'s committed records + `markers.jsonl`, exactly as before promotion
    /// existed. Canonical text and `live.jsonl`'s committed text are display-identical
    /// by construction at promotion time (same `TranscriptText.join`), so the
    /// paragraphs stay consistent with whichever text is shown. Three answers all the
    /// way down: no attached canonical revision (absent `transcript/`, or every file in
    /// it unreadable) falls through to today's `live.jsonl` path unchanged.
    ///
    /// **#40.1 (T7 Task 3):** the two `attribution` modes now take genuinely different
    /// canonical-chain paths, not just a different tail. `.compute` (the detail screen,
    /// a user-action-triggered read) still goes through `loadChain`, decoding every
    /// revision body — it needs the full text and `current`'s real `RevisionSource` for
    /// the paragraph-attribution guard below. `.skip` (the scanner's row, run on every
    /// entry on every scan) goes through `TranscriptRevisionStore.validatedHead`
    /// instead — the O(1)-when-trusted head-cache path (design §4.3, hardened against
    /// silent staleness by fix round 1's size-integrity check) that exists precisely
    /// so a row never opens a `canonical-<n>.json` body just to show a preview. Its
    /// `current` is therefore a `TranscriptHeadSummary`, not a `TranscriptRevision`:
    /// `text` becomes `snippet` (the cached, already-truncated-with-ellipsis preview)
    /// rather than the full flattened text. Both branches still carry the SAME
    /// `live.jsonl`-degradation rules
    /// (truncation/unreadability of the source log survives even when canonical text
    /// wins, review finding 1) via `liveLogDegradation` below, and both fall through to
    /// the identical `live.jsonl`-only path when there is no attached canonical current.
    static func load(captureDirectory: URL, expectedRecords: Int?,
                     attribution: AttributionMode = .skip) -> EntryTranscript {
        // DEFERRED MINOR (T7 Task 3 fix round 1, reviewer note; #50's neighbourhood,
        // not fixed here): this JSON-parses every `live.jsonl` RECORD unconditionally,
        // even on the `.skip` branch, which only ever needs the truncation/
        // unreadability SIGNAL (`loaded.source`/`loaded.completeLines`) and never the
        // decoded `records` themselves once a canonical current exists. A cheaper
        // line-count-only read for `.skip` is possible but out of scope for this round.
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)

        func paragraphs(for committed: [TranscriptResult]) -> [TranscriptAttribution.Paragraph]? {
            guard case .compute(let sampleRate) = attribution else { return nil }
            return attributedParagraphs(captureDirectory: captureDirectory,
                                        committed: committed, sampleRate: sampleRate)
        }

        // The `live.jsonl`-side degradation rules, shared verbatim by every canonical-
        // present branch below (review finding 1): the source log being truncated or
        // unreadable must survive regardless of which canonical path supplied `text`.
        func liveLogDegradation(_ base: EntryDegradation) -> EntryDegradation {
            var degradations = base
            switch loaded.source {
            case .absent:
                break
            case .unreadable:
                // The promoted text is only as good as the log it came from — an
                // unreadable `live.jsonl` must still be surfaced even though `current`
                // itself decoded fine.
                degradations.insert(.transcriptUnreadable)
            case .present:
                if case .truncated = LiveTranscriptReader.completeness(lines: loaded.completeLines,
                                                                       expected: expectedRecords) {
                    degradations.insert(.transcriptTruncated)
                }
            }
            return degradations
        }

        // No attached canonical revision to show (absent transcript/, or every file in
        // it unreadable/empty) — the live.jsonl-only path, carrying any canonical-side
        // degradation forward so an owner still learns "revision unreadable" over the
        // fallback text. Identical for both attribution modes: `paragraphs(for:)`
        // self-selects `nil` under `.skip`, and this consolidation cost is pre-existing
        // and out of #40's scope (see this type's own "Known cost" doc on the scanner).
        func fallbackToLiveLog(canonicalDegradation: EntryDegradation) -> EntryTranscript {
            switch loaded.source {
            case .absent:
                return EntryTranscript(state: .absent, text: nil, degradations: canonicalDegradation)
            case .unreadable:
                // Not "no transcript". The log is there and we failed at it.
                var degradations = canonicalDegradation
                degradations.insert(.transcriptUnreadable)
                return EntryTranscript(state: .unreadable, text: nil, degradations: degradations)
            case .present:
                var degradations = canonicalDegradation
                if case .truncated = LiveTranscriptReader.completeness(lines: loaded.completeLines,
                                                                       expected: expectedRecords) {
                    degradations.insert(.transcriptTruncated)
                }
                let consolidator = LiveTranscriptReader.consolidate(loaded.records)
                return EntryTranscript(
                    state: .present,
                    text: consolidator.committedText,
                    degradations: degradations,
                    paragraphs: paragraphs(for: consolidator.committed))
            }
        }

        switch attribution {
        case .compute:
            let canonicalLoad = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
            var canonicalDegradation: EntryDegradation = []
            if let canonicalLoad, !canonicalLoad.unreadableFiles.isEmpty {
                canonicalDegradation.insert(.revisionUnreadable)
            }
            guard let canonicalLoad,
                  let current = TranscriptChain.current(TranscriptChain.ordered(canonicalLoad.revisions))
            else {
                return fallbackToLiveLog(canonicalDegradation: canonicalDegradation)
            }
            var committed: [TranscriptResult] = []
            if case .present = loaded.source {
                committed = LiveTranscriptReader.consolidate(loaded.records).committed
            }
            // Paragraphs are attributed off `live.jsonl`'s committed records (T7 plan
            // step 2, unchanged for v1) — trustworthy only when `current` IS that
            // machine-live text. A human revision (T6d/T6e onward) has diverged from
            // the log by definition; attributing markers.jsonl over post-edit text
            // would silently render stale pre-edit words under a voice label (review
            // finding 2). Re-attributing edited text is T7's job, not this loader's.
            let attributed = current.source == .machineLive ? paragraphs(for: committed) : nil
            return EntryTranscript(state: .present,
                                   text: TranscriptChain.plainText(current),
                                   degradations: liveLogDegradation(canonicalDegradation),
                                   paragraphs: attributed)

        case .skip:
            // #40.1: the scanner's row path must never decode a revision body.
            // `validatedHead` is trusted as-is (no file opened, no JSON decoded)
            // unless the directory listing OR any tracked file's size has moved since
            // the cache was last written (fix round 1, Important 1), in which case it
            // falls back to a full rebuild — a cost paid only on the scan right after
            // a chain-changing write or a damaged file, not on every subsequent one.
            let head = TranscriptRevisionStore.validatedHead(captureDirectory: captureDirectory)
            var canonicalDegradation: EntryDegradation = []
            if let head, !head.unreadableFiles.isEmpty {
                canonicalDegradation.insert(.revisionUnreadable)
            }
            guard let head, let current = head.current else {
                return fallbackToLiveLog(canonicalDegradation: canonicalDegradation)
            }
            return EntryTranscript(state: .present,
                                   text: current.snippet,
                                   degradations: liveLogDegradation(canonicalDegradation),
                                   paragraphs: nil)
        }
    }

    /// The MACHINE transcript alone: `live.jsonl`, consolidated, with the canonical chain
    /// deliberately not consulted at all (T7 Task 4, ruling Q5 — Gate A finding I3).
    ///
    /// `load(captureDirectory:expectedRecords:attribution:)` above cannot serve this, and
    /// riding it was a real defect: its canonical branch PREFERS `current`'s text and reaches
    /// the live-log fallback only when no readable revision exists at all. So a chain with one
    /// damaged file and one readable `.userEdit` handed back the OWNER'S OWN EDIT — to an
    /// editor screen whose heading calls it the un-edited machine transcript. Q5's offer is
    /// the loader's FALLBACK text specifically, and never labelling a state with something
    /// untrue is a principle the owner has now ruled on three times.
    ///
    /// `nil` for an absent or unreadable log, and for a readable log with nothing committed in
    /// it. Built on the same `LiveTranscriptReader.load` + `.consolidate` primitives
    /// `fallbackToLiveLog` uses, so issue #10's consolidation rules keep one implementation.
    static func machineLiveText(captureDirectory: URL) -> String? {
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        guard case .present = loaded.source else { return nil }
        let text = LiveTranscriptReader.consolidate(loaded.records).committedText
        return text.isEmpty ? nil : text
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
