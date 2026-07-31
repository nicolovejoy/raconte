#if DEBUG
import Foundation

/// UI-test composition root. Active only when `RACONTE_UITEST_ID` is in the launch
/// environment (set by RaconteUITests): synthetic engine + no-op session over an
/// id-keyed captures root, so UI flows run with no microphone, no TCC prompt, and
/// per-test isolation. A relaunch with the same id sees the same disk — the
/// recovery-flow tests rely on that.
extension CaptureScreenModel {
    @MainActor static func uiTestHarness() -> CaptureScreenModel? {
        guard let id = ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"] else { return nil }
        let root = defaultCapturesRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("uitest-captures-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: { UITestSessionController() },
            makeRecorder: { SyntheticRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            // A second branch on every capture, so the simulator suite drives
            // record→finalize→relaunch over a two-branch tee rather than the
            // one-branch shape no shipping build will use.
            makeSecondarySink: { _ in NoOpPCMSink() })
    }
}

/// A tee branch that does nothing. Exists so the tested path has the same shape
/// as the shipping path.
final class NoOpPCMSink: PCMSink {
    nonisolated func receive(_ chunk: PCMChunk) {}
}

/// Grants permission and activates unconditionally; never emits a session event.
final class UITestSessionController: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    init() { (events, continuation) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

/// Engine stand-in generating a continuous 440 Hz sine (canonical mono Float32) in
/// 100 ms chunks, so capture/finalize/playback run end-to-end with real bytes and a
/// non-silent verify — no audio hardware involved.
final class SyntheticRecorder: EngineRecording, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var captureFormatDescriptor: AudioFormatDescriptor?
    private var task: Task<Void, Never>?

    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws {
        guard !isRunning else { return }
        let rate = canonical?.sampleRate ?? 48_000
        captureFormatDescriptor = AudioFormatDescriptor(
            sampleRate: rate, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)
        isRunning = true
        task = Task.detached {
            let chunkFrames = rate / 10
            var frame = 0
            while !Task.isCancelled {
                var samples = [Float](repeating: 0, count: chunkFrames)
                for i in 0..<chunkFrames {
                    samples[i] = Float(sin(2 * Double.pi * 440 * Double(frame + i) / Double(rate)) * 0.5)
                }
                frame += chunkFrames
                let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                sink.receive(PCMChunk(data: data, frameCount: .init(chunkFrames),
                                      sampleRate: Double(rate)))
                onLevel?(0.35)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
#endif
