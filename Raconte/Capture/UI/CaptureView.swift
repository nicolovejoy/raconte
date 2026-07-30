import SwiftUI

/// One playable capture on disk, for the "recent recordings" list (design §5 playback).
struct FinishedRecording: Identifiable, Equatable, Sendable {
    let captureID: String
    let durationSeconds: Double
    var id: String { captureID }
    var formattedDuration: String { CaptureCoordinator.formatDuration(durationSeconds) }
}

/// Composition + orchestration for the capture screen. Owns the (per-capture, ephemeral)
/// `CaptureCoordinator`, the launch-recovery banner list, the background finalizer, and
/// the recent-recordings list. Kept out of the pure-tested layer on purpose: the testable
/// mapping lives in `RecordControlModel` / `RecFormat`; this type is the imperative glue.
///
/// Why a fresh coordinator per capture: the machine has no `captured → idle` edge (a
/// coordinator instance is single-capture by design), so once a recording commits we spawn
/// a new idle coordinator for the next one, preserving the launch banners in view state.
@MainActor
@Observable
final class CaptureScreenModel {
    private(set) var coordinator: CaptureCoordinator
    private(set) var recovered: [RecoveredRecording] = []
    private(set) var finished: [FinishedRecording] = []
    private var dismissed: Set<String> = []
    private var didBootstrap = false
    private var finishing = false

    let capturesRoot: URL
    private let spawn: @MainActor () -> CaptureCoordinator
    private let finalizer: FinalizerWorker

    /// Launch-recovered captures the user hasn't dismissed (via Keep/Delete) yet.
    var visibleRecovered: [RecoveredRecording] {
        recovered.filter { !dismissed.contains($0.captureID) }
    }

    init(capturesRoot: URL,
         makeSession: @escaping () -> AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         encoder: AudioEncoder) {
        self.capturesRoot = capturesRoot
        self.finalizer = FinalizerWorker(capturesRoot: capturesRoot, encoder: encoder)
        let spawn: @MainActor () -> CaptureCoordinator = {
            CaptureCoordinator(
                capturesRoot: capturesRoot,
                session: makeSession(),
                makeRecorder: makeRecorder,
                makeStore: { id, fmt in
                    SegmentStore(capturesRoot: capturesRoot, captureID: id, format: fmt)
                })
        }
        self.spawn = spawn
        self.coordinator = spawn()
    }

    /// Live composition root: platform session controller, real engine recorder, and the
    /// AVAssetWriter encoder, over Application Support.
    static func live() -> CaptureScreenModel {
        CaptureScreenModel(
            capturesRoot: Self.defaultCapturesRoot(),
            makeSession: {
                #if os(iOS)
                IOSAudioSessionController()
                #else
                MacAudioSessionController()
                #endif
            },
            makeRecorder: { AudioEngineRecorder() },
            encoder: AVAssetWriterAudioEncoder())
    }

    static func defaultCapturesRoot() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Raconte/captures", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: intents

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await coordinator.recoverAtLaunch()
        recovered = coordinator.recoveredRecordings
        await runFinalizer(coordinator.finalizeQueue)
        refreshFinished()
    }

    func record() async { await coordinator.record() }
    func done() async { await coordinator.done() }
    func resume() async { await coordinator.resume() }

    /// Called on every phase change; when a capture commits (`captured`/`complete`) it
    /// finalizes, refreshes the list, and resets to a fresh idle coordinator.
    func handle(phase: CaptureState) {
        guard phase == .captured || phase == .complete else { return }
        Task { await finishCurrentCapture() }
    }

    func keep(_ id: String) { dismissed.insert(id) }

    func delete(_ id: String) {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
        try? FileManager.default.removeItem(at: dir)
        dismissed.insert(id)
        refreshFinished()
    }

    // MARK: internals

    private func finishCurrentCapture() async {
        guard !finishing else { return }
        finishing = true
        await runFinalizer(coordinator.finalizeQueue)
        refreshFinished()
        coordinator = spawn()
        finishing = false
    }

    private func runFinalizer(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await finalizer.enqueue(contentsOf: ids)
        _ = await finalizer.drain()
    }

    private func refreshFinished() {
        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        finished = snapshot.captures.compactMap { cap -> FinishedRecording? in
            if case .none = PlayableSourceSelector.select(cap) { return nil }
            let seconds: Double
            if cap.finalM4APresent, let frames = cap.manifest?.final.durationFrames, frames > 0 {
                seconds = Double(frames) / Double(max(1, cap.format.sampleRate))
            } else {
                seconds = PlayableSourceSelector.rawDurationSeconds(cap)
            }
            return FinishedRecording(captureID: cap.captureID, durationSeconds: seconds)
        }
        .sorted { $0.captureID > $1.captureID }   // ULID descending == newest first
    }
}

