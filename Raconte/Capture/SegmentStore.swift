import Foundation
import AVFoundation
import CryptoKit

/// Serial single-writer for a capture's on-disk state (design §1/§2). All disk
/// mutations funnel through this actor, so `stateSeq` is a true total order and
/// disk I/O stays off the caller's (tap) thread. Builds on the pure `SegmentLayout`
/// (T1) for paths/naming and `AtomicFile` for durable manifest/sidecar writes.
///
/// Segments are raw interleaved-free `Float32` PCM appended to `NNNNNN.pcm.part`;
/// on rotation the `.part` is fsync'd + renamed to `NNNNNN.pcm` and its sidecar
/// `NNNNNN.json` written (§1). The manifest is the capture-level journal, written
/// atomically (write-ahead) on every transition.
///
/// Conforms to `PCMSink`: the tap thread calls `receive(_:)` (non-blocking); a
/// `consume()` loop drains chunks serially into `append(_:)`. Tests drive
/// `append(_:)` directly for determinism.
actor SegmentStore: PCMSink {
    /// Rotation thresholds (§1): close the live segment and open the next when
    /// EITHER duration ≥ 20s OR bytes ≥ ~8 MB, whichever comes first.
    static let rotationDurationSeconds: Double = 20
    static let rotationByteCap: Int = 8 * 1024 * 1024

    struct Config: Sendable {
        var rotationDurationSeconds: Double
        var rotationByteCap: Int
        init(rotationDurationSeconds: Double = SegmentStore.rotationDurationSeconds,
             rotationByteCap: Int = SegmentStore.rotationByteCap) {
            self.rotationDurationSeconds = rotationDurationSeconds
            self.rotationByteCap = rotationByteCap
        }
    }

    /// Injected time so sidecar/manifest timestamps are deterministic in tests.
    struct Clock: Sendable {
        var now: @Sendable () -> Date
        var hostTimeSeconds: @Sendable () -> Double
        static let live = Clock(now: { Date() },
                                hostTimeSeconds: { ProcessInfo.processInfo.systemUptime })
    }

    enum SegmentStoreError: Error, Equatable {
        case posix(operation: String, code: Int32)
        case notRecording
    }

    // Identity/layout — immutable Sendable lets, readable without awaiting.
    nonisolated let captureID: String
    nonisolated let capturesRoot: URL
    nonisolated let captureDirectory: URL
    nonisolated let segmentsDirectory: URL

    private let bytesPerFrame: Int
    private let sampleRate: Double
    private let segmentFormat: AudioFormatDescriptor   // carries bytesPerFrame
    private let manifestFormat: AudioFormatDescriptor  // bytesPerFrame omitted (§1)
    private let config: Config
    private let clock: Clock

    // Live-tail file descriptor, boxed so it closes on dealloc even after a "kill".
    private let fd = FileDescriptorBox()

    // PCMSink bridge: non-blocking enqueue on the tap thread, serial drain here.
    private let chunkStream: AsyncStream<PCMChunk>
    nonisolated private let chunkContinuation: AsyncStream<PCMChunk>.Continuation

    private var manifest: Manifest
    private var segmentCount = 0
    private var cumulativeFrameOffset = 0
    private var currentIndex = 0
    private var currentFrameCount = 0
    private var currentByteCount = 0
    private var currentHasher = SHA256()
    private var currentWallClock = Date()
    private var currentHostTime: Double = 0

    init(capturesRoot: URL, captureID: String, format: AudioFormatDescriptor,
         config: Config = .init(), clock: Clock = .live) {
        self.capturesRoot = capturesRoot
        self.captureID = captureID
        self.captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                               captureID: captureID)
        self.segmentsDirectory = SegmentLayout.segmentsDirectory(captureDirectory: captureDirectory)
        let bpf = format.bytesPerFrame
            ?? SegmentStore.bytesPerFrame(commonFormat: format.commonFormat, channels: format.channels)
        self.bytesPerFrame = bpf
        self.sampleRate = Double(format.sampleRate)
        self.segmentFormat = AudioFormatDescriptor(
            sampleRate: format.sampleRate, channels: format.channels,
            commonFormat: format.commonFormat, interleaved: format.interleaved, bytesPerFrame: bpf)
        self.manifestFormat = AudioFormatDescriptor(
            sampleRate: format.sampleRate, channels: format.channels,
            commonFormat: format.commonFormat, interleaved: format.interleaved, bytesPerFrame: nil)
        self.config = config
        self.clock = clock
        let (stream, continuation) = AsyncStream<PCMChunk>.makeStream()
        self.chunkStream = stream
        self.chunkContinuation = continuation
        self.manifest = Manifest(captureID: captureID, createdAt: clock.now(), state: .idle,
                                 stateSeq: 0, stateUpdatedAt: clock.now(), format: manifestFormat)
    }

    deinit { chunkContinuation.finish() }

    // MARK: Lifecycle

    /// Create the capture directory tree, write the initial `recording` manifest
    /// (write-ahead, §2), then open segment 0's `.part`.
    func begin() throws {
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        manifest = Manifest(captureID: captureID, createdAt: clock.now(), state: .recording,
                            stateSeq: 0, stateUpdatedAt: clock.now(), format: manifestFormat)
        try persistManifest()          // stateSeq -> 1, before any segment holds data
        try openCurrentSegmentFile()
    }

    /// Append one canonical PCM chunk to the live segment, rotating if a threshold
    /// is crossed. Called serially (by `consume()` or directly by tests).
    func append(_ chunk: PCMChunk) throws {
        guard fd.value >= 0 else { throw SegmentStoreError.notRecording }
        try Self.writeAll(fd: fd.value, data: chunk.data)
        currentByteCount += chunk.data.count
        currentFrameCount += Int(chunk.frameCount)
        if !chunk.data.isEmpty { currentHasher.update(data: chunk.data) }
        if shouldRotate() { try rotate() }
    }

    /// User tapped Done (or interruption-then-Done): close the final segment and
    /// commit `captured` — the durability commit point (§2).
    func finish(reason: SegmentClosedReason = .stop) throws {
        try closeCurrentSegment(reason: reason)
        manifest.state = .captured
        manifest.segmentCount = segmentCount
        manifest.lastKnownFrameOffset = cumulativeFrameOffset
        try persistManifest()
    }

    /// System yanked audio (§2 rows 5–7): close the live segment as `interruption`,
    /// append an interruption-log entry, persist `interrupted`.
    func markInterrupted(kind: String, beganAt: Date) throws {
        try closeCurrentSegment(reason: .interruption)
        manifest.state = .interrupted
        manifest.interruptions.append(
            InterruptionLogEntry(kind: kind, beganAt: beganAt, endedAt: nil, resumed: nil))
        manifest.segmentCount = segmentCount
        manifest.lastKnownFrameOffset = cumulativeFrameOffset
        try persistManifest()
    }

    /// Reacquired the engine after an interruption (§2 row 9): persist `recording`
    /// (write-ahead) then open the next segment. Closes the open interruption entry
    /// (issue #9) in the SAME write as the state flip, so a kill right after resume
    /// can't land `recording` on disk with the entry still open.
    func resumeRecording() throws {
        closeMostRecentOpenInterruption(resumed: true)
        manifest.state = .recording
        try persistManifest()
        try openCurrentSegmentFile()
    }

    /// Generic state transition + operational-field update, atomically persisted
    /// (§2 rows 8/12/15/16/17/18/19). Only non-nil operational fields are changed.
    /// `closingInterruption`, when non-nil, closes the most recent open interruption
    /// entry (issue #9) with that `resumed` value in the same write — used for the two
    /// `-> captured` paths that leave an interruption while it's still open: the user
    /// stopping from `interrupted` (row 14) and reacquire giving up its retry budget
    /// (row 11). Never pass it for `.interrupted`/`.resuming`, which must leave the
    /// entry open.
    func setState(_ state: CaptureState,
                  needsAttention: Bool? = nil, lastError: String? = nil,
                  retryCount: Int? = nil, finalizeAttempts: Int? = nil,
                  closingInterruption resumed: Bool? = nil) throws {
        if let resumed { closeMostRecentOpenInterruption(resumed: resumed) }
        manifest.state = state
        if let needsAttention { manifest.needsAttention = needsAttention }
        if let lastError { manifest.lastError = lastError }
        if let retryCount { manifest.retryCount = retryCount }
        if let finalizeAttempts { manifest.finalizeAttempts = finalizeAttempts }
        try persistManifest()
    }

    // MARK: PCMSink

    nonisolated func receive(_ chunk: PCMChunk) {
        chunkContinuation.yield(chunk)
    }

    /// Drain the tap-fed chunk stream serially. Runs until the stream finishes
    /// (deinit) or a write error trips the disk-full path (§2 row 19).
    func consume() async {
        for await chunk in chunkStream {
            do { try append(chunk) }
            catch { try? failWithStorageError(); break }
        }
    }

    // MARK: Read accessors (recovery / finalize)

    func currentManifest() -> Manifest { manifest }
    func finalizedSegmentCount() -> Int { segmentCount }
    /// Frames durably closed plus the live segment's whole frames.
    func totalFrameCount() -> Int {
        cumulativeFrameOffset + (fd.value >= 0 ? currentFrameCount : 0)
    }

    // MARK: Internals

    private func openCurrentSegmentFile() throws {
        // Index == count of finalized segments keeps numbering gap-free even when
        // an empty segment was discarded (its index is reused).
        currentIndex = segmentCount
        let url = SegmentLayout.pcmPartURL(segmentsDirectory: segmentsDirectory, index: currentIndex)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw SegmentStoreError.posix(operation: "open", code: errno) }
        fd.value = descriptor
        currentFrameCount = 0
        currentByteCount = 0
        currentHasher = SHA256()
        currentWallClock = clock.now()
        currentHostTime = clock.hostTimeSeconds()
    }

    private func shouldRotate() -> Bool {
        let duration = sampleRate > 0 ? Double(currentFrameCount) / sampleRate : 0
        return duration >= config.rotationDurationSeconds || currentByteCount >= config.rotationByteCap
    }

    private func rotate() throws {
        try closeCurrentSegment(reason: .rotation)
        try openCurrentSegmentFile()
    }

    /// fsync + close the live `.part`; if it holds ≥1 frame, atomically promote it
    /// to `NNNNNN.pcm`, write its sidecar (§1 order: after rename), and bump the
    /// manifest. An empty segment is discarded (recovery ignores empty segments).
    private func closeCurrentSegment(reason: SegmentClosedReason) throws {
        guard fd.value >= 0 else { return }
        let index = currentIndex
        let frames = currentFrameCount
        let bytes = currentByteCount
        if fsync(fd.value) != 0 { throw SegmentStoreError.posix(operation: "fsync", code: errno) }
        fd.closeIfOpen()

        let partURL = SegmentLayout.pcmPartURL(segmentsDirectory: segmentsDirectory, index: index)
        if frames == 0 {
            try? FileManager.default.removeItem(at: partURL)
            return
        }

        let pcmURL = SegmentLayout.pcmURL(segmentsDirectory: segmentsDirectory, index: index)
        guard rename(partURL.path, pcmURL.path) == 0 else {
            throw SegmentStoreError.posix(operation: "rename", code: errno)
        }
        try fsyncDirectory(segmentsDirectory.path)

        let sidecar = SegmentSidecar(
            captureID: captureID, index: index, format: segmentFormat,
            frameCount: frames, startFrameOffset: cumulativeFrameOffset,
            startHostTime: currentHostTime, wallClockStart: currentWallClock,
            sha256Prefix: Self.hexPrefix(currentHasher.finalize()),
            closedReason: reason, byteCount: bytes)
        let data = try CaptureCoding.encoder().encode(sidecar)
        try AtomicFile.replace(
            at: SegmentLayout.sidecarURL(segmentsDirectory: segmentsDirectory, index: index),
            writing: data)

        cumulativeFrameOffset += frames
        segmentCount += 1
        manifest.segmentCount = segmentCount
        manifest.lastKnownFrameOffset = cumulativeFrameOffset
        try persistManifest()
    }

    /// Closes the most recent open interruption entry (`endedAt == nil`), stamping
    /// `endedAt`/`resumed`. A well-formed log never has more than one open entry, but
    /// if a crash between `markInterrupted` and its close somehow left an earlier one
    /// open too, that entry is left alone — it's evidence, not clutter. No-op if none
    /// open. Caller persists the manifest.
    private func closeMostRecentOpenInterruption(resumed: Bool) {
        guard let index = manifest.interruptions.lastIndex(where: { $0.endedAt == nil }) else { return }
        manifest.interruptions[index].endedAt = clock.now()
        manifest.interruptions[index].resumed = resumed
    }

    private func persistManifest() throws {
        manifest.stateSeq += 1
        manifest.stateUpdatedAt = clock.now()
        let data = try CaptureCoding.encoder().encode(manifest)
        try AtomicFile.replace(
            at: SegmentLayout.manifestURL(captureDirectory: captureDirectory), writing: data)
    }

    private func failWithStorageError() throws {
        try? closeCurrentSegment(reason: .appTermination)
        manifest.state = .interrupted
        manifest.lastError = "diskFull"
        manifest.segmentCount = segmentCount
        manifest.lastKnownFrameOffset = cumulativeFrameOffset
        try persistManifest()
    }

    // MARK: Pure helpers

    static func bytesPerFrame(commonFormat: PCMCommonFormat, channels: Int) -> Int {
        let sampleBytes: Int
        switch commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32: sampleBytes = 4
        case .pcmFormatFloat64: sampleBytes = 8
        case .pcmFormatInt16: sampleBytes = 2
        case .otherFormat: sampleBytes = 4
        }
        return sampleBytes * max(channels, 1)
    }

    private static func hexPrefix(_ digest: SHA256.Digest) -> String {
        // First 4 bytes -> 8 hex chars (§1 sha256Prefix).
        digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 { throw SegmentStoreError.posix(operation: "write", code: errno) }
                offset += n
            }
        }
    }

    private func fsyncDirectory(_ path: String) throws {
        let dfd = open(path, O_RDONLY)
        guard dfd >= 0 else { throw SegmentStoreError.posix(operation: "open(dir)", code: errno) }
        defer { close(dfd) }
        if fsync(dfd) != 0 { throw SegmentStoreError.posix(operation: "fsync(dir)", code: errno) }
    }
}

/// Boxes the live segment's fd so it is closed on dealloc — a dropped store (the
/// "kill" case) leaves the `.part` on disk with its bytes intact but unrenamed,
/// never leaking the descriptor.
private final class FileDescriptorBox {
    var value: Int32 = -1
    func closeIfOpen() { if value >= 0 { close(value); value = -1 } }
    deinit { closeIfOpen() }
}
