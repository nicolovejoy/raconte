import Foundation

/// Turns committed transcript results + snapped structure markers into ordered,
/// voice-attributed paragraphs (T7 plan step 1). Pure: no I/O, no actor, no clock —
/// sibling in spirit to `MarkerSnapping`, which supplies the `snapped` input.
///
/// One voice per paragraph, deliberately: owner requirement 2 makes every voice switch
/// a paragraph break, so a `[Span]`-inside-`Paragraph` model would have exactly one
/// span in every case this can produce. Rejected here for that reason; T7 can widen it
/// if editing ever decouples the two.
enum TranscriptAttribution {
    struct Paragraph: Sendable, Equatable {
        /// `nil` — no voice marker is in force (no multi-voice toggle, or before the
        /// first `.voice` marker in a transcript with no frame-0 opener).
        var voice: String?
        var text: String
        /// Set when a marker that bounds this paragraph landed inside a piece rather
        /// than exactly on a piece boundary — either because the raw frame itself was
        /// unsnappable (`SnappedMarker.approximate`) or because the snapped frame still
        /// fell strictly inside one piece and had to be pushed to its nearer edge.
        /// Marked on both paragraphs adjacent to such a boundary: the imprecision is a
        /// property of the cut, not of a single side of it.
        var hasApproximateBoundary: Bool
        /// Indices into the `spans` array passed to `attribute(spans:snapped:)` that
        /// this paragraph was assembled from (T7 Task 3, #56) — lets a later marking UI
        /// map a rendered paragraph back to span indices. Only the span path populates
        /// this; the committed/pieces path (`attribute(committed:snapped:)`) has no span
        /// array to index into and always leaves it `nil`. Defaulted so every existing
        /// memberwise call site (fixtures, `paragraph(pieces:...)`) compiles unchanged.
        var spanRange: Range<Int>? = nil
    }

    /// One contiguous span of transcript text on the capture-frame axis, tagged with
    /// which committed record it came from (`recordIndex` — position in the sorted
    /// `committed` array, not an id). Whether a piece is one timed run out of several
    /// or a record's entire (untimed) text is not stored here — `paragraph(pieces:...)`
    /// re-derives it via `recordPieceCounts` when assembling text, which is the only
    /// place the distinction matters.
    ///
    /// Mirrors `MarkerSnapping.intervals(fromCommitted:)` exactly (same untimed-run
    /// fallback rule) so a marker never snaps to a boundary this piece stream doesn't
    /// also have.
    private struct Piece {
        var start: Int64
        var end: Int64
        var text: String
        var recordIndex: Int
    }

    static func attribute(committed: [TranscriptResult],
                          snapped: [MarkerSnapping.SnappedMarker]) -> [Paragraph] {
        let records = committed.sorted { $0.range.start < $1.range.start }
        let pieces = pieces(from: records)
        guard !pieces.isEmpty else { return [] }

        var recordPieceCounts: [Int: Int] = [:]
        for piece in pieces {
            recordPieceCounts[piece.recordIndex, default: 0] += 1
        }

        let relevantMarkers = snapped
            .filter { isRenderable($0.marker.kind) }
            .sorted { ($0.snappedFrame, $0.marker.seq) < ($1.snappedFrame, $1.marker.seq) }

        let breakpoints = breakpoints(for: relevantMarkers, pieces: pieces)

        var paragraphs: [Paragraph] = []
        var groupStart = 0
        var groupVoice: String?
        var pendingApprox = false

        for index in breakpoints.keys.sorted() {
            guard let breakpoint = breakpoints[index], breakpoint.isBreak else { continue }
            paragraphs.append(paragraph(pieces: pieces,
                                        range: groupStart..<index,
                                        records: records,
                                        recordPieceCounts: recordPieceCounts,
                                        voice: groupVoice,
                                        approximate: pendingApprox || breakpoint.approximate))
            groupStart = index
            groupVoice = breakpoint.voice
            pendingApprox = breakpoint.approximate
        }
        paragraphs.append(paragraph(pieces: pieces,
                                    range: groupStart..<pieces.count,
                                    records: records,
                                    recordPieceCounts: recordPieceCounts,
                                    voice: groupVoice,
                                    approximate: pendingApprox))

        return paragraphs.filter { !$0.text.isEmpty }
    }