/// The Milestone 1 capture screen: recovery banners, elapsed timer + status, mic meter,
/// the one big round record button, and a recent-recordings list. Dark-first, minimal
/// chrome (design language: quiet personal journal; polish is Milestone 5).
struct CaptureView: View {
    let model: CaptureScreenModel
    #if DEBUG
    @State private var showDebugMenu = false
    #endif

    private var control: RecordControlModel {
        RecordControlModel.make(phase: model.coordinator.phase,
                                canResume: model.coordinator.canResume)
    }

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    // DEBUG-HARNESS-MOUNT — transition-pause menu (T11) for the kill-at-every-transition sweep.
                    #if DEBUG
                    HStack {
                        Spacer()
                        Button("Debug") { showDebugMenu = true }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .sheet(isPresented: $showDebugMenu) {
                        // Reset the capture screen's inherited .white foreground —
                        // it renders invisible on the system sheet background.
                        NavigationStack { DebugMenuView() }
                            .foregroundStyle(Color.primary)
                    }
                    #endif

                    ForEach(model.visibleRecovered) { rec in
                        RecoveryBanner(recording: rec,
                                       capturesRoot: model.capturesRoot,
                                       onKeep: { model.keep(rec.captureID) },
                                       onDelete: { model.delete(rec.captureID) })
                    }

                    Spacer(minLength: 12)

                    RecStatusLine(phase: model.coordinator.phase,
                                  canResume: model.coordinator.canResume,
                                  elapsed: model.coordinator.elapsed)

                    MicMeter(level: model.coordinator.micLevel,
                             isLive: model.coordinator.phase == .recording)

                    RecordButton(model: control, action: primaryAction)

                    if control.showsDoneButton {
                        Button("Done") { Task { await model.done() } }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }

                    if let error = model.coordinator.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    finishedSection

                    Spacer(minLength: 24)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .task { await model.bootstrap() }
        .onChange(of: model.coordinator.phase) { _, phase in
            model.handle(phase: phase)
        }
    }

    @ViewBuilder
    private var finishedSection: some View {
        if !model.finished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recordings")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.7))
                ForEach(model.finished) { item in
                    FinishedRow(recording: item, capturesRoot: model.capturesRoot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func primaryAction() {
        switch control.action {
        case .record: Task { await model.record() }
        case .done: Task { await model.done() }
        case .resume: Task { await model.resume() }
        case .none: break
        }
    }
}

/// One row in the recent-recordings list: duration + a play/pause toggle backed by a
/// lazily-built `CapturePlayback` (finalized `.m4a` or raw-segment fallback, design §5).
struct FinishedRow: View {
    let recording: FinishedRecording
    let capturesRoot: URL

    @State private var playback: CapturePlayback?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(white: 0.9))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.formattedDuration)
                    .font(.body.monospacedDigit())
                Text(recording.captureID.prefix(10))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color(white: 0.45))
                if let playback {
                    PlaybackProgressLine(playback: playback)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isPlaying: Bool { playback?.isPlaying ?? false }

    private func toggle() {
        let p = playback ?? CapturePlayback(capturesRoot: capturesRoot, captureID: recording.captureID)
        playback = p
        if p.isPlaying { p.pause() } else { p.play() }
    }
}
