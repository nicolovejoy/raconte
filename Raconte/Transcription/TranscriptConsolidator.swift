import Foundation

/// One span of the live transcript, in frame order, with the one distinction the screen
/// can honestly draw (#118 §5): committed text is what the transcriber stands behind;
/// provisional is the hypothesis it may still revise. Sentence boundaries are not tracked
/// anywhere in the pipeline, so "current sentence vs earlier" is unbuildable — this is
/// the real seam.
///
/// Named `ConsolidatedTranscriptRun`, not the brief's `TranscriptRun`: that name is
/// already `TranscriptRecord.swift`'s Codable, persisted, per-attribution run type, used
/// throughout `Raconte`/`RaconteTests`. The two are unrelated (this one is a live/UI
/// merge of committed+provisional spans; that one is what gets written to disk) and a
/// same-module redeclaration does not compile — this type gets a distinct name instead.
struct ConsolidatedTranscriptRun: Equatable, Sendable {
    var text: String
    var range: FrameRange
    var isProvisional: Bool

    /// One committed run standing for a finished transcript, for surfaces that hold the
    /// text after the consolidator is gone. The range is a placeholder — nothing sorts or
    /// merges these.
    static func wholeCommitted(_ text: String) -> [ConsolidatedTranscriptRun] {
        text.isEmpty ? [] : [ConsolidatedTranscriptRun(text: text, range: FrameRange(start: 0, end: 0), isProvisional: false)]
    }
}

/// Merges the transcriber's two result streams into one ordered view (design §8).
///
/// The SDK emits *volatile* results — provisional hypotheses over a range that get
/// revised, superseded, or withdrawn — interleaved with final ones. The sharp edge
/// this type exists to blunt: **a volatile result is never promoted to committed
/// text.** Committed text only ever comes from a result that arrived with
/// `isVolatile == false`. Anything else means the UI shows words the transcriber
/// later retracted, in a journal, permanently.
///
/// Pure and synchronous on purpose: every rule below is reachable from a unit test
/// with no engine, no models, and no clock.
struct TranscriptConsolidator: Sendable, Equatable {

    /// Finalized results, ordered by `range.start`. Append-only in spirit; a later
    /// final result may revise an overlapping earlier one.
    private(set) var committed: [TranscriptResult] = []

    /// The volatile overlay. Wholly replaceable, never a source of committed text.
    private(set) var provisional: [TranscriptResult] = []

    init() {}

    /// Apply one result and report what must reach `live.jsonl`.
    ///
    /// The return value is the whole answer to issue #10. An append-only log can only
    /// reproduce the live view if it records *every mutation of `committed`*, in order —
    /// which is two kinds of event, not one:
    ///
    /// - a result that arrived final, **including empty-text ones**, because those are
    ///   deletions and dropping them makes a revoked span reappear on replay;
    /// - a hypothesis promoted by `finalizedThroughFrame` advancing, because the SDK may
    ///   never reissue it and it would otherwise exist only in memory.
    ///
    /// Both are emitted as non-volatile results, so replay is exactly this same method
    /// fed the log in file order — the overlap and deletion rules stay in one tested
    /// place and the file format stays dumb. See `LiveTranscriptReader.consolidate`.
    @discardableResult
    mutating func apply(_ result: TranscriptResult) -> [TranscriptResult] {
        var log: [TranscriptResult] = []
        if result.isVolatile {
            applyVolatile(result)
        } else {
            applyFinal(result)
            log.append(result)
        }
        // After, not before: the sweep above has already evicted anything this result
        // supersedes, so promotion only ever considers hypotheses that survived it.
        if let through = result.finalizedThroughFrame {
            log.append(contentsOf: promote(through: through))
        }
        return log
    }

