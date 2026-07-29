import Foundation

/// What the executor did, categorized for the caller (banner + finalizer queue).
/// Deterministic from the action list alone, so applying the same actions twice
/// yields an equal outcome (design §3 idempotency).
struct RecoveryOutcome: Equatable {
    /// Captures rescued this launch → show a "Recovered recording: MM:SS" banner.
    var recoveredCaptureIDs: [String] = []
    /// Captures handed to the finalizer to encode/verify.
    var finalizeQueue: [String] = []
    /// Captures whose `.m4a` must be verified (decode) before raw delete.
    var verifyQueue: [String] = []
    /// Capture directories removed (silent).
    var deletedCaptureIDs: [String] = []
}

/// Applies `RecoveryPlanner` actions to the real filesystem, idempotently
/// (design §3 executor). Every op tolerates already-applied state: renamed
/// `.part`s, deleted directories, and already-`captured` manifests are no-ops.
struct RecoveryExecutor {
    let capturesRoot: URL
    /// Injected clock for regenerated sidecar/manifest timestamps (testability).
    var now: () -> Date = Date.init

    init(capturesRoot: URL, now: @escaping () -> Date = Date.init) {
        self.capturesRoot = capturesRoot
        self.now = now
    }

    @discardableResult
    func apply(_ actions: [RecoveryAction]) -> RecoveryOutcome {
        var outcome = RecoveryOutcome()
        for action in actions { apply(action, into: &outcome) }
        return outcome
    }

    private func apply(_ action: RecoveryAction, into outcome: inout RecoveryOutcome) {
        switch action {
        case .deleteCaptureDirectory(let id):
            try? FileManager.default.removeItem(at: captureDir(id))
            outcome.deletedCaptureIDs.append(id)

        case .normalizeToCaptured(let recovered):
            normalize(recovered)
            outcome.recoveredCaptureIDs.append(recovered.captureID)
            outcome.finalizeQueue.append(recovered.captureID)

        case .enqueueFinalize(let id):
            outcome.finalizeQueue.append(id)

        case .discardFinalPartRequeue(let id):
            let dir = captureDir(id)
            try? FileManager.default.removeItem(at: SegmentLayout.finalRecordingPartURL(captureDirectory: dir))
            setStateCapturedIfNeeded(dir: dir, captureID: id)
            outcome.finalizeQueue.append(id)

        case .verifyFinal(let id):
            outcome.verifyQueue.append(id)

        case .finishRawDelete(let id):
            try? FileManager.default.removeItem(
                at: SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id)))
        }
    }

    // MARK: - normalizeToCaptured

    private func normalize(_ recovered: RecoveredCapture) {
        let dir = captureDir(recovered.captureID)
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        let format = DirectorySnapshot.normalizingBytesPerFrame(recovered.format)

        for seg in recovered.segments {
            let pcmURL = SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: seg.index)
            let partURL = SegmentLayout.pcmPartURL(segmentsDirectory: segsDir, index: seg.index)

            // Truncate + rename the live tail (skip if already renamed).
            if seg.needsPartNormalization,
               !FileManager.default.fileExists(atPath: pcmURL.path),
               FileManager.default.fileExists(atPath: partURL.path) {
                try? truncateRenameSync(partPath: partURL.path, pcmPath: pcmURL.path,
                                        byteCount: seg.byteCount, dirPath: segsDir.path)
            }

            // Regenerate a missing sidecar (skip if present).
            let sidecarURL = SegmentLayout.sidecarURL(segmentsDirectory: segsDir, index: seg.index)
            if !FileManager.default.fileExists(atPath: sidecarURL.path) {
                let sidecar = SegmentSidecar(
                    captureID: recovered.captureID, index: seg.index, format: format,
                    frameCount: seg.frameCount, startFrameOffset: seg.startFrameOffset,
                    startHostTime: 0, wallClockStart: now(),
                    sha256Prefix: "", closedReason: .appTermination, byteCount: seg.byteCount)
                if let data = try? CaptureCoding.encoder().encode(sidecar) {
                    try? AtomicFile.replace(at: sidecarURL, writing: data)
                }
            }
        }

        // Stray manifest.json.part cleanup (§1: recovery deletes it).
        try? FileManager.default.removeItem(at: SegmentLayout.manifestPartURL(captureDirectory: dir))

        writeCapturedManifest(dir: dir, recovered: recovered, format: format)
    }

    private func writeCapturedManifest(dir: URL, recovered: RecoveredCapture,
                                       format: AudioFormatDescriptor) {
        let existing = readManifest(dir: dir)
        // Idempotent: don't rewrite if already captured with the same content.
        if let m = existing, m.state == .captured,
           m.segmentCount == recovered.segments.count,
           m.lastKnownFrameOffset == recovered.totalFrames {
            return
        }
        let manifestFormat = AudioFormatDescriptor(
            sampleRate: format.sampleRate, channels: format.channels,
            commonFormat: format.commonFormat, interleaved: format.interleaved)
        let manifest = Manifest(
            captureID: recovered.captureID,
            createdAt: existing?.createdAt ?? now(),
            state: .captured,
            stateSeq: (existing?.stateSeq ?? -1) + 1,
            stateUpdatedAt: now(),
            format: manifestFormat,
            segmentCount: recovered.segments.count,
            lastKnownFrameOffset: recovered.totalFrames,
            interruptions: existing?.interruptions ?? [],
            final: existing?.final ?? FinalRef())
        if let data = try? CaptureCoding.encoder().encode(manifest) {
            try? AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir), writing: data)
        }
    }

    private func setStateCapturedIfNeeded(dir: URL, captureID: String) {
        guard let existing = readManifest(dir: dir) else { return }
        if existing.state == .captured { return }
        var m = existing
        m.state = .captured
        m.stateSeq = existing.stateSeq + 1
        m.stateUpdatedAt = now()
        if let data = try? CaptureCoding.encoder().encode(m) {
            try? AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir), writing: data)
        }
    }

    // MARK: - helpers

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func readManifest(dir: URL) -> Manifest? {
        let url = SegmentLayout.manifestURL(captureDirectory: dir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    /// Truncate a `.pcm.part` to whole frames, fsync, rename to `.pcm`, then
    /// fsync the directory so the rename is durable (design §1/§3 normalization).
    private func truncateRenameSync(partPath: String, pcmPath: String,
                                    byteCount: Int, dirPath: String) throws {
        let fd = open(partPath, O_WRONLY)
        guard fd >= 0 else { throw AtomicFileError.posix(operation: "open", code: errno) }
        do {
            guard ftruncate(fd, off_t(byteCount)) == 0 else {
                throw AtomicFileError.posix(operation: "ftruncate", code: errno)
            }
            guard fsync(fd) == 0 else { throw AtomicFileError.posix(operation: "fsync", code: errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw AtomicFileError.posix(operation: "close", code: errno) }
        guard rename(partPath, pcmPath) == 0 else {
            throw AtomicFileError.posix(operation: "rename", code: errno)
        }
        let dfd = open(dirPath, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }
}