    /// Attribute over a revision's SPANS instead of the machine's committed results (T7
    /// Task 5) — the entry point that lets voice attribution survive an edit, since a
    /// revision's spans carry frames too (with an honesty grade, `SpanAnchor`) rather
    /// than only ever being the untouched machine output `attribute(committed:snapped:)`
    /// above reads.
    ///
    /// A span can only be placed against a marker frame when its anchor claims usable
    /// bounds AND those bounds are non-zero-length — `.none`/`.unknown` never carry
    /// frames at all, and a zero-length `.inherited` span is one of the ways
    /// `TranscriptSplice` anchors ordinary newly-typed text: a POINT borrowed from the
    /// nearest preceding span, not a measured interval. That is no longer the WHOLE
    /// story since design §16.5 / Task 9b (2026-08-11): a wholesale, zero-character-
    /// overlap replacement of exactly one parent span (e.g. "Ellen" -> "LN") inherits
    /// the REPLACED span's own bounds instead — a real, non-zero-length interval, and
    /// placeable exactly when that replaced span itself was (if it wasn't, the
    /// replacement degrades to `.none`, the same rule as any other unanchored span, not
    /// to the zero-length-point fallback). So placeability is not a proxy for "was this
    /// text typed or measured" — it is exactly and only "does this span carry a real,
    /// non-degenerate interval," however that interval was produced.
    ///
    /// A span landing on the zero-length-point side inherits the voice of the nearest
    /// PRECEDING placeable span and can never itself start a paragraph: every cut this
    /// function computes lands immediately BEFORE the next placeable span
    /// (`fullSpanIndex(forPlaceablePosition:...)` below), which by construction sweeps
    /// every non-placeable span between it and the PREVIOUS placeable span into the
    /// group that just ended, never the one that's about to start. A run of
    /// non-placeable spans with nothing placeable before them at all (leading the
    /// array) has nowhere to inherit FROM either — the earliest possible cut is still
    /// no earlier than the first placeable span, so they land in the very first group
    /// by the same structural reason.
    ///
    /// Text assembly is `TranscriptText.join` per group — the SAME rule
    /// `TranscriptChain.plainText` uses over a revision's spans — so a no-marker call
    /// (one group covering every span) reproduces `plainText(revision)` byte-for-byte:
    /// the whole-record join rule (design §4.2 rule 8) generalises to a whole-span join
    /// rule without any special-casing needed here.
    static func attribute(spans: [TranscriptSpan],
                          snapped: [MarkerSnapping.SnappedMarker]) -> [Paragraph] {
        guard !spans.isEmpty else { return [] }

        let placeableIndices = spans.indices.filter { isPlaceableSpan(spans[$0]) }

        let relevantMarkers = snapped
            .filter { isRenderable($0.marker.kind) }
            .sorted { ($0.snappedFrame, $0.marker.seq) < ($1.snappedFrame, $1.marker.seq) }

        let breakpoints = spanBreakpoints(for: relevantMarkers, spans: spans, placeableIndices: placeableIndices)

        var paragraphs: [Paragraph] = []
        var groupStart = 0
        var groupVoice: String?
        var pendingApprox = false

        for index in breakpoints.keys.sorted() {
            guard let breakpoint = breakpoints[index], breakpoint.isBreak else { continue }
            paragraphs.append(spanParagraph(spans: spans, range: groupStart..<index,
                                            voice: groupVoice,
                                            approximate: pendingApprox || breakpoint.approximate))
            groupStart = index
            groupVoice = breakpoint.voice
            pendingApprox = breakpoint.approximate
        }
        paragraphs.append(spanParagraph(spans: spans, range: groupStart..<spans.count,
                                        voice: groupVoice, approximate: pendingApprox))

        return paragraphs.filter { !$0.text.isEmpty }
    }

    /// Whether a span's frame bounds are trustworthy enough to test a marker frame
    /// against: usable per `SpanAnchor.hasUsableBounds` AND non-zero-length. See the
    /// design note on `attribute(spans:snapped:)` above for why zero-length is excluded
    /// even though `.inherited` alone would say "usable".
    ///
    /// Not `private` (T7 Task 6): `MarkerCorrectionWriter`'s boundary-add needs the
    /// IDENTICAL "is this word offerable" rule — brief case 3 says a word whose span
    /// has no usable bounds is not offerable, and that is exactly this predicate. Two
    /// implementations of "placeable" would be free to silently disagree.
    static func isPlaceableSpan(_ span: TranscriptSpan) -> Bool {
        guard span.anchor.hasUsableBounds,
              let start = span.frameStart, let end = span.frameEnd else { return false }
        return end > start
    }

