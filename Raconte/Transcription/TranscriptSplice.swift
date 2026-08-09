import Foundation

/// Pure diff-and-splice engine (design §3.3). No I/O, no actor isolation — a value
/// transform from a parent revision plus freshly edited text to a new span array, so
/// every rule in the design's §10 table can be pinned as a plain unit test.
enum TranscriptSplice {

    /// Diffs `editedText` against `parent`'s flattened text — the exact same
    /// `TranscriptText.join` rule `TranscriptChain.plainText` uses, so the base a human
    /// edits against is what they actually saw — and rewrites `parent.spans` per §3.3:
    ///
    /// - an untouched span is copied verbatim (text, frames, anchor);
    /// - a span touched anywhere (a character removed from it, or new text inserted into
    ///   its interior) degrades to one or more `.inherited` fragments, each carrying the
    ///   PARENT SPAN'S FULL bounds — never a synthesized sub-range (F17). A span with no
    ///   usable bounds to begin with (`.none`/`.unknown`) degrades its fragments to
    ///   `.none` instead, since there is nothing to inherit;
    /// - newly typed text becomes an `.inherited` zero-length point at the nearest
    ///   preceding OUTPUT span with usable bounds (`.none` if there is none);
    /// - a wholly deleted span simply produces no output — frames are never redistributed
    ///   to a neighbour;
    /// - adjacent spans sharing `anchor == .none`, or sharing `anchor == .inherited` with
    ///   identical bounds AND `sourceRevisionID`, are merged. `.exact` spans never merge,
    ///   and merging never crosses a still-present separator between two originally
    ///   distinct spans (that separator is `TranscriptText.join`'s job to reinsert on
    ///   read, not this function's to store).
    ///
    /// `sourceRevisionID` on every BORROWED span (unchanged or fragment) is written
    /// EXPLICIT — `parentSpan.resolvedSourceRevisionID(in: parent)` — never left to
    /// default-resolve against whatever revision this output eventually gets minted
    /// into. This function doesn't know that id yet (the caller mints it after seeing
    /// the spliced spans); dropping a borrowed span's id back to nil where it happens to
    /// equal the new revision's own id (`TranscriptSpan.swift` :150-156, the Task 1
    /// ledger note on the omit-when-equal economy) is the caller's job, once that id is
    /// known — see `TranscriptRevisionStore.closeDraft`.
    static func spans(parent: TranscriptRevision, editedText: String) -> [TranscriptSpan] {
        let parentSpans = parent.spans

        // MARK: - Flatten parent spans into (character, provenance) positions, exactly
        // mirroring TranscriptText.join: empty spans are skipped, and a single synthetic
        // space separates each pair of adjacent non-empty spans. `.separator` positions
        // are never attributed to any span — they exist only to diff against.
        enum Origin: Equatable {
            case span(index: Int, charIndex: Int)
            case separator
        }
        var positions: [(char: Character, origin: Origin)] = []
        let nonEmptyIndices = parentSpans.indices.filter { !parentSpans[$0].text.isEmpty }
        for (k, spanIndex) in nonEmptyIndices.enumerated() {
            if k > 0 {
                positions.append((" ", .separator))
            }
            for (charIndex, char) in parentSpans[spanIndex].text.enumerated() {
                positions.append((char, .span(index: spanIndex, charIndex: charIndex)))
            }
        }

        let sourceChars = positions.map(\.char)
        let targetChars = Array(editedText)

        // MARK: - The locked decision: Character-level Myers diff, no move inference.
        let diff = targetChars.difference(from: sourceChars)
        var removedOffsets = Set<Int>()
        var insertedAt: [Int: Character] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, let element, _):
                insertedAt[offset] = element
            }
        }

        // MARK: - Walk target positions into atoms carrying provenance (or "inserted").
        enum Atom {
            case spanChar(spanIndex: Int, char: Character)
            case separatorChar
            case insertedChar(Character)
        }
        var atoms: [Atom] = []
        atoms.reserveCapacity(targetChars.count)
        var sourceIndex = 0
        for targetIndex in 0..<targetChars.count {
            if let inserted = insertedAt[targetIndex] {
                atoms.append(.insertedChar(inserted))
                continue
            }
            while removedOffsets.contains(sourceIndex) { sourceIndex += 1 }
            switch positions[sourceIndex].origin {
            case .separator:
                atoms.append(.separatorChar)
            case .span(let spanIndex, _):
                atoms.append(.spanChar(spanIndex: spanIndex, char: positions[sourceIndex].char))
            }
            sourceIndex += 1
        }

        // MARK: - Coalesce adjacent atoms into raw units (the brief's "coalesce adjacent
        // removals+insertions into replacement hunks" instruction, generalized: a run of
        // consecutive atoms belonging to the same parent span, or a run of consecutive
        // inserted characters, becomes one unit — removed characters never produce an
        // atom, so a deletion in the middle of a surviving run coalesces automatically).
        enum RawUnit {
            case spanRun(spanIndex: Int, text: String, length: Int)
            case insertion(text: String)
            case separator
        }
        var rawUnits: [RawUnit] = []
        var i = 0
        while i < atoms.count {
            switch atoms[i] {
            case .separatorChar:
                rawUnits.append(.separator)
                i += 1
            case .insertedChar:
                var text = ""
                while i < atoms.count, case .insertedChar(let char) = atoms[i] {
                    text.append(char)
                    i += 1
                }
                rawUnits.append(.insertion(text: text))
            case .spanChar(let spanIndex, _):
                var text = ""
                while i < atoms.count, case .spanChar(let idx, let char) = atoms[i], idx == spanIndex {
                    text.append(char)
                    i += 1
                }
                rawUnits.append(.spanRun(spanIndex: spanIndex, text: text, length: text.count))
            }
        }

        // A span that survives as more than one run (only possible when new text is
        // inserted into its interior — a deletion never fragments a run, since removed
        // characters simply produce no atom) is touched in every run, even the run that
        // happens to carry every one of its original characters (F17: two runs can never
        // both claim the parent's one frame pair as "unedited").
        var runCounts: [Int: Int] = [:]
        for unit in rawUnits {
            if case .spanRun(let spanIndex, _, _) = unit {
                runCounts[spanIndex, default: 0] += 1
            }
        }

        // MARK: - Emit output spans left to right, tracking the nearest preceding
        // output span with usable bounds (for insertion anchoring) and whether a
        // still-present separator blocks merging with whatever comes next.
        var output: [TranscriptSpan] = []
        var lastUsableFrameEnd: Int64?
        var lastUsableSourceRevisionID: String?
        var blockedByBarrier = true

        func emit(_ span: TranscriptSpan) {
            if !blockedByBarrier, let last = output.last, canMerge(last, span) {
                output[output.count - 1] = merge(last, span)
            } else {
                output.append(span)
            }
            if span.anchor.hasUsableBounds {
                lastUsableFrameEnd = span.frameEnd
                lastUsableSourceRevisionID = span.sourceRevisionID
            }
            blockedByBarrier = false
        }

        for unit in rawUnits {
            switch unit {
            case .separator:
                blockedByBarrier = true

            case .spanRun(let spanIndex, let text, let length):
                let parentSpan = parentSpans[spanIndex]
                let isWhole = runCounts[spanIndex] == 1 && length == parentSpan.text.count
                if isWhole {
                    emit(TranscriptSpan(text: parentSpan.text,
                                        anchor: parentSpan.anchor,
                                        frameStart: parentSpan.frameStart,
                                        frameEnd: parentSpan.frameEnd,
                                        confidence: parentSpan.confidence,
                                        sourceRevisionID: parentSpan.resolvedSourceRevisionID(in: parent)))
                } else if parentSpan.anchor.hasUsableBounds {
                    emit(TranscriptSpan(text: text,
                                        anchor: .inherited,
                                        frameStart: parentSpan.frameStart,
                                        frameEnd: parentSpan.frameEnd,
                                        confidence: nil,
                                        sourceRevisionID: parentSpan.resolvedSourceRevisionID(in: parent)))
                } else {
                    emit(TranscriptSpan(text: text, anchor: .none, confidence: nil, sourceRevisionID: nil))
                }

            case .insertion(let text):
                if let frameEnd = lastUsableFrameEnd {
                    emit(TranscriptSpan(text: text, anchor: .inherited,
                                        frameStart: frameEnd, frameEnd: frameEnd,
                                        confidence: nil, sourceRevisionID: lastUsableSourceRevisionID))
                } else {
                    emit(TranscriptSpan(text: text, anchor: .none, confidence: nil, sourceRevisionID: nil))
                }
            }
        }

        return output
    }

    /// The span-count-growth bound (§3.3): both `.none`, or both `.inherited` with
    /// identical bounds AND identical `sourceRevisionID`. `.exact` never merges — its
    /// distinct frames are the point.
    private static func canMerge(_ a: TranscriptSpan, _ b: TranscriptSpan) -> Bool {
        switch (a.anchor, b.anchor) {
        case (.none, .none):
            return true
        case (.inherited, .inherited):
            return a.frameStart == b.frameStart && a.frameEnd == b.frameEnd
                && a.sourceRevisionID == b.sourceRevisionID
        default:
            return false
        }
    }

    private static func merge(_ a: TranscriptSpan, _ b: TranscriptSpan) -> TranscriptSpan {
        TranscriptSpan(text: a.text + b.text, anchor: a.anchor,
                       frameStart: a.frameStart, frameEnd: a.frameEnd,
                       confidence: nil, sourceRevisionID: a.sourceRevisionID)
    }
}