    /// Move hypotheses the transcriber has settled past into `committed`.
    ///
    /// Apple: *"all previously-provided results with a `range` predating
    /// `resultsFinalizationTime` are also final"* — and, critically, a module need not
    /// reissue them. Without this, every phrase recognized correctly on the first try is
    /// finalized by the marker, never resent, then swept out of `provisional` by the next
    /// overlapping result, reaching the saved transcript nowhere.
    ///
    /// Deliberately conservative in one respect: a promoted hypothesis never displaces a
    /// committed result. A result that actually arrived final is the transcriber's
    /// considered answer over that span; a hypothesis is not, and out-of-order arrival
    /// must not let the weaker one win.
    private mutating func promote(through frame: Int64) -> [TranscriptResult] {
        guard !provisional.isEmpty else { return [] }
        let settled = provisional.filter { $0.range.end <= frame }
        guard !settled.isEmpty else { return [] }
        provisional.removeAll { $0.range.end <= frame }

        var promoted: [TranscriptResult] = []
        for var result in settled where !result.text.isEmpty {
            guard !committed.contains(where: { $0.range.supersededBy(result.range) }) else { continue }
            result.isVolatile = false
            committed.insert(result, at: insertionIndex(in: committed, for: result.range))
            promoted.append(result)
        }
        return promoted
    }

    /// A final result supersedes any volatile hypothesis it overlaps — that overlap
    /// *is* the promotion signal, driven by the analyzer's `resultsFinalizationTime`
    /// having moved past the range (design §4). It also revises any committed result
    /// covering the same span, which is how a late correction lands.
    private mutating func applyFinal(_ result: TranscriptResult) {
        provisional.removeAll { $0.range.supersededBy(result.range) }
        committed.removeAll { $0.range.supersededBy(result.range) }
        // An empty final is a deletion, not a word: the overlap sweep above is the
        // whole effect. Inserting it would put an empty run in the transcript.
        guard !result.text.isEmpty else { return }
        committed.insert(result, at: insertionIndex(in: committed, for: result.range))
    }

    /// An empty-text volatile result **revokes** its range — the transcriber
    /// withdrawing a hypothesis it no longer believes. Treating it as "a result whose
    /// text happens to be empty" would leave the retracted words on screen.
    private mutating func applyVolatile(_ result: TranscriptResult) {
        provisional.removeAll { $0.range.supersededBy(result.range) }
        guard !result.text.isEmpty else { return }
        provisional.insert(result, at: insertionIndex(in: provisional, for: result.range))
    }

    /// Results arrive out of order often enough that appending is wrong; position is
    /// always decided by the capture-frame axis, never by arrival.
    private func insertionIndex(in list: [TranscriptResult], for range: FrameRange) -> Int {
        list.firstIndex { $0.range.start > range.start } ?? list.count
    }

    /// What the transcriber stands behind. This is what gets persisted.
    var committedText: String { TranscriptText.join(committed.map(\.text)) }

    /// Committed and provisional runs merged by FRAME POSITION, not arrival order, and
    /// not "committed then provisional". Results arrive out of order often enough that a
    /// hypothesis can precede committed text; appending it after would render it in the
    /// wrong place — visibly, the moment it happens. The screen dims on `isProvisional`,
    /// never on position, for the same reason.
    var runs: [ConsolidatedTranscriptRun] {
        let all = committed.map { ConsolidatedTranscriptRun(text: $0.text, range: $0.range, isProvisional: false) }
                + provisional.map { ConsolidatedTranscriptRun(text: $0.text, range: $0.range, isProvisional: true) }
        return all.sorted { $0.range.start < $1.range.start }
    }

    /// Committed text plus the live hypothesis — the capture screen's ghost text. Derived
    /// from `runs` so the two cannot drift. Never persist this.
    var displayText: String { TranscriptText.join(runs.map(\.text)) }
}

extension FrameRange {
    /// Half-open overlap: `[start, end)`. Touching ranges do not overlap, which is
    /// what makes adjacent results coexist instead of evicting each other.
    func overlaps(_ other: FrameRange) -> Bool {
        start < other.end && other.start < end
    }

    /// Whether a result over `self` is replaced by one over `other`.
    ///
    /// Overlap alone is not the test. A zero-length result (`start == end`) never
    /// overlaps anything under the strict comparison, so a final result with an empty
    /// range used to supersede nothing — leaving the stale hypothesis it was meant to
    /// promote on screen indefinitely. Containment covers that case.
    func supersededBy(_ other: FrameRange) -> Bool {
        overlaps(other) || other.contains(self) || contains(other)
    }

    /// True when `other` sits entirely within this range, endpoints included — so a
    /// zero-length range at a boundary still counts.
    func contains(_ other: FrameRange) -> Bool {
        other.start >= start && other.end <= end
    }
}
