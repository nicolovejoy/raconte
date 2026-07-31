import Foundation

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

    mutating func apply(_ result: TranscriptResult) {
        if result.isVolatile {
            applyVolatile(result)
        } else {
            applyFinal(result)
        }
    }

    /// A final result supersedes any volatile hypothesis it overlaps — that overlap
    /// *is* the promotion signal, driven by the analyzer's `resultsFinalizationTime`
    /// having moved past the range (design §4). It also revises any committed result
    /// covering the same span, which is how a late correction lands.
    private mutating func applyFinal(_ result: TranscriptResult) {
        provisional.removeAll { $0.range.overlaps(result.range) }
        committed.removeAll { $0.range.overlaps(result.range) }
        // An empty final is a deletion, not a word: the overlap sweep above is the
        // whole effect. Inserting it would put an empty run in the transcript.
        guard !result.text.isEmpty else { return }
        committed.insert(result, at: insertionIndex(in: committed, for: result.range))
    }

    /// An empty-text volatile result **revokes** its range — the transcriber
    /// withdrawing a hypothesis it no longer believes. Treating it as "a result whose
    /// text happens to be empty" would leave the retracted words on screen.
    private mutating func applyVolatile(_ result: TranscriptResult) {
        provisional.removeAll { $0.range.overlaps(result.range) }
        guard !result.text.isEmpty else { return }
        provisional.insert(result, at: insertionIndex(in: provisional, for: result.range))
    }

    /// Results arrive out of order often enough that appending is wrong; position is
    /// always decided by the capture-frame axis, never by arrival.
    private func insertionIndex(in list: [TranscriptResult], for range: FrameRange) -> Int {
        list.firstIndex { $0.range.start > range.start } ?? list.count
    }

    /// What the transcriber stands behind. This is what gets persisted.
    var committedText: String { Self.join(committed) }

    /// Committed text plus the live hypothesis — the capture screen's ghost text.
    /// Never persist this.
    var displayText: String { Self.join(committed + provisional) }

    /// Joined with single spaces. Real spacing and punctuation are the canonical
    /// transcript's problem (T6/T7), not the live overlay's.
    private static func join(_ results: [TranscriptResult]) -> String {
        results.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension FrameRange {
    /// Half-open overlap: `[start, end)`. Touching ranges do not overlap, which is
    /// what makes adjacent results coexist instead of evicting each other.
    func overlaps(_ other: FrameRange) -> Bool {
        start < other.end && other.start < end
    }
}
