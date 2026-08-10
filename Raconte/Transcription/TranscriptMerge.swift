import Foundation

/// Pure minting of merge revisions (design §6). No I/O, no actor isolation — every
/// function here is a value transform from revisions already in hand to a new
/// in-memory `TranscriptRevision`; persistence is `TranscriptRevisionStore.append`,
/// which treats a merge as an ordinary revision.
///
/// v1 is whole-revision (owner decision §12.6): accept/decline/revert each replace
/// the entire span array, never a hunk. Per-hunk merge is out of scope; `degradingOverlaps`
/// ships anyway because both accept and revert route conceptually through the F11 rule
/// once per-hunk lands, and it is cheap to pin now.

/// The #41.2 precondition, enforced at the mint site so no caller can skip it: a
/// human-lineage revision's id must never be written into `basedOnMachineID` — that
/// field is permanent once minted and poisons §6.4 propagation forever (every later
/// user edit copies it verbatim, per `TranscriptRevisionStore`'s propagation rule).
enum TranscriptMergeError: Error, Equatable {
    case notMachineLineage(String)
}

enum TranscriptMerge {

    /// Accept: adopt the machine revision's spans verbatim — text and frames together,
    /// unchanged anchor included (design §6.3: "the legitimate route up the lattice,"
    /// F18's merge exemption — a borrowed span ordinarily degrades on the way into a
    /// new revision, but a merge's adoption is sound because text and frames arrived
    /// from one fresh measurement). `parentID` = current's id, `basedOnMachineID` =
    /// the accepted machine revision's id, `source` = `.merge`.
    static func accept(current: TranscriptRevision, machine: TranscriptRevision,
                       id: String, createdAt: Date, deviceID: String?) throws -> TranscriptRevision {
        guard !machine.source.isHumanLineage else {
            throw TranscriptMergeError.notMachineLineage(machine.id)
        }
        return mint(spans: adopt(machine.spans, from: machine), id: id, createdAt: createdAt,
                    parentID: current.id, basedOnMachineID: machine.id, deviceID: deviceID)
    }

    /// Decline: spans byte-identical to current's, `basedOnMachineID` advanced to the
    /// declined machine revision's id.
    ///
    /// text-identical is intentional — see §6.5, this is not the §2.5 no-op rule: a
    /// draft equal to current closes to nothing because NO field changes, but a decline
    /// changes `basedOnMachineID` even though its spans match current's exactly. It is
    /// a real recorded action (the same `.merge` primitive as accept), not a discard.
    static func decline(current: TranscriptRevision, machine: TranscriptRevision,
                        id: String, createdAt: Date, deviceID: String?) throws -> TranscriptRevision {
        guard !machine.source.isHumanLineage else {
            throw TranscriptMergeError.notMachineLineage(machine.id)
        }
        return mint(spans: adopt(current.spans, from: current), id: id, createdAt: createdAt,
                    parentID: current.id, basedOnMachineID: machine.id, deviceID: deviceID)
    }

    /// Revert: adopt the reverted-to machine revision's spans verbatim (design §6.5) —
    /// same shape as `accept`, restoring an earlier machine revision's `.exact` anchors
    /// legitimately (they arrive with their own frames, not synthesized). `parentID` =
    /// current's id, `basedOnMachineID` = the reverted-to machine revision's id.
    static func revert(current: TranscriptRevision, toMachine machine: TranscriptRevision,
                       id: String, createdAt: Date, deviceID: String?) throws -> TranscriptRevision {
        guard !machine.source.isHumanLineage else {
            throw TranscriptMergeError.notMachineLineage(machine.id)
        }
        return mint(spans: adopt(machine.spans, from: machine), id: id, createdAt: createdAt,
                    parentID: current.id, basedOnMachineID: machine.id, deviceID: deviceID)
    }

    /// F11 rule, shipped for future per-hunk use: any RETAINED span whose frame range
    /// intersects an ADOPTED span's degrades to `.inherited`. Without this, a per-hunk
    /// accept can leave two `.exact` spans over the same audio (design §6.3's example:
    /// a retained [0,100] run alongside an adopted [45,100] re-segmentation) — the exact
    /// lie the anchor scheme exists to prevent. Adopted spans are returned unmodified
    /// (only `retained` is ever degraded); property: after this call, no two `.exact`
    /// spans in `retained + adopted` intersect.
    ///
    /// Only spans with usable bounds can intersect at all — a `.none`/`.unknown`
    /// retained span, or one degrading against an adopted span with no usable bounds,
    /// simply passes through unchanged.
    static func degradingOverlaps(retained: [TranscriptSpan],
                                  adopted: [TranscriptSpan]) -> [TranscriptSpan] {
        let adoptedRanges: [FrameRange] = adopted.compactMap { span in
            guard span.anchor.hasUsableBounds,
                  let start = span.frameStart, let end = span.frameEnd else { return nil }
            return FrameRange(start: start, end: end)
        }
        guard !adoptedRanges.isEmpty else { return retained }

        return retained.map { span in
            guard span.anchor.hasUsableBounds,
                  let start = span.frameStart, let end = span.frameEnd else { return span }
            let range = FrameRange(start: start, end: end)
            guard adoptedRanges.contains(where: range.overlaps) else { return span }
            return TranscriptSpan(text: span.text, anchor: .inherited,
                                  frameStart: span.frameStart, frameEnd: span.frameEnd,
                                  confidence: span.confidence, sourceRevisionID: span.sourceRevisionID)
        }
    }

    // MARK: - Private

    /// Copies `spans` verbatim out of `source` and into a new revision, writing each
    /// span's `sourceRevisionID` EXPLICIT via `resolvedSourceRevisionID(in:)` — mirrors
    /// `TranscriptSplice`'s rule for borrowed spans (see its doc comment and
    /// `TranscriptRevisionStore.closeDraft`): a span's own field is nil exactly when it
    /// equals the revision it currently lives in, so copying that nil verbatim into a
    /// DIFFERENT revision would misresolve to the new revision's own id instead of
    /// `source`'s.
    private static func adopt(_ spans: [TranscriptSpan], from source: TranscriptRevision) -> [TranscriptSpan] {
        spans.map { span in
            var copy = span
            copy.sourceRevisionID = span.resolvedSourceRevisionID(in: source)
            return copy
        }
    }

    /// Builds the merge revision and applies the caller-side half of the omit-when-equal
    /// economy (`TranscriptSpan.swift:150-156`): now that the new id is known, drop any
    /// span's `sourceRevisionID` back to nil wherever it happens to equal it — the same
    /// final step `closeDraft` performs after minting.
    private static func mint(spans: [TranscriptSpan], id: String, createdAt: Date,
                             parentID: String, basedOnMachineID: String,
                             deviceID: String?) -> TranscriptRevision {
        var finalSpans = spans
        for index in finalSpans.indices where finalSpans[index].sourceRevisionID == id {
            finalSpans[index].sourceRevisionID = nil
        }
        return TranscriptRevision(id: id, source: .merge, createdAt: createdAt, spans: finalSpans,
                                  parentID: parentID, basedOnMachineID: basedOnMachineID,
                                  deviceID: deviceID)
    }
}
