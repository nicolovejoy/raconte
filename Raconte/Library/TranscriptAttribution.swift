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

    static func displayName(forVoice voice: String) -> String {
        voice.uppercased()
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

    private static func isRenderable(_ kind: StructureMarker.Kind) -> Bool {
        switch kind {
        case .voice, .paragraph: return true
        case .unknown: return false
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
            case .unknown:
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
