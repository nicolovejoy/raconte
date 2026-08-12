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
    /// - `TranscriptText.join` (rule 8) inserts a synthetic separator between array
    ///   elements and NEVER within one, so any two pieces of text left adjacent with no
    ///   surviving separator between them (touched or not) MUST become exactly one
    ///   output span, or the boundary is silently fabricated or dropped on the next
    ///   read. Two pieces sharing `anchor == .none`, or sharing `anchor == .inherited`
    ///   with identical bounds AND `sourceRevisionID`, combine cleanly (§3.3's
    ///   span-count-growth bound); anything else forced together this way degrades to
    ///   `.inherited` with the union of both pieces' bounds (`.exact` never survives a
    ///   forced merge — the lattice only ever degrades). Only an intact, UNEDITED
    ///   join-separator may leave two spans adjacent as separate array entries.
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

        // MARK: - Precompute: which insertion runs are a WHOLESALE, ZERO-OVERLAP
        // replacement of exactly one parent span (design §16 ruling 5, owner
        // 2026-08-11 — Task 9b: "Ellen" -> "LN"). The retyped word IS the heard word,
        // corrected, so the replacement inherits the REPLACED span's own frame bounds
        // instead of the brand-new-text `.insertion` case's zero-length point.
        //
        // A capitalized "Ellen" -> "LN" pair shares no characters at all (case-sensitive
        // Myers diff), so every character of "Ellen" lands in `removedOffsets` with
        // nothing surviving as a matched atom — invisible to the atom walk below, which
        // never needs to skip over it (a removed character produces no atom either way,
        // so its removal can go unprocessed there for the rest of the function, e.g. when
        // the insertion is the very last thing in the text). Detected here instead by
        // walking `positions`/`targetChars` directly in lock-step: a run of removed
        // characters that (a) belongs to exactly ONE span, (b) covers ALL of that span's
        // characters, and (c) is immediately followed — no removed separator, no second
        // span, no surviving matched character in between — by newly typed text pairs
        // that insertion with the span it replaced. Anything looser (a partial-span edit,
        // a merge of two spans, a pure deletion with nothing typed after) is deliberately
        // left untagged and keeps today's behavior — the ruling is scoped to one retyped
        // word, not a redesign of the diff classification.
        var wholesaleReplacements: [Int: Int] = [:]  // insertion run's start target offset -> spanIndex
        do {
            var sIdx = 0
            var tIdx = 0
            var pendingActive = false
            var pendingQualifies = false
            var pendingSpan: Int?
            var pendingCharsSeen = 0
            while sIdx < positions.count || tIdx < targetChars.count {
                if sIdx < positions.count, removedOffsets.contains(sIdx) {
                    switch positions[sIdx].origin {
                    case .span(let spanIndex, _):
                        if !pendingActive {
                            pendingActive = true
                            pendingSpan = spanIndex
                            pendingCharsSeen = 1
                            pendingQualifies = true
                        } else if pendingQualifies, pendingSpan == spanIndex {
                            pendingCharsSeen += 1
                        } else {
                            pendingQualifies = false
                        }
                    case .separator:
                        // A removed separator taints whatever run is forming — the ruling
                        // covers one retyped word with its surrounding spacing intact, not
                        // a merge across a deleted boundary.
                        pendingActive = true
                        pendingQualifies = false
                    }
                    sIdx += 1
                } else if tIdx < targetChars.count, insertedAt[tIdx] != nil {
                    if pendingActive, pendingQualifies, let spanIndex = pendingSpan,
                       pendingCharsSeen == parentSpans[spanIndex].text.count {
                        wholesaleReplacements[tIdx] = spanIndex
                    }
                    pendingActive = false
                    pendingQualifies = false
                    pendingSpan = nil
                    pendingCharsSeen = 0
                    tIdx += 1
                } else {
                    // A surviving matched character — nothing was typed in its place, so
                    // any pending removal run before it is a plain deletion, not a
                    // replacement.
                    pendingActive = false
                    pendingQualifies = false
                    pendingSpan = nil
                    pendingCharsSeen = 0
                    sIdx += 1
                    tIdx += 1
                }
            }
        }

        // MARK: - Walk target positions into atoms carrying provenance (or "inserted").
        enum Atom {
            case spanChar(spanIndex: Int, char: Character)
            case separatorChar
            case insertedChar(Character, targetIndex: Int)
        }
        var atoms: [Atom] = []
        atoms.reserveCapacity(targetChars.count)
        var sourceIndex = 0
        for targetIndex in 0..<targetChars.count {
            if let inserted = insertedAt[targetIndex] {
                atoms.append(.insertedChar(inserted, targetIndex: targetIndex))
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
            case insertion(text: String, wholesaleReplacedSpanIndex: Int?)
            case separator
        }
        var rawUnits: [RawUnit] = []
        var i = 0
        while i < atoms.count {
            switch atoms[i] {
            case .separatorChar:
                rawUnits.append(.separator)
                i += 1
            case .insertedChar(_, let startOffset):
                var text = ""
                while i < atoms.count, case .insertedChar(let char, _) = atoms[i] {
                    text.append(char)
                    i += 1
                }
                rawUnits.append(.insertion(text: text, wholesaleReplacedSpanIndex: wholesaleReplacements[startOffset]))
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

        // MARK: - Emit output spans left to right.
        //
        // `TranscriptText.join` (rule 8) inserts exactly one synthetic space STRICTLY
        // BETWEEN array elements — never before the first, never after the last, never
        // more than one at a time. A surviving `.separator` atom can therefore only be
        // left as a "free" gap (nothing stored, join supplies it on read) when it has a
        // real output span on BOTH sides. `pendingSeparators` defers that decision:
        // separators accumulate here until either (a) real content follows, at which
        // point exactly one of them rides for free and any others are materialized as
        // literal spaces onto the previous span (Critical 1, round 2: possible when an
        // entire span between two others was deleted while both its flanking
        // separators survived), or (b) nothing ever follows (trailing separators) or
        // nothing ever preceded (leading separators), in which case ALL of them must be
        // materialized — there is no "before the first" or "after the last" position
        // for join to place a space in.
        var output: [TranscriptSpan] = []
        var lastUsableFrameEnd: Int64?
        var lastUsableSourceRevisionID: String?
        var pendingSeparators = 0
        var hasEmittedAnything = false

        func appendSpaces(_ count: Int, toLastIn output: inout [TranscriptSpan]) {
            guard count > 0, let last = output.last else { return }
            // Incidental whitespace debris from a deletion elsewhere, not content
            // anyone typed within this span — bounds/source are untouched by
            // absorbing it. Anchor is the one exception (F18): the span's TEXT no
            // longer byte-matches its parent once whitespace is appended, so an
            // `.exact` span must degrade to `.inherited` here — the lattice only ever
            // degrades, and "unedited" cannot include "gained characters".
            // `.inherited`/`.none` were already degraded and are unaffected.
            let anchor: SpanAnchor = last.anchor == .exact ? .inherited : last.anchor
            output[output.count - 1] = TranscriptSpan(
                text: last.text + String(repeating: " ", count: count),
                anchor: anchor, frameStart: last.frameStart, frameEnd: last.frameEnd,
                confidence: last.confidence, sourceRevisionID: last.sourceRevisionID)
        }

        func emit(_ span: TranscriptSpan) {
            if !hasEmittedAnything {
                // Nothing precedes this at all. Any pending separators are a LEADING
                // gap — materialize them as a literal prefix. Same F18 exception as
                // `appendSpaces`: a gained leading character means `.exact` must
                // degrade to `.inherited` (text no longer byte-matches the parent).
                if pendingSeparators > 0 {
                    let prefix = String(repeating: " ", count: pendingSeparators)
                    let anchor: SpanAnchor = span.anchor == .exact ? .inherited : span.anchor
                    output.append(TranscriptSpan(
                        text: prefix + span.text, anchor: anchor,
                        frameStart: span.frameStart, frameEnd: span.frameEnd,
                        confidence: span.confidence, sourceRevisionID: span.sourceRevisionID))
                } else {
                    output.append(span)
                }
            } else if pendingSeparators == 0 {
                // Touching the previous content with no surviving separator between
                // them at all — must combine into exactly one span (Critical 1).
                output[output.count - 1] = combine(output[output.count - 1], span)
            } else {
                // One or more separators survived. The LAST one rides free (join will
                // supply it); any earlier ones are materialized onto the previous span.
                appendSpaces(pendingSeparators - 1, toLastIn: &output)
                output.append(span)
            }
            let current = output[output.count - 1]
            if current.anchor.hasUsableBounds {
                lastUsableFrameEnd = current.frameEnd
                lastUsableSourceRevisionID = current.sourceRevisionID
            }
            hasEmittedAnything = true
            pendingSeparators = 0
        }

        for unit in rawUnits {
            switch unit {
            case .separator:
                pendingSeparators += 1

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

            case .insertion(let text, let wholesaleReplacedSpanIndex):
                if let spanIndex = wholesaleReplacedSpanIndex {
                    let replacedSpan = parentSpans[spanIndex]
                    if replacedSpan.anchor.hasUsableBounds,
                       let frameStart = replacedSpan.frameStart,
                       let frameEnd = replacedSpan.frameEnd {
                        // Splice-inherit ruling (design §16.5, owner 2026-08-11 — Task
                        // 9b): a wholesale zero-overlap replacement inherits the
                        // REPLACED span's own bounds, not a zero-length point at some
                        // other span's end.
                        emit(TranscriptSpan(text: text, anchor: .inherited,
                                            frameStart: frameStart, frameEnd: frameEnd,
                                            confidence: nil,
                                            sourceRevisionID: replacedSpan.resolvedSourceRevisionID(in: parent)))
                    } else {
                        // The REPLACED span itself has nothing to inherit — same
                        // principle as the touched-span rule just above (`.none`, nil
                        // source when the parent span has no usable bounds). Falling
                        // through to `lastUsableFrameEnd` here would anchor the
                        // correction at a DIFFERENT span's end under that span's
                        // borrowed provenance — exactly the untruth §16.5 exists to
                        // remove, just aimed at a new victim.
                        emit(TranscriptSpan(text: text, anchor: .none, confidence: nil, sourceRevisionID: nil))
                    }
                } else if let frameEnd = lastUsableFrameEnd {
                    emit(TranscriptSpan(text: text, anchor: .inherited,
                                        frameStart: frameEnd, frameEnd: frameEnd,
                                        confidence: nil, sourceRevisionID: lastUsableSourceRevisionID))
                } else {
                    emit(TranscriptSpan(text: text, anchor: .none, confidence: nil, sourceRevisionID: nil))
                }
            }
        }

        // Trailing separators: nothing followed them, so — same reasoning as the
        // leading case — they cannot rely on join either.
        if pendingSeparators > 0 {
            if output.isEmpty {
                output.append(TranscriptSpan(text: String(repeating: " ", count: pendingSeparators), anchor: .none))
            } else {
                appendSpaces(pendingSeparators, toLastIn: &output)
            }
        }

        return output
    }

    /// Combines two spans that sit adjacent with no surviving separator between them —
    /// unconditional, per `emit`'s round-trip requirement. The clean case (§3.3's
    /// span-count-growth bound: both `.none`, or both `.inherited` with identical
    /// bounds AND identical `sourceRevisionID`) preserves that shared descriptor
    /// exactly; anything else is a FORCED merge (Critical 1) that must still produce
    /// exactly one span, so it degrades to the most conservative common descriptor.
    private static func combine(_ a: TranscriptSpan, _ b: TranscriptSpan) -> TranscriptSpan {
        if canMerge(a, b) {
            return merge(a, b)
        }
        return forcedMerge(a, b)
    }

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

    /// Neither side may remain (or become) `.exact` here — the lattice only ever
    /// degrades (F18), and two spans forced together were, by definition, never a
    /// single unedited measurement. Mismatched bounds have no single honest
    /// descriptor, so the widened union of both real measurements is the
    /// least-fabricating choice available — still "approximate" per §3.2, never
    /// claiming more precision than either side actually had. `.none` on either side
    /// (nothing to inherit) forces the whole result to `.none`.
    private static func forcedMerge(_ a: TranscriptSpan, _ b: TranscriptSpan) -> TranscriptSpan {
        let text = a.text + b.text
        guard a.anchor.hasUsableBounds, b.anchor.hasUsableBounds,
              let aStart = a.frameStart, let aEnd = a.frameEnd,
              let bStart = b.frameStart, let bEnd = b.frameEnd else {
            return TranscriptSpan(text: text, anchor: .none)
        }
        let sourceRevisionID = a.sourceRevisionID == b.sourceRevisionID ? a.sourceRevisionID : nil
        return TranscriptSpan(text: text, anchor: .inherited,
                              frameStart: min(aStart, bStart), frameEnd: max(aEnd, bEnd),
                              sourceRevisionID: sourceRevisionID)
    }
}