    /// Cut-position search restricted to the placeable spans, over the COMPACTED
    /// placeable-only index space (`0...placeableIndices.count`): a marker frame can
    /// only ever be tested against a span with real, non-zero-length bounds.
    ///
    /// The nearer-edge rule is the SAME idea as `cutIndex(forFrame:pieces:)`'s (text is
    /// never torn mid-word — a frame with no room on one side cuts at the other), but
    /// "mirrors it exactly" overstates it for one real case: `TranscriptSplice` degrades
    /// a touched span into one or more `.inherited` FRAGMENTS that all carry the PARENT
    /// span's FULL bounds (`TranscriptSplice.swift`, the "each carrying the PARENT
    /// SPAN'S FULL bounds" rule), so two or more CONSECUTIVE placeable spans can share
    /// an identical `[frameStart, frameEnd)`. `firstIndex(where:)` finds the FIRST such
    /// fragment, and "nearer the end" then cuts after that FIRST fragment — not after
    /// the run those fragments came from. This is still safe: nothing tears mid-word
    /// (the splice round-trip keeps fragment texts space-aligned, so a cut between two
    /// same-bounds fragments lands on a real text boundary, never inside one), and the
    /// result is flagged `structuralApprox: true` either way, same as every other
    /// interior cut — the imprecision is disclosed, not silently claimed as exact.
    ///
    /// No longer an open question (Gate B Minor 4): this used to say "left for Gate B if a
    /// cheap fixture surfaces". One did, and the shape turned out to be the ORDINARY
    /// post-edit one rather than exotic — pinned by `TranscriptAttributionTests`'
    /// `testTwoPlaceableSpansSharingBoundsCutAfterTheFirstFragmentAndFlagItApproximate`,
    /// which is also the only fixture that fails if `firstIndex` becomes `lastIndex`.
    private static func placeableCutPosition(
        forFrame frame: Int64, spans: [TranscriptSpan], placeableIndices: [Int]
    ) -> (position: Int, structuralApprox: Bool) {
        if let insideAt = placeableIndices.firstIndex(where: { idx in
            let span = spans[idx]
            return span.frameStart! < frame && frame < span.frameEnd!
        }) {
            let span = spans[placeableIndices[insideAt]]
            if frame - span.frameStart! < span.frameEnd! - frame {
                return (insideAt, true)       // nearer the start -> cut before the span
            } else {
                return (insideAt + 1, true)   // nearer the end -> cut after the span
            }
        }
        let position = placeableIndices.firstIndex { spans[$0].frameStart! >= frame } ?? placeableIndices.count
        return (position, false)
    }

    /// Converts a placeable-space cut position back into a real index into `spans`. A
    /// position landing strictly between two placeable spans resolves to the FULL index
    /// of the NEXT placeable span — which pulls every non-placeable span between the
    /// previous placeable span and this one into the group that ENDS here, never the
    /// group that starts here (the "inherit the nearest PRECEDING placeable span" rule,
    /// enforced structurally rather than by a special case). Position ==
    /// `placeableIndices.count` (cut after the last placeable span) resolves to
    /// `spans.count`, so trailing non-placeable spans stay in the final group too.
    ///
    /// `position < placeableIndices.count` implicitly assumes `placeableIndices`
    /// (equivalently, `spans`) is ordered ascending by `frameStart` — true for every
    /// producer today (`TranscriptRevisionStore.spans(fromCommitted:)`,
    /// `TranscriptSplice.spans`), but not an invariant this function enforces, and a
    /// future write path could violate it (e.g. a merge that reorders spans without
    /// re-deriving frame order). The blast radius if it ever is violated is bounded: the
    /// caller (`attribute(spans:snapped:)`) always builds paragraphs from `groupStart`
    /// forward in ARRAY order and every group's range is `Range<Int>` over `spans`
    /// directly, so the output still covers `0..<spans.count` exactly once, in order,
    /// with every span's text included exactly once — only WHERE a boundary lands could
    /// degrade (a marker attributed to the wrong side of a cut), never data loss,
    /// duplication, or a crash.
    private static func fullSpanIndex(forPlaceablePosition position: Int,
                                      spans: [TranscriptSpan], placeableIndices: [Int]) -> Int {
        position < placeableIndices.count ? placeableIndices[position] : spans.count
    }

