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

extension EntryTranscript {
    /// Marking mode's one read primitive (T7 Task 3, #56): what a "mark voices" screen
    /// needs to render and let the owner tap voice/paragraph structure onto an entry.
    /// Composes the same internals the reading path (`EntryTranscriptLoader.load`)
    /// uses — `TranscriptRevisionStore.loadChain` for the current revision's spans,
    /// `LiveTranscriptReader` for the marker-snap intervals, `EntryTranscriptLoader
    /// .snappedMarkers` for the fold + snap-vs-exact split, and
    /// `TranscriptAttribution.attribute(spans:snapped:)` for the actual grouping —
    /// never duplicating any of those rules.
    ///
    /// The one deliberate departure from the reading path (brief's "key difference"):
    /// an ABSENT or EMPTY marker log is `.ready`, not "nothing to show" — marking
    /// exists precisely for entries that have no markers yet, so a single nil-voice
    /// paragraph spanning every span is the correct starting point to mark ONTO, not a
    /// dead end.
    enum VoiceMarkingLayout: Equatable {
        /// No readable canonical revision to mark onto — the entry was never
        /// promoted, or every canonical file is unreadable / the chain listing itself
        /// failed (`TranscriptRevisionStore.loadChain` returning `nil`, or a non-nil
        /// chain with no attached current revision). Marking needs a revision's
        /// SPANS, not the raw machine transcript, so — unlike the reading path —
        /// there is no live.jsonl fallback here.
        case unavailable
        /// `markers.jsonl` exists but couldn't be read. A silent "no markers yet"
        /// answer here would risk marking directly on top of taps that are still
        /// really there on disk — refuse instead, distinctly from `.unavailable`.
        case markersUnreadable(String)
        case ready(spans: [TranscriptSpan],
                   paragraphs: [TranscriptAttribution.Paragraph],
                   hasAnyVoiceMarker: Bool)
    }

    static func voiceMarkingLayout(captureDirectory: URL, sampleRate: Double) -> VoiceMarkingLayout {
        guard let chainLoad = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory),
              let current = TranscriptChain.current(TranscriptChain.ordered(chainLoad.revisions))
        else {
            return .unavailable
        }

        // Same `live.jsonl` read `EntryTranscriptLoader.load`'s `.compute` branch uses —
        // `snappedMarkers` still needs `committed` to derive the real audio gaps a raw
        // tap snaps against, unaffected by any later edit to `current`.
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        var committed: [TranscriptResult] = []
        if case .present = loaded.source {
            committed = LiveTranscriptReader.consolidate(loaded.records).committed
        }

