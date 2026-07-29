import Foundation

/// A capture error surfaced to the user and/or recorded in the manifest.
enum CaptureError: String, Sendable, Equatable {
    case permissionDenied
    case configurationFailed
    case diskFull
}

/// A declarative manifest write emitted by the reducer (design §2).
///
/// The reducer never touches disk; it describes the manifest mutation the host
/// must persist. Operational fields the base `Manifest` model doesn't yet carry
/// (`needsAttention`, `lastError`, `retryCount`, `finalizeAttempts`) ride here in
/// the effect payload rather than in the shared `Models/` types (T3 owns those).
struct ManifestUpdate: Sendable, Equatable {
    /// State to persist. For `touchOnly` this is the unchanged current state.
    var state: CaptureState
    /// Post-increment monotonic sequence number (design §2: bumps on every write).
    var stateSeq: Int
    /// New finalized-segment count, when a segment just closed (rows 4, 13). `nil` = leave as-is.
    var segmentCount: Int?
    /// Append an interruption-log entry (rows 5/6/7).
    var appendInterruption: Bool
    /// New retry count after a resume failure (row 10). `nil` = leave as-is.
    var retryCount: Int?
    /// New finalize-attempt count after an encode failure (row 17). `nil` = leave as-is.
    var finalizeAttempts: Int?
    /// Flag the capture as needing attention (row 18).
    var needsAttention: Bool?
    /// Record the last error (row 19).
    var lastError: CaptureError?
    /// Mark `final.verifiedAt` (row 16).
    var markFinalVerified: Bool
    /// Last-gasp: bump only `stateUpdatedAt`/`stateSeq`, change nothing else (row 20).
    var touchOnly: Bool

    init(state: CaptureState,
         stateSeq: Int,
         segmentCount: Int? = nil,
         appendInterruption: Bool = false,
         retryCount: Int? = nil,
         finalizeAttempts: Int? = nil,
         needsAttention: Bool? = nil,
         lastError: CaptureError? = nil,
         markFinalVerified: Bool = false,
         touchOnly: Bool = false) {
        self.state = state
        self.stateSeq = stateSeq
        self.segmentCount = segmentCount
        self.appendInterruption = appendInterruption
        self.retryCount = retryCount
        self.finalizeAttempts = finalizeAttempts
        self.needsAttention = needsAttention
        self.lastError = lastError
        self.markFinalVerified = markFinalVerified
        self.touchOnly = touchOnly
    }
}

/// Side effects the imperative host executes for a transition, in order (design §2).
///
/// Ordering encodes the write-ahead protocol: a `writeManifest` that authorizes an
/// action precedes that action, EXCEPT a segment close (its sidecar) precedes the
/// manifest that claims the segment count, and raw-segment deletion follows the
/// `complete` manifest write.
enum Effect: Sendable, Equatable {
    /// Create `captures/<id>/` (row 1).
    case createCaptureDirectory(captureID: String)
    /// Remove an empty/aborted capture directory (row 3).
    case deleteCaptureDirectory
    /// Request mic permission and configure session + engine (row 1).
    case requestPermissionAndConfigure
    /// Tear down the engine after a failed prepare (row 3).
    case tearDownEngine
    /// Surface an error to the user (rows 3, 19).
    case surfaceError(CaptureError)
    /// Install the tap and open the given segment `.part` (rows 2, 9).
    case installTapAndOpenSegment(index: Int)
    /// Open the next segment `.part` after a rotation close (row 4).
    case openNextSegment(index: Int)
    /// Close the live segment: fsync + rename + write sidecar (rows 4, 5, 6, 7, 13).
    case closeLiveSegment(reason: SegmentClosedReason)
    /// Stop the engine, cutting the tap (rows 5, 6, 13, 19).
    case stopEngine
    /// Discard an unusable engine after a media-services reset (row 7).
    case discardEngine
    /// Rebuild the session + engine to resume (row 8).
    case rebuildSessionAndEngine
    /// Keep the tap alive for the flush window, then remove it (row 12).
    case beginFlushWindow
    /// Release the audio session (row 13).
    case releaseSession
    /// Back off before the next resume attempt (row 10).
    case scheduleResumeBackoff
    /// Encode AAC-LC to `final/recording.m4a.part` (row 15).
    case beginFinalize
    /// Discard a failed finalize `.part`; keep raw segments (rows 17, 18).
    case discardFinalPart
    /// Atomically rename `.m4a.part` -> `.m4a` after verification (row 16).
    case promoteFinalRecording
    /// Unlink the raw `segments/` after the `complete` manifest is durable (row 16).
    case deleteRawSegments
    /// Best-effort fsync of the live segment on termination (row 20).
    case fsyncLiveSegment
    /// Persist the manifest (see `ManifestUpdate`).
    case writeManifest(ManifestUpdate)
}
