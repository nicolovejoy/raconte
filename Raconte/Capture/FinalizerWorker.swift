import Foundation

/// Result of finalizing one capture (design §5, transition rows 15–18).
enum FinalizeStatus: Sendable, Equatable {
    /// Verified `.m4a`; raw segments deleted (row 16 → `complete`).
    case completed
    /// Encode/verify failed with retry budget left; `.part` discarded, raw kept,
    /// `finalizeAttempts++` (row 17). The next launch's recovery re-enqueues it.
    case requeued
    /// Kept raw forever + flagged `needsAttention` (row 18 budget-exhausted, or a
    /// `startFrameOffset` gap that makes the `.m4a` an incomplete prefix).
    case needsAttention
    /// Nothing contiguous/usable to encode; capture left as-is.
    case skipped
}

struct FinalizeOutcome: Sendable, Equatable {
    var captureID: String
    var status: FinalizeStatus
    /// Frames the encoder was fed (the contiguous prefix total).
    var encodedFrameCount: Int
    var finalizeAttempts: Int
    /// True when a `startFrameOffset` chain gap truncated the encode to a prefix.
    var hadGap: Bool
}

/// Drains a queue of `captured` captures, one at a time, encoding each to a
/// verified AAC-LC `.m4a` (design §5). Resumable across launches: all progress
/// lives in the manifest, so a killed finalize is just re-enqueued by recovery.
///
/// Queue surface (minimal, per the coordinator hand-off): the input is a plain
/// capture-ID `String`. `enqueue(_:)` accepts what `RecoveryOutcome.finalizeQueue`
/// already produces; `drain()` processes the queue FIFO and returns per-capture
/// outcomes. The worker resolves each ID to `capturesRoot/<id>/` itself — the
/// coordinator never passes URLs or model objects across the actor boundary.
actor FinalizerWorker {
    struct Config: Sendable {
        /// Max encode/verify attempts before giving up and flagging needsAttention (row 18).
        var maxFinalizeAttempts: Int
        /// Decoded-vs-raw duration tolerance in seconds (VERIFY §5: AAC priming/padding
        /// makes it inexact; 0.5 s comfortably covers encoder delay + a padded last packet).
        var verifyToleranceSeconds: Double
        init(maxFinalizeAttempts: Int = 3, verifyToleranceSeconds: Double = 0.5) {
            self.maxFinalizeAttempts = maxFinalizeAttempts
            self.verifyToleranceSeconds = verifyToleranceSeconds
        }
    }

    nonisolated let capturesRoot: URL
    private let encoder: AudioEncoder
    private let config: Config
    private let now: @Sendable () -> Date

    private var queue: [String] = []

    init(capturesRoot: URL, encoder: AudioEncoder,
         config: Config = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.capturesRoot = capturesRoot
        self.encoder = encoder
        self.config = config
        self.now = now
    }

    /// Add a capture ID to the finalize queue (dedup: no double-enqueue).
    func enqueue(_ captureID: String) {
        if !queue.contains(captureID) { queue.append(captureID) }
    }

    func enqueue(contentsOf ids: [String]) {
        for id in ids { enqueue(id) }
    }

    /// Process the whole queue FIFO; returns one outcome per capture in order.
    /// A `requeued` outcome is NOT re-added within the same drain (that's a
    /// next-launch responsibility) so a persistently-failing encode can't loop.
    @discardableResult
    func drain() async -> [FinalizeOutcome] {
        var outcomes: [FinalizeOutcome] = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            outcomes.append(await finalize(captureID: id))
        }
        return outcomes
    }

    /// Finalize one capture. Reads its finalized segments in index order via
    /// sidecars, feeds the contiguous prefix to the encoder, verifies the output
    /// against summed raw frames, then (only on a clean pass) writes `complete`
    /// and deletes raw. See the §2 transition rows in the branch comments.
    func finalize(captureID: String) async -> FinalizeOutcome {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        guard var manifest = readManifest(dir: dir) else {
            return FinalizeOutcome(captureID: captureID, status: .skipped,
                                   encodedFrameCount: 0, finalizeAttempts: 0, hadGap: false)
        }
        let format = DirectorySnapshot.normalizingBytesPerFrame(manifest.format)
        let all = readSegments(dir: dir, format: format)
        let (prefix, hadGap) = contiguousPrefix(all)

        // Nothing contiguous to encode.
        guard !prefix.isEmpty else {
            // #94: raw segments gone but a promoted `.m4a` exists and was never
            // stamped — the crash-between-promote-and-`.complete` state. Re-deriving
            // from raw is impossible forever, so verify the m4a itself (decode
            // probe) and stamp. Without this, recovery re-plans `.verifyFinal`
            // every launch and this returns `.skipped` every time, leaving the
            // capture permanently push-ineligible while playing fine locally.
            let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: dir)
            if !hadGap, manifest.final.verifiedAt == nil,
               FileManager.default.fileExists(atPath: m4aURL.path) {
                if let verified = try? await encoder.verify(m4aURL: m4aURL),
                   verified.decodable, verified.nonSilent {
                    manifest.final.verifiedAt = now()
                    manifest.final.durationFrames = verified.decodedFrameCount
                    writeManifest(manifest, dir: dir, state: .complete)
                    return FinalizeOutcome(captureID: captureID, status: .completed,
                                           encodedFrameCount: 0,
                                           finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                           hadGap: false)
                }
                // Probe failed with no raw to fall back on: keep every byte,
                // surface it. NOT the failEncode path — that would delete a
                // `.part` and burn retry budget on a state retries cannot change.
                manifest.needsAttention = true
                writeManifest(manifest, dir: dir, state: manifest.state)
                return FinalizeOutcome(captureID: captureID, status: .needsAttention,
                                       encodedFrameCount: 0,
                                       finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                       hadGap: false)
            }
            if hadGap {
                manifest.needsAttention = true
                writeManifest(manifest, dir: dir, state: .captured)
            }
            return FinalizeOutcome(captureID: captureID,
                                   status: hadGap ? .needsAttention : .skipped,
                                   encodedFrameCount: 0,
                                   finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                   hadGap: hadGap)
        }

        let expectedFrames = prefix.reduce(0) { $0 + $1.frameCount }
        let sampleRate = max(1, format.sampleRate)
        let toleranceFrames = config.verifyToleranceSeconds * Double(sampleRate)

        // Row 15: write-ahead `finalizing` before producing the `.m4a.part`.
        writeManifest(manifest, dir: dir, state: .finalizing)

        let partURL = SegmentLayout.finalRecordingPartURL(captureDirectory: dir)
        let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: dir)

        let encoded: EncodeResult
        let verified: VerifyResult
        do {
            encoded = try await encoder.encode(segments: prefix, format: format, to: partURL)
            verified = try await encoder.verify(m4aURL: partURL)
        } catch {
            return failEncode(&manifest, dir: dir, partURL: partURL,
                              captureID: captureID, hadGap: hadGap)
        }

        let durationOK = abs(Double(verified.decodedFrameCount) - Double(expectedFrames)) <= toleranceFrames
        let passed = verified.decodable && verified.nonSilent && durationOK

        guard passed else {
            return failEncode(&manifest, dir: dir, partURL: partURL,
                              captureID: captureID, hadGap: hadGap)
        }

        // Verify passed. Promote `.m4a.part` -> `.m4a` (atomic rename + dir fsync).
        do {
            try promote(partURL: partURL, finalURL: m4aURL, dir: dir)
        } catch {
            return failEncode(&manifest, dir: dir, partURL: partURL,
                              captureID: captureID, hadGap: hadGap)
        }

        manifest.final.verifiedAt = now()
        manifest.final.durationFrames = expectedFrames

        if hadGap {
            // A verified but incomplete prefix: keep raw (ground truth), flag it.
            manifest.needsAttention = true
            writeManifest(manifest, dir: dir, state: .captured)
            return FinalizeOutcome(captureID: captureID, status: .needsAttention,
                                   encodedFrameCount: encoded.encodedFrameCount,
                                   finalizeAttempts: manifest.finalizeAttempts ?? 0, hadGap: true)
        }

        // Row 16: `complete` manifest is durable BEFORE any raw unlink.
        writeManifest(manifest, dir: dir, state: .complete)
        try? FileManager.default.removeItem(at: SegmentLayout.segmentsDirectory(captureDirectory: dir))
        return FinalizeOutcome(captureID: captureID, status: .completed,
                               encodedFrameCount: encoded.encodedFrameCount,
                               finalizeAttempts: manifest.finalizeAttempts ?? 0, hadGap: false)
    }

    // MARK: - failure path (rows 17/18)

    private func failEncode(_ manifest: inout Manifest, dir: URL, partURL: URL,
                            captureID: String, hadGap: Bool) -> FinalizeOutcome {
        try? FileManager.default.removeItem(at: partURL)
        let attempts = (manifest.finalizeAttempts ?? 0) + 1
        manifest.finalizeAttempts = attempts
        let exhausted = attempts >= config.maxFinalizeAttempts
        if exhausted { manifest.needsAttention = true }
        writeManifest(manifest, dir: dir, state: .captured)
        return FinalizeOutcome(captureID: captureID,
                               status: exhausted ? .needsAttention : .requeued,
                               encodedFrameCount: 0, finalizeAttempts: attempts, hadGap: hadGap)
    }

    // MARK: - segment reading

    /// Finalized segments in index order. Prefers sidecar `frameCount`/
    /// `startFrameOffset`; falls back to file size for a missing sidecar.
    private func readSegments(dir: URL, format: AudioFormatDescriptor) -> [EncodableSegment] {
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: segsDir.path) else { return [] }
        let bytesPerFrame = DirectorySnapshot.bytesPerFrame(format)

        var indices: [Int] = []
        for name in names
        where name.hasSuffix(".\(SegmentLayout.pcmExtension)") {
            if let idx = SegmentLayout.segmentIndex(fromFileName: name) { indices.append(idx) }
        }
        indices.sort()

        var segments: [EncodableSegment] = []
        var running = 0
        for idx in indices {
            let pcmURL = SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: idx)
            let sidecar = readSidecar(segsDir: segsDir, index: idx)
            let frameCount: Int
            let startOffset: Int
            if let sidecar {
                frameCount = sidecar.frameCount
                startOffset = sidecar.startFrameOffset
            } else {
                let size = (try? pcmURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                frameCount = SegmentLayout.wholeFrameCount(fileSize: size, bytesPerFrame: bytesPerFrame)
                startOffset = running
            }
            running = startOffset + frameCount
            segments.append(EncodableSegment(index: idx, startFrameOffset: startOffset,
                                             frameCount: frameCount, pcmURL: pcmURL))
        }
        return segments
    }

    /// The leading run whose `startFrameOffset` chain is unbroken (offset[0] == 0,
    /// offset[i] == offset[i-1] + frameCount[i-1]). Returns the prefix and whether
    /// any trailing segment was dropped because of a gap (design §5).
    private func contiguousPrefix(_ segments: [EncodableSegment]) -> (prefix: [EncodableSegment], hadGap: Bool) {
        var prefix: [EncodableSegment] = []
        var running = 0
        for seg in segments {
            guard seg.frameCount > 0, seg.startFrameOffset == running else {
                return (prefix, hadGap: true)
            }
            prefix.append(seg)
            running += seg.frameCount
        }
        return (prefix, hadGap: false)
    }

    // MARK: - manifest / file helpers

    private func readManifest(dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir)) else {
            return nil
        }
        return try? CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    private func readSidecar(segsDir: URL, index: Int) -> SegmentSidecar? {
        let url = SegmentLayout.sidecarURL(segmentsDirectory: segsDir, index: index)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(SegmentSidecar.self, from: data)
    }

    /// Persist `manifest` at the new `state`, bumping the monotonic `stateSeq`
    /// and `stateUpdatedAt`, written atomically (design §2 single-writer journal).
    private func writeManifest(_ manifest: Manifest, dir: URL, state: CaptureState) {
        var m = manifest
        m.state = state
        m.stateSeq += 1
        m.stateUpdatedAt = now()
        manifestSideEffect(&m, dir: dir)
    }

    private func manifestSideEffect(_ m: inout Manifest, dir: URL) {
        if let data = try? CaptureCoding.encoder().encode(m) {
            try? AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir), writing: data)
        }
    }

    /// Atomic `.m4a.part` -> `.m4a` rename + directory fsync (design §5 step 4 /
    /// §1 atomicity), so a kill after the rename leaves a valid finalized file.
    private func promote(partURL: URL, finalURL: URL, dir: URL) throws {
        guard rename(partURL.path, finalURL.path) == 0 else {
            throw AtomicFileError.posix(operation: "rename", code: errno)
        }
        let dirPath = SegmentLayout.finalDirectory(captureDirectory: dir).path
        let dfd = open(dirPath, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }
}