        switch EntryTranscriptLoader.snappedMarkers(captureDirectory: captureDirectory,
                                                     committed: committed, sampleRate: sampleRate) {
        case .unreadable(let reason):
            return .markersUnreadable(reason)
        case .absent:
            // The departure from the reading path: absent is READY, not nil — one
            // nil-voice paragraph spanning every span, the correct starting point to
            // mark onto.
            let paragraphs = TranscriptAttribution.attribute(spans: current.spans, snapped: [])
            return .ready(spans: current.spans, paragraphs: paragraphs, hasAnyVoiceMarker: false)
        case .present(let snapped, let hasAnyVoiceMarker):
            // Covers both "markers exist but folded to nothing usable" (snapped == [])
            // and the ordinary populated case — both are `.ready`, matching the same
            // departure as the `.absent` case above.
            let paragraphs = TranscriptAttribution.attribute(spans: current.spans, snapped: snapped)
            return .ready(spans: current.spans, paragraphs: paragraphs, hasAnyVoiceMarker: hasAnyVoiceMarker)
        }
    }
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
    /// **Attribution (`.compute` mode) as of T7 Task 5:** paragraphs are attributed over
    /// `current`'s own spans (`TranscriptAttribution.attribute(spans:snapped:)`), not
    /// `live.jsonl`'s committed records — so voice attribution survives an edit instead
    /// of switching off the moment `current` stops being the untouched machine
    /// transcript. `live.jsonl` is still read to snap marker frames against the real
    /// audio gaps (unaffected by later edits); only the paragraph GROUPING step reads
    /// `spans`. Three answers all the way down: no attached canonical revision (absent
    /// `transcript/`, or every file in it unreadable) falls through to today's
    /// `live.jsonl`-only path unchanged (committed-based attribution, as before T7).
    ///
    /// **#40.1 (T7 Task 3):** the two `attribution` modes take genuinely different
    /// canonical-chain paths, not just a different tail. `.compute` (the detail screen,
    /// a user-action-triggered read) still goes through `loadChain`, decoding every
    /// revision body — it needs the full text and (since Task 5) `current`'s own spans
    /// for attribution. `.skip` (the scanner's row, run on every
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

        // T7 Task 5: attribution over `current`'s OWN spans, not `committed`'s — a
        // revision's spans carry frames too (with an honesty grade), so voice
        // attribution survives an edit instead of switching off the moment `current`
        // stops being the live machine transcript. See
        // `TranscriptAttribution.attribute(spans:snapped:)`'s doc comment for the
        // placement rule over spans with no usable (or zero-length) bounds. `committed`
        // is still read/consolidated by the `.compute` branch below: `snappedMarkers`
        // still snaps raw marker frames against the real audio gaps it derives from
        // `committed` — those never change regardless of a later edit — only the
        // paragraph GROUPING step switches from `committed` to `spans`.
        func spanParagraphs(_ spans: [TranscriptSpan],
                            committed: [TranscriptResult]) -> [TranscriptAttribution.Paragraph]? {
            guard case .compute(let sampleRate) = attribution else { return nil }
            return attributedParagraphs(captureDirectory: captureDirectory,
                                        spans: spans, committed: committed, sampleRate: sampleRate)
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
            // T7 Task 5: attribution now runs over `current.spans` via
            // `spanParagraphs`, whatever `current.source` is — the gate that used to
            // force `nil` for anything but `.machineLive` (and silently drop the
            // owner's two-voice structure on his very first edit) is gone. See
            // `spanParagraphs`'s doc comment above for why `committed` is still read.
            let attributed = spanParagraphs(current.spans, committed: committed)
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

    /// `markers.jsonl` → fold corrections → snap, applying the marker-source rules
    /// (design §7): an absent or unreadable log, or one with nothing usable in it, is
    /// `nil` — never "single voice, nothing to see" (the journals.json lesson repeated
    /// for markers). Shared by both `attributedParagraphs` overloads below so the two
    /// attribution paths (`committed`-based and, since T7 Task 5, `spans`-based) can
    /// never silently disagree on when a marker log counts as usable.
    ///
    /// **T7 Task 6:** `MarkerCorrections.effectiveMarkers` runs BEFORE snapping — raw
    /// taps on disk are never touched (locked decision 5), but every reader of the log
    /// must see the corrected picture, so the fold happens once, here, rather than in
    /// each attribution call site. "Nothing usable" now also covers a raw list that
    /// resolves to empty AFTER corrections (e.g. retracting the only marker) — the same
    /// rule an empty raw list already got, extended to the effective one.
    ///
    /// **Review Critical 1:** a boundary-add's synthesized marker (`isExact == true`)
    /// must NEVER go through `MarkerSnapping.snap` — that function exists to correct
    /// RAW TAP latency (design §6), and a word-anchored frame was never a tap at all;
    /// it is a span's own bound, exact by construction. On real device data (abutting
    /// in-record word intervals, the owner's own marker-session norm), snapping an
    /// exact frame can silently move it to a DIFFERENT word or erase the split
    /// entirely — reproduced and pinned in
    /// `TranscriptAttributionLoadTests.testAddBoundaryOnAbuttingWordsIsNotSnapped`.
    /// So the effective list is split: only the non-exact half (raw taps, including a
    /// voice-corrected one — its FRAME is still the original raw tap's) goes through
    /// `MarkerSnapping.snap`; an exact marker is wrapped directly as its own
    /// `SnappedMarker` at its own frame, `approximate: false` — the honest answer,
    /// since nothing was approximated.
    ///
    /// Three-way answer (T7 Task 3, #56), not the collapsed nil/non-nil `attributedParagraphs`
    /// below actually needs: `EntryTranscript.voiceMarkingLayout` has to tell "no log at
    /// all" (`.absent`) apart from "log exists but is unreadable" (its own
    /// `.markersUnreadable` answer, refuse-to-mark) — a distinction `attributedParagraphs`
    /// has never needed, since both collapse to `nil` on the reading path. It also needs
    /// `hasAnyVoiceMarker` without re-deriving `MarkerCorrections.effectiveMarkers` itself
    /// — computed here, once, alongside the fold that already produces it.
    ///
    /// Not `private` (T7 Task 3): `EntryTranscript.voiceMarkingLayout` is a DIFFERENT type
    /// declared later in this same file and must call this directly rather than
    /// reimplement the fold + snap-vs-exact split — copying it would be a second
    /// implementation of the same rule, free to silently disagree with this one.
    enum MarkerAttributionInputs {
        case absent
        case unreadable(String)
        case present(snapped: [MarkerSnapping.SnappedMarker], hasAnyVoiceMarker: Bool)
    }

    /// M4 T10: this device's own stream (readability three-answer, unchanged) plus every
    /// foreign stream ingest has materialized beside it, folded through
    /// `MarkerStreamMerge.merge` before `MarkerCorrections`/`MarkerSnapping` ever see a
    /// marker — so a field-add or a correction that landed on a PEER device is not
    /// silently invisible here (the exact hazard design §7.4 exists to close). Own-stream
    /// readability still governs `.absent`/`.unreadable`: this device's marking UI writes
    /// only to its own `markers.jsonl`, so a torn/unreadable own log must still refuse
    /// exactly as before M4 — a readable foreign stream cannot paper over that.
    ///
    /// `.absent` own stream with at least one readable foreign stream is `.present` (a
    /// peer marked voices, this device never has) — the corpus-wide "unreadable ≠ absent
    /// ≠ nothing to see" rule (#11) applies per stream, not only to the local one.
    static func snappedMarkers(captureDirectory: URL, committed: [TranscriptResult],
                               sampleRate: Double) -> MarkerAttributionInputs {
        let markerLoad = MarkerLogReader.load(captureDirectory: captureDirectory)
        switch markerLoad.source {
        case .absent:
            let foreign = foreignMarkerStreams(captureDirectory: captureDirectory)
            guard !foreign.isEmpty else { return .absent }
            return presentAttributionInputs(merged: MarkerStreamMerge.merge(foreign),
                                            committed: committed, sampleRate: sampleRate)
        case .unreadable(let reason):
            return .unreadable(reason)
        case .present:
            let ownStream = MarkerStreamMerge.Stream(deviceID: DeviceIdentity.stable(), markers: markerLoad.markers)
            let merged = MarkerStreamMerge.merge([ownStream] + foreignMarkerStreams(captureDirectory: captureDirectory))
            return presentAttributionInputs(merged: merged, committed: committed, sampleRate: sampleRate)
        }
    }

    /// Every readable `transcript/markers-<deviceID>.jsonl` sibling of this device's own
    /// `markers.jsonl` (M4 T10). An UNREADABLE foreign stream is dropped, not surfaced —
    /// unlike the own-stream case, a corrupt peer's bytes cannot demote the whole read to
    /// `.unreadable` (this device's own attribution must still work), so the honest
    /// three-answer treatment happens per file and only the readable ones are folded in.
    private static func foreignMarkerStreams(captureDirectory: URL) -> [MarkerStreamMerge.Stream] {
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: transcriptDir.path) else {
            return []
        }
        var streams: [MarkerStreamMerge.Stream] = []
        for name in names.sorted() {
            guard let deviceID = SegmentLayout.foreignStreamDeviceID(fromFileName: name) else { continue }
            let url = transcriptDir.appendingPathComponent(name)
            let result = MarkerLogReader.load(url: url)
            guard case .present = result.source else { continue }
            streams.append(MarkerStreamMerge.Stream(deviceID: deviceID, markers: result.markers))
        }
        return streams
    }

    /// Shared tail of `snappedMarkers`' two non-absent branches: fold corrections, split
    /// exact (boundary-add) markers from raw taps needing `MarkerSnapping`, exactly as
    /// before M4 — factored out so both the own-stream-present and own-absent-but-
    /// foreign-present paths compute this identically rather than two copies free to
    /// diverge.
    private static func presentAttributionInputs(merged: [StructureMarker], committed: [TranscriptResult],
                                                  sampleRate: Double) -> MarkerAttributionInputs {
        let effective = MarkerCorrections.effectiveMarkers(merged)
        let hasAnyVoiceMarker = effective.contains { $0.marker.kind == .voice }
        guard !effective.isEmpty else {
            return .present(snapped: [], hasAnyVoiceMarker: hasAnyVoiceMarker)
        }
        let intervals = MarkerSnapping.intervals(fromCommitted: committed)
        let window = MarkerSnapping.windowFrames(sampleRate: sampleRate)

        let toSnap = effective.filter { !$0.isExact }.map(\.marker)
        let snapped = MarkerSnapping.snap(markers: toSnap, intervals: intervals, windowFrames: window)
        let exact = effective.filter(\.isExact).map { em in
            MarkerSnapping.SnappedMarker(marker: em.marker, snappedFrame: em.marker.frame, approximate: false)
        }
        return .present(snapped: snapped + exact, hasAnyVoiceMarker: hasAnyVoiceMarker)
    }

    /// The live-log fallback path's attribution (`fallbackToLiveLog`, above): no
    /// canonical revision exists to attribute over, so this reads straight off
    /// `committed`, unchanged since before T7 Task 5.
    private static func attributedParagraphs(captureDirectory: URL,
                                              committed: [TranscriptResult],
                                              sampleRate: Double) -> [TranscriptAttribution.Paragraph]? {
        guard case .present(let snapped, _) = snappedMarkers(captureDirectory: captureDirectory,
                                                              committed: committed, sampleRate: sampleRate),
              !snapped.isEmpty else { return nil }
        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: snapped)
        // Markers with no transcript (hazard 4): `attribute` returns `[]`, which must
        // render as "not transcribed", not as an empty paragraph list.
        return paragraphs.isEmpty ? nil : paragraphs
    }

    /// The canonical-chain path's attribution (T7 Task 5): attributes over a
    /// REVISION's spans instead of `committed`, the change that lets voice attribution
    /// survive an edit. `committed` is still required here — `snappedMarkers` still
    /// snaps raw marker frames against the real audio gaps it derives from `committed`,
    /// which never change regardless of a later edit; only the paragraph GROUPING step
    /// (`TranscriptAttribution.attribute(spans:snapped:)`) reads `spans` instead.
    private static func attributedParagraphs(captureDirectory: URL,
                                              spans: [TranscriptSpan],
                                              committed: [TranscriptResult],
                                              sampleRate: Double) -> [TranscriptAttribution.Paragraph]? {
        guard case .present(let snapped, _) = snappedMarkers(captureDirectory: captureDirectory,
                                                              committed: committed, sampleRate: sampleRate),
              !snapped.isEmpty else { return nil }
        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: snapped)
        return paragraphs.isEmpty ? nil : paragraphs
    }
}
