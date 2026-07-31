import Foundation

/// One planned recovery step for a single capture (design §3 decision table).
/// The planner emits exactly one per capture; the executor applies it idempotently.
enum RecoveryAction: Equatable {
    /// Nothing durable was captured — remove the whole capture directory (silent).
    case deleteCaptureDirectory(captureID: String)

    /// Raw segments exist but the capture never reached a clean `captured` state
    /// (crashed mid-recording, or manifest missing/corrupt). Normalize any
    /// `.pcm.part`, regenerate missing sidecars, and write a `captured` manifest.
    /// `capture` carries the per-segment plan and recovered duration. The executor
    /// also enqueues finalize afterward. User-facing: "Recovered recording: MM:SS".
    case normalizeToCaptured(RecoveredCapture)

    /// Already `captured`, raw intact, no `.m4a` yet — hand to the finalizer.
    case enqueueFinalize(captureID: String)

    /// A finalize was interrupted leaving only `recording.m4a.part`; discard it,
    /// set `captured`, requeue finalize (design §3 finalizing row).
    case discardFinalPartRequeue(captureID: String)

    /// An `.m4a` exists but is unverified this launch — hand to the finalizer to
    /// verify (§5) and, on pass, delete raw. Verification decodes audio, which is
    /// out of the pure executor's scope, so this is a hand-off.
    case verifyFinal(captureID: String)

    /// `complete` with a verified `.m4a` — finish any half-done raw-segment delete
    /// (silent; already an entry).
    case finishRawDelete(captureID: String)

    /// The tree would otherwise have been deleted, but it holds a finalized `.m4a`
    /// or a transcript (issue #8). Leave every byte in place and surface it to the
    /// owner instead. Deliberately a *no-op on disk*: moving the directory would
    /// hide the recording from the UI, and the whole point is that the audio
    /// outlives our confusion about it.
    case quarantineCaptureDirectory(captureID: String)
}

/// The normalization plan for one capture that is being rescued to `captured`.
/// Pure data computed from stats — the executor turns it into filesystem ops.
struct RecoveredCapture: Equatable {
    var captureID: String
    var format: AudioFormatDescriptor
    /// Kept segments in index order (zero-frame segments dropped), each with the
    /// recomputed cumulative `startFrameOffset` and normalization flags.
    var segments: [NormalizedSegment]
    var totalFrames: Int
    var durationSeconds: Double
}

/// One segment's normalization plan.
struct NormalizedSegment: Equatable {
    var index: Int
    /// Whole frames the finalized segment will hold (trailing partial frame dropped).
    var frameCount: Int
    /// Cumulative frames before this segment (recomputed over kept segments).
    var startFrameOffset: Int
    /// Byte length after normalization (== frameCount × bytesPerFrame).
    var byteCount: Int
    /// The on-disk file is `NNNNNN.pcm.part` and must be truncated + renamed.
    var needsPartNormalization: Bool
    /// `NNNNNN.json` is missing and must be regenerated.
    var needsSidecar: Bool
}

/// Pure recovery decision core (design §3/§6): `(DirectorySnapshot) -> [RecoveryAction]`.
/// No filesystem access, no PCM decode — every input is a stat in the snapshot.
enum RecoveryPlanner {
    /// A capture below this total duration is discarded as an accidental tap (§3).
    static let minCaptureDurationSeconds = 0.5

    static func plan(_ snapshot: DirectorySnapshot) -> [RecoveryAction] {
        snapshot.captures.map(plan(for:))
    }

    /// Issue #8. Every delete decision below reasons from `hasData`, which is about
    /// *raw segments* — and a finalized capture has none by design. Rather than
    /// re-deriving that guard at each of the three delete sites (and forgetting it at
    /// the fourth one someone adds later), the decision is made once and then
    /// filtered here.
    static func plan(for capture: CaptureSnapshot) -> RecoveryAction {
        let action = decide(for: capture)
        if case .deleteCaptureDirectory(let id) = action, capture.holdsIrreplaceableArtifacts {
            return .quarantineCaptureDirectory(captureID: id)
        }
        return action
    }