    /// Same walk-and-collapse rule as `breakpoints(for:pieces:)` below (see that
    /// function's doc comment for the marker-ordering / re-tap / collapsing rules, all
    /// unchanged here) — retargeted at the span/placeable-index cut computation instead
    /// of the piece stream.
    private static func spanBreakpoints(for relevantMarkers: [MarkerSnapping.SnappedMarker],
                                        spans: [TranscriptSpan],
                                        placeableIndices: [Int]) -> [Int: Breakpoint] {
        var activeVoice: String?
        var result: [Int: Breakpoint] = [:]

        for marker in relevantMarkers {
            let (position, structuralApprox) = placeableCutPosition(forFrame: marker.snappedFrame,
                                                                     spans: spans,
                                                                     placeableIndices: placeableIndices)
            let index = fullSpanIndex(forPlaceablePosition: position, spans: spans, placeableIndices: placeableIndices)
            let approx = marker.approximate || structuralApprox

            var isBreak = false
            switch marker.marker.kind {
            case .paragraph:
                isBreak = true
            case .voice:
                if marker.marker.voice != activeVoice {
                    isBreak = true
                }
                activeVoice = marker.marker.voice
            // T7 Task 6: correction kinds are resolved into effective `.voice`/
            // `.paragraph` records by `MarkerCorrections.effectiveMarkers` before a
            // marker list ever reaches attribution (see `isRenderable`'s doc comment
            // above `spanBreakpoints`) — unreachable in production, kept only so an
            // unfolded list (or an even-newer kind this build doesn't understand)
            // fails safe instead of losing compiler exhaustiveness coverage.
            case .correctionRetract, .correctionVoice, .correctionBoundaryAdd, .unknown:
                continue
            }

            var breakpoint = result[index] ?? Breakpoint(voice: activeVoice, approximate: false, isBreak: false)
            breakpoint.voice = activeVoice
            breakpoint.approximate = breakpoint.approximate || approx
            breakpoint.isBreak = breakpoint.isBreak || isBreak
            result[index] = breakpoint
        }
        return result
    }

    /// A paragraph's text over a slice of `spans`, via `TranscriptText.join` — the ONE
    /// join rule (design §4.2 rule 8), the SAME rule `TranscriptChain.plainText` uses.
    /// This is what makes a no-marker call reproduce `plainText(revision)` byte-for-byte:
    /// one group covering every span, joined the identical way. Unlike
    /// `paragraph(pieces:...)` above, there is no "whole record verbatim vs joined runs"
    /// distinction to make here — a `TranscriptSpan` is already the atomic text unit a
    /// revision's `plainText` itself joins, so one rule suffices.
    private static func spanParagraph(spans: [TranscriptSpan], range: Range<Int>,
                                      voice: String?, approximate: Bool) -> Paragraph {
        guard !range.isEmpty else {
            return Paragraph(voice: voice, text: "", hasApproximateBoundary: approximate, spanRange: range)
        }
        let text = TranscriptText.join(spans[range].map(\.text))
        return Paragraph(voice: voice, text: text, hasApproximateBoundary: approximate, spanRange: range)
    }

    // MARK: - Pieces

    private static func pieces(from records: [TranscriptResult]) -> [Piece] {
        var extracted: [Piece] = []
        for (recordIndex, record) in records.enumerated() {
            let timed = record.runs.compactMap { run -> Piece? in
                guard let start = run.captureFrameStart, let end = run.captureFrameEnd else { return nil }
                return Piece(start: start, end: end, text: run.text, recordIndex: recordIndex)
            }
            if !record.runs.isEmpty, timed.count == record.runs.count {
                extracted.append(contentsOf: timed)
            } else {
                extracted.append(Piece(start: record.range.start,
                                       end: record.range.end,
                                       text: record.text,
                                       recordIndex: recordIndex))
            }
        }
        return extracted
    }

    /// T7 Task 6: correction kinds are never directly renderable — a fold step
    /// (`MarkerCorrections.effectiveMarkers`) resolves them into equivalent `.voice`/
    /// `.paragraph` records (or drops them, for a retract) before markers ever reach
    /// this function. These three cases exist only so an unfolded list fails safe
    /// (ignored, like `.unknown`) rather than the compiler's exhaustiveness check
    /// silently going away.
    private static func isRenderable(_ kind: StructureMarker.Kind) -> Bool {
        switch kind {
        case .voice, .paragraph: return true
        case .correctionRetract, .correctionVoice, .correctionBoundaryAdd, .unknown: return false
        }
    }

    // MARK: - Cut position

