#if DEBUG
import Foundation

/// UI-test composition root. Active only when `RACONTE_UITEST_ID` is in the launch
/// environment (set by RaconteUITests): synthetic engine + no-op session over an
/// id-keyed captures root, so UI flows run with no microphone, no TCC prompt, and
/// per-test isolation. A relaunch with the same id sees the same disk — the
/// recovery-flow tests rely on that.
/// Where the harness's id-keyed tree lives, factored out so `LibraryScreenModel` (M3 T4)
/// points at the same one `CaptureScreenModel`'s harness uses — two roots for one
/// `RACONTE_UITEST_ID` would make the library scan an empty directory next to the one the
/// capture screen is actually writing.
///
/// The id keys a **container** root with `captures/` beneath it, the same layout
/// `AppContainer` defines. The harness used to key the captures root itself and then pin
/// `journals.json` *inside* it, which contradicted `AppContainer`'s "never inside
/// captures/" rule and left the harness testing a shape no shipping build has. With the
/// container keyed instead, `AppContainer.containerRoot(capturesRoot:)` derives the right
/// place on its own and nothing needs pinning.
enum UITestHarnessRoot {
    @MainActor static func containerRoot(id: String) -> URL {
        CaptureScreenModel.defaultCapturesRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("uitest-\(id)", isDirectory: true)
    }

    @MainActor static func capturesRoot(id: String) -> URL {
        let root = AppContainer.capturesRoot(containerRoot: containerRoot(id: id))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension CaptureScreenModel {
    /// `library` is threaded through (M3 T4.5) rather than dropped: `ContentView`'s
    /// `navigationDestination(for: LibraryDestination.self)` reads its OWN
    /// `LibraryScreenModel.item(_:)`, which only ever sees rows that instance itself
    /// scanned — if the harness quietly built a second, disconnected `LibraryScreenModel`
    /// here, a tap on a capture-screen recent row would push a detail screen for an id
    /// the caller's library never scanned, and render nothing.
    @MainActor static func uiTestHarness(library: LibraryScreenModel) -> CaptureScreenModel? {
        guard let id = ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"] else { return nil }
        let root = UITestHarnessRoot.capturesRoot(id: id)
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: { UITestSessionController() },
            makeRecorder: { SyntheticRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            // A second branch on every capture, so the simulator suite drives
            // record→finalize→relaunch over a two-branch tee rather than the
            // one-branch shape no shipping build will use.
            makeSecondarySink: { _ in NoOpPCMSink() },
            // No `journalsContainerRoot` override: the id keys the container, so the
            // production derivation lands `journals.json` beside `captures/` — isolated
            // per test id and the same layout the shipping app has.
            library: library)
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