    private static func decide(for capture: CaptureSnapshot) -> RecoveryAction {
        let bpf = DirectorySnapshot.bytesPerFrame(capture.format)
        let recovered = recoveredCapture(from: capture, bytesPerFrame: bpf)
        let hasData = recovered.durationSeconds >= minCaptureDurationSeconds

        let verified = capture.manifest?.final.verifiedAt != nil
        let state = capture.manifest?.state  // nil == missing/corrupt == "unknown"

        switch state {
        case .complete:
            if capture.finalM4APresent && verified { return .finishRawDelete(captureID: capture.captureID) }
            if capture.finalM4APresent { return .verifyFinal(captureID: capture.captureID) }
            // Anomalous: `complete` but no `.m4a`. Keep audio if any, else discard.
            return hasData ? .enqueueFinalize(captureID: capture.captureID)
                           : .deleteCaptureDirectory(captureID: capture.captureID)

        case .finalizing:
            if capture.finalM4APresent { return .verifyFinal(captureID: capture.captureID) }
            if !hasData { return .deleteCaptureDirectory(captureID: capture.captureID) }
            if capture.finalM4APartPresent { return .discardFinalPartRequeue(captureID: capture.captureID) }
            return .enqueueFinalize(captureID: capture.captureID)

        case .captured:
            if capture.finalM4APresent && verified { return .finishRawDelete(captureID: capture.captureID) }
            if capture.finalM4APresent { return .verifyFinal(captureID: capture.captureID) }
            if !hasData { return .deleteCaptureDirectory(captureID: capture.captureID) }
            // Already-clean captured: leave state, enqueue finalize. If a stray
            // `.pcm.part` or missing sidecar slipped through, normalize first.
            let needsNormalize = recovered.segments.contains { $0.needsPartNormalization || $0.needsSidecar }
            return needsNormalize ? .normalizeToCaptured(recovered)
                                  : .enqueueFinalize(captureID: capture.captureID)

        case .recording, .interrupted, .resuming, .stopping, .preparing, .idle, .none:
            // Mid-recording crash, or unknown/rebuild-from-files. Trust the segments.
            return hasData ? .normalizeToCaptured(recovered)
                           : .deleteCaptureDirectory(captureID: capture.captureID)
        }
    }

    // MARK: - Segment recovery math (stats only)

    /// Build the ordered, offset-chained normalized-segment list from stats.
    /// Drops zero-frame segments (empty `.part`/`.pcm`), prefers a finalized
    /// `.pcm` over its `.part` sibling, and trusts a present sidecar's frameCount.
    static func recoveredCapture(from capture: CaptureSnapshot, bytesPerFrame bpf: Int) -> RecoveredCapture {
        struct Kept { var index: Int; var frameCount: Int; var needsPart: Bool; var needsSidecar: Bool }

        var kept: [Kept] = []
        for stat in capture.segments.sorted(by: { $0.index < $1.index }) {
            if let pcmSize = stat.pcmByteSize {
                // Finalized `.pcm` present. Trust sidecar frameCount if it agrees in kind.
                let frames = stat.sidecar?.frameCount
                    ?? SegmentLayout.wholeFrameCount(fileSize: pcmSize, bytesPerFrame: bpf)
                guard frames > 0 else { continue }
                kept.append(Kept(index: stat.index, frameCount: frames,
                                 needsPart: false, needsSidecar: stat.sidecar == nil))
            } else if let partSize = stat.partByteSize {
                // Live tail only. Truncate trailing partial frame.
                let frames = SegmentLayout.wholeFrameCount(fileSize: partSize, bytesPerFrame: bpf)
                guard frames > 0 else { continue }
                kept.append(Kept(index: stat.index, frameCount: frames,
                                 needsPart: true, needsSidecar: true))
            }
        }

        let offsets = SegmentLayout.startFrameOffsets(frameCounts: kept.map(\.frameCount))
        let segments = zip(kept, offsets).map { k, offset in
            NormalizedSegment(index: k.index, frameCount: k.frameCount,
                              startFrameOffset: offset, byteCount: k.frameCount * bpf,
                              needsPartNormalization: k.needsPart, needsSidecar: k.needsSidecar)
        }
        let totalFrames = kept.reduce(0) { $0 + $1.frameCount }
        let rate = max(1, capture.format.sampleRate)
        return RecoveredCapture(
            captureID: capture.captureID,
            format: DirectorySnapshot.normalizingBytesPerFrame(capture.format),
            segments: segments,
            totalFrames: totalFrames,
            durationSeconds: Double(totalFrames) / Double(rate))
    }
}