    /// Finds the piece index to cut before, and whether the cut lands strictly inside a
    /// piece (task-1-brief.md step 3). A frame that lands inside a piece cuts at the
    /// piece's nearer edge — text is never torn mid-word, because frames give no
    /// character offset to tear at correctly.
    private static func cutIndex(forFrame frame: Int64, pieces: [Piece]) -> (index: Int, structuralApprox: Bool) {
        if let insideIndex = pieces.firstIndex(where: { $0.start < frame && frame < $0.end }) {
            let piece = pieces[insideIndex]
            if frame - piece.start < piece.end - frame {
                return (insideIndex, true)       // nearer the start -> cut before the piece
            } else {
                return (insideIndex + 1, true)   // nearer the end -> cut after the piece
            }
        }
        let index = pieces.firstIndex { $0.start >= frame } ?? pieces.count
        return (index, false)
    }

    // MARK: - Breakpoints

    private struct Breakpoint {
        /// Active voice right after every marker at this index has been processed, in
        /// order. Carried onto the paragraph that starts at this index.
        var voice: String?
        var approximate: Bool
        var isBreak: Bool
    }

    /// Walks `relevantMarkers` in their sorted (frame, seq) order, once, tracking the
    /// voice in force as it goes (design §2 decision 4: the frame-0 opener removes the
    /// special case for "before the first marker"). A `.paragraph` marker always
    /// breaks; a `.voice` marker breaks only when it actually changes the active voice
    /// — a re-tap of the same voice updates nothing observable and must not manufacture
    /// an empty paragraph. Markers that land at the same cut index collapse into one
    /// breakpoint: the final `voice`/`approximate`/`isBreak` reflect all of them.
    private static func breakpoints(for relevantMarkers: [MarkerSnapping.SnappedMarker],
                                    pieces: [Piece]) -> [Int: Breakpoint] {
        var activeVoice: String?
        var result: [Int: Breakpoint] = [:]

        for marker in relevantMarkers {
            let (index, structuralApprox) = cutIndex(forFrame: marker.snappedFrame, pieces: pieces)
            let approx = marker.approximate || structuralApprox

            var isBreak = false
            switch marker.marker.kind {
            case .paragraph:
                isBreak = true
            case .voice:
                if marker.marker.voice != activeVoice {
                    isBreak = true
                }
                activeVoice = marker.marker.voice
            // T7 Task 6: see `spanBreakpoints`'s identical case above — corrections are
            // folded away before reaching here; this is fail-safe coverage only.
            case .correctionRetract, .correctionVoice, .correctionBoundaryAdd, .unknown:
                continue
            }

            var breakpoint = result[index] ?? Breakpoint(voice: activeVoice, approximate: false, isBreak: false)
            breakpoint.voice = activeVoice
            breakpoint.approximate = breakpoint.approximate || approx
            breakpoint.isBreak = breakpoint.isBreak || isBreak
            result[index] = breakpoint
        }
        return result
    }

    // MARK: - Text assembly

    /// The exactness rule (brief step 6): a paragraph's pieces are grouped by
    /// `recordIndex`. A group holding *every* piece of its record uses that record's
    /// `text` verbatim; otherwise its run texts join with `""`. Groups join with `" "`.
    /// This is what makes the no-marker case reproduce
    /// `TranscriptConsolidator.committedText` byte-for-byte instead of "almost" — that
    /// join also filters empty record texts, reproduced here.
    private static func paragraph(pieces: [Piece],
                                  range: Range<Int>,
                                  records: [TranscriptResult],
                                  recordPieceCounts: [Int: Int],
                                  voice: String?,
                                  approximate: Bool) -> Paragraph {
        guard !range.isEmpty else {
            return Paragraph(voice: voice, text: "", hasApproximateBoundary: approximate)
        }

        var order: [Int] = []
        var grouped: [Int: [Piece]] = [:]
        for i in range {
            let piece = pieces[i]
            if grouped[piece.recordIndex] == nil { order.append(piece.recordIndex) }
            grouped[piece.recordIndex, default: []].append(piece)
        }

        let text = order
            .map { recordIndex -> String in
                let groupPieces = grouped[recordIndex] ?? []
                if groupPieces.count == recordPieceCounts[recordIndex] {
                    return records[recordIndex].text
                }
                return groupPieces.map(\.text).joined(separator: "")
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Paragraph(voice: voice, text: text, hasApproximateBoundary: approximate)
    }
}
