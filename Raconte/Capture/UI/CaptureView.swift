import SwiftUI

/// One playable capture on disk, for the "recent recordings" list (design §5 playback).
struct FinishedRecording: Identifiable, Equatable, Sendable {
    let captureID: String
    let durationSeconds: Double
    let createdAt: Date
    var id: String { captureID }
    var formattedDuration: String { CaptureCoordinator.formatDuration(durationSeconds) }

    /// "Today 3:42 PM" / "Jul 28, 3:42 PM" — the date is only worth the width once the
    /// recording isn't from today.
    var formattedCreatedAt: String {
        let cal = Calendar.current
        let time = createdAt.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(createdAt) { return "Today \(time)" }
        if cal.isDateInYesterday(createdAt) { return "Yesterday \(time)" }
        return "\(createdAt.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// A ULID's first 10 Crockford-base32 chars are a 48-bit millisecond timestamp, so a
    /// capture whose manifest is missing or corrupt still shows the right date.
    static func timestamp(fromULID id: String) -> Date? {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let head = id.uppercased().prefix(10)
        guard head.count == 10 else { return nil }
        var ms: UInt64 = 0
        for ch in head {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            ms = (ms << 5) | UInt64(v)
        }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
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

    /// Live transcription, or nil when the build has none wired (the UI-test harness).
    let transcription: LiveTranscriptionCoordinator?

    /// Launch-recovered captures the user hasn't dismissed (via Keep/Delete) yet.
    var visibleRecovered: [RecoveredRecording] {
        recovered.filter { !dismissed.contains($0.captureID) }
    }

    init(capturesRoot: URL,
         makeSession: @escaping () -> AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         encoder: AudioEncoder,
         startCue: (@MainActor () async -> Void)? = nil,
         makeSecondarySink: SecondarySinkFactory? = nil,
         transcription: LiveTranscriptionCoordinator? = nil) {
        self.capturesRoot = capturesRoot
        self.transcription = transcription
        self.finalizer = FinalizerWorker(capturesRoot: capturesRoot, encoder: encoder)
        let spawn: @MainActor () -> CaptureCoordinator = {
            CaptureCoordinator(
                capturesRoot: capturesRoot,
                session: makeSession(),
                makeRecorder: makeRecorder,
                makeStore: { id, fmt in
                    SegmentStore(capturesRoot: capturesRoot, captureID: id, format: fmt)
                },
                startCue: startCue,
                makeSecondarySink: makeSecondarySink)
        }
        self.spawn = spawn
        self.coordinator = spawn()
    }

    /// Live composition root: platform session controller, real engine recorder, and the
    /// AVAssetWriter encoder, over Application Support.
    static func live() -> CaptureScreenModel {
        #if DEBUG
        if let harness = uiTestHarness() { return harness }
        #endif
        return CaptureScreenModel(
            capturesRoot: Self.defaultCapturesRoot(),
            makeSession: {
                #if os(iOS)
                IOSAudioSessionController()
                #else
                MacAudioSessionController()
                #endif
            },
            makeRecorder: { AudioEngineRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            startCue: { await StartCue().play() })
    }

    /// Composition root with live transcription attached.
    ///
    /// The transcription coordinator is built *before* the model because the model's init
    /// constructs the capture coordinator, which needs the sink factory — so the factory
    /// closure captures the transcription coordinator, never the model.
    static func liveWithTranscription() -> CaptureScreenModel {
        #if DEBUG
        if let harness = uiTestHarness() { return harness }
        #endif
        let root = Self.defaultCapturesRoot()
        let transcription = LiveTranscriptionCoordinator(
            capturesRoot: root,
            makeEngine: { SpeechAnalyzerEngine() })
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: {
                #if os(iOS)
                IOSAudioSessionController()
                #else
                MacAudioSessionController()
                #endif
            },
            makeRecorder: { AudioEngineRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            startCue: { await StartCue().play() },
            makeSecondarySink: { [weak transcription] id in transcription?.begin(captureID: id) },
            transcription: transcription)
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

    /// Called when the coordinator's finalize queue changes. Keyed off the queue, NOT
    /// the phase: `phase` flips to `.captured` before that transition's effects run
    /// (the debug-harness gate sits between), so a phase-triggered drain reads an
    /// empty queue, no-ops, and the capture never finalizes until the next launch's
    /// recovery scan. `enqueueFinalize` runs after `store.finish` — the durability
    /// commit — so this signal means the capture is fully on disk.
    /// The phase guard skips launch-recovery fills (`bootstrap` drains those itself).
    func handleFinalizeQueue() {
        guard !coordinator.finalizeQueue.isEmpty,
              coordinator.phase == .captured || coordinator.phase == .complete else { return }
        Task { await finishCurrentCapture() }
    }

    /// Stand the transcription session up once the format is readable.
    ///
    /// Keyed off `.recording` rather than the factory call: the factory runs inside
    /// `configureAndStart`, before `recorder.start` returns, so `activeFormat` is still
    /// nil there. Idempotent — SwiftUI may deliver the same phase more than once.
    func handlePhase() {
        guard let transcription,
              coordinator.phase == .recording,
              let id = coordinator.activeCaptureID,
              let format = coordinator.activeFormat else { return }
        transcription.activate(captureID: id, inputFormat: format)
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
        let transcribed = coordinator.activeCaptureID
        await runFinalizer(coordinator.finalizeQueue)
        // Strictly AFTER the finalizer. Three things read-modify-write `manifest.json`
        // and none are serialized against each other: `SegmentStore` holds it in memory
        // for the whole capture and clobbers on its next write, and `FinalizerWorker`
        // reads and writes across the encode+verify awaits, so a ref written into that
        // window is silently reverted. Here the store is dead and the finalizer is done —
        // the only point today where neither is true.
        if let transcribed { await recordTranscriptRef(for: transcribed) }
        refreshFinished()
        coordinator = spawn()
        finishing = false
    }

    private func recordTranscriptRef(for captureID: String) async {
        guard let transcription, let ref = await transcription.finish(captureID: captureID) else {
            return
        }
        let url = SegmentLayout.manifestURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        guard let data = try? Data(contentsOf: url),
              var manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: data)
        else { return }
        manifest.transcript = ref
        guard let encoded = try? CaptureCoding.encoder().encode(manifest) else { return }
        // Best-effort by design: a manifest we cannot update costs the re-derive hint,
        // not the recording or the transcript, both of which are already on disk.
        try? AtomicFile.replace(at: url, writing: encoded)
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
            let created = cap.manifest?.createdAt
                ?? FinishedRecording.timestamp(fromULID: cap.captureID)
                ?? Date(timeIntervalSince1970: 0)
            return FinishedRecording(captureID: cap.captureID,
                                     durationSeconds: seconds,
                                     createdAt: created)
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

                    if let transcription = model.transcription, !transcription.displayText.isEmpty {
                        ScrollView {
                            Text(transcription.displayText)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                        .accessibilityIdentifier("capture.transcript")
                    }

                    RecStatusLine(phase: model.coordinator.phase,
                                  canResume: model.coordinator.canResume,
                                  elapsed: model.coordinator.elapsed)

                    MicMeter(level: model.coordinator.micLevel,
                             isLive: model.coordinator.phase == .recording)

                    RecordButton(model: control, action: primaryAction)
                        .accessibilityIdentifier("capture.record")

                    if control.showsDoneButton {
                        Button("Done") { Task { await model.done() } }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityIdentifier("capture.done")
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
        .onChange(of: model.coordinator.phase) { _, _ in
            model.handlePhase()
        }
        .onChange(of: model.coordinator.finalizeQueue) { _, _ in
            model.handleFinalizeQueue()
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
                    FinishedRow(recording: item, capturesRoot: model.capturesRoot,
                                onDelete: { model.delete(item.captureID) })
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
    let onDelete: () -> Void

    @State private var playback: CapturePlayback?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(white: 0.9))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("finished.play")

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.formattedDuration)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("finished.duration")
                Text(recording.formattedCreatedAt)
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.55))
                    .accessibilityIdentifier("finished.createdAt")
                if let playback {
                    PlaybackProgressLine(playback: playback)
                }
            }
            Spacer()

            Button(role: .destructive) {
                playback?.stop()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color(white: 0.5))
            }
            .buttonStyle(.plain)
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
