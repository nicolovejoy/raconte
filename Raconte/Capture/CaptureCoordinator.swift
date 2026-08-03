import Foundation
import Observation
import AVFoundation

/// Wires the pure `CaptureMachine` (T2) to the imperative host: the `SegmentStore`
/// actor (T3), an `AudioSessionController` (T5), an engine recorder (T6), and the
/// launch recovery scan (T4). Owns the authoritative `MachineState`, translates UI
/// intents + `SessionEvent`s into machine `Event`s, and realizes each emitted
/// `Effect` in order against the store/recorder/session (design §2/§3/§4).
///
/// Observable (@Observable) and @MainActor so a SwiftUI screen (T10) binds directly
/// to `phase`, `elapsed`, `micLevel`, `lastError`, `recoveredRecordings`, and
/// `finalizeQueue`. All hardware sits behind injected protocols/closures so the whole
/// type is exercised with fakes + a real store on a temp dir (design §6).
///
/// Wiring decisions (see the T7 report for rationale):
/// - The `preparing` phase writes nothing to disk. `SegmentStore.begin()` bundles
///   dir-create + `recording` manifest + open-seg-0 and needs the hardware format,
///   which is unknown until the engine starts. So `createCaptureDirectory` /
///   `writeManifest(.preparing)` are in-memory only; all disk creation happens at
///   `recording` (row 2) via `begin()`. Safe: recovery discards any `preparing`/empty
///   dir, and nothing durable is claimed before it exists (§2 write-ahead exception).
/// - Segment rotation is driven inside `SegmentStore.append` (byte/duration caps), not
///   by feeding `rotationTick`; the coordinator never emits row-4 events.
/// - Finalization (rows 15–18) is out of scope: reached-`captured` captures are pushed
///   onto `finalizeQueue` (the T8 hand-off surface) and not encoded here.
/// Engine driver seam (design §6). `AudioEngineRecorder` (T6) conforms retroactively
/// below; tests inject a synthetic-PCM fake. Top-level (not nested in the @MainActor
/// coordinator) so the retroactive conformance carries no actor isolation.
protocol EngineRecording: AnyObject {
    var isRunning: Bool { get }
    /// Canonical capture format, available once `start` succeeds.
    var captureFormatDescriptor: AudioFormatDescriptor? { get }
    /// `matching` non-nil pins output to that format (resume path — the new input
    /// device's rate may differ from the capture's); nil adopts the hardware format.
    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws
    func stop()
}

/// Builds a fresh `SegmentStore` for a capture once its format is known. A closure,
/// not a protocol: tests inject a temp-dir factory and assert the real on-disk
/// manifest/segments the store writes.
typealias StoreFactory = @Sendable (_ captureID: String, _ format: AudioFormatDescriptor) -> SegmentStore

/// Builds an optional second `PCMSink` branch, fanned alongside the disk branch by
/// `TeeSink` (M2 design §4). `@MainActor` rather than `@Sendable` so the owner can
/// retain the product — a transcription session outlives the coordinator.
///
/// The format is deliberately NOT a parameter: it is unknown until
/// `recorder.start` returns. Read `CaptureCoordinator.activeFormat` instead.
typealias SecondarySinkFactory = @MainActor (_ captureID: String) -> (any PCMSink)?

@MainActor
@Observable
final class CaptureCoordinator {

    // MARK: Observable state (bound by the T10 UI)

    private(set) var phase: CaptureState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    private(set) var lastError: String?
    /// True after an interruption ended WITHOUT `.shouldResume`: UI shows a Resume button.
    private(set) var canResume = false
    /// Captures rescued at launch → "Recovered recording: MM:SS" banner (design §3).
    private(set) var recoveredRecordings: [RecoveredRecording] = []
    /// Captures recovery refused to delete because they hold a finalized `.m4a` or a
    /// transcript without a coherent manifest (issue #8). Published so the owner can
    /// be told they exist; no UI consumes it yet, and nothing on disk was touched.
    private(set) var quarantinedCaptureIDs: [String] = []
    /// Minimal finalize hand-off surface (T8 consumes): capture IDs whose raw audio is
    /// complete on disk and awaits AAC-LC encoding/verification. `capturesRoot` locates them.
    private(set) var finalizeQueue: [String] = []
    /// Ordered record of effects the coordinator has dispatched — test introspection only.
    private(set) var executedEffectLog: [Effect] = []

    /// The capture currently being prepared or recorded. Set as soon as `.record`
    /// is realized — before any disk exists — and cleared by `resetCaptureWiring()`.
    ///
    /// It is already nil by the time a `finalizeQueue` observer runs:
    /// `completeCapture()` enqueues and resets in one synchronous body, while the
    /// UI's `.onChange` relay schedules a `Task`. An owner that needs the ID must
    /// latch it at the preparing→recording edge.
    private(set) var activeCaptureID: String?

    /// Canonical PCM format of the active capture, readable once the engine has
    /// started. Deliberately **not** re-set on resume: the resume start pins
    /// `matching: format` and the tap resamples, so the emitted
    /// `PCMChunk.sampleRate` is invariant for the life of the capture — which is
    /// what lets a derived consumer keep one frame axis across an interruption.
    private(set) var activeFormat: AudioFormatDescriptor?

    /// Root of the on-disk capture tree; T8/T9 use it to locate queued captures.
    let capturesRoot: URL

    // MARK: Config + dependencies

    private let machine: CaptureMachine
    private let session: AudioSessionController
    private let makeRecorder: () -> EngineRecording
    private let makeStore: StoreFactory
    private let mintCaptureID: @Sendable () -> String
    private let now: @Sendable () -> Date
    /// Flush window kept open after Done so the last spoken tail lands (§2 row 12/13).
    /// `.zero` finishes synchronously — used by tests for determinism.
    private let flushInterval: Duration
    private let resumeBackoff: Duration
    /// Played just before the tap opens. `nil` in tests and the UI-test harness — the
    /// settle wait would add real time to every capture for no coverage.
    private let startCue: (@MainActor () async -> Void)?
    /// Second tee branch, built once per capture. `nil` in M1 and in tests that
    /// only care about the disk path.
    private let makeSecondarySink: SecondarySinkFactory?

    // MARK: Per-capture mutable wiring

    private var machineState: MachineState = .idle
    private var currentRecorder: EngineRecording?
    private var currentStore: SegmentStore?
    private var currentForwarder: PCMForwarder?
    /// Fan-out installed on the tap: disk branch first, then any injected
    /// secondary. Always present during a capture, even with one branch, so both
    /// `recorder.start` sites (initial + resume) hand the recorder the same
    /// object — a conditional tee would give the resume path a different sink and
    /// silently kill the second branch at the first interruption.
    private var currentTee: TeeSink?
    // nonisolated(unsafe): mutated only on the main actor; `deinit` (nonisolated in
    // Swift 6) cancels them, and it runs only when no other reference survives.
    nonisolated(unsafe) private var pumpTask: Task<Void, Never>?
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?
    nonisolated(unsafe) private var sessionTask: Task<Void, Never>?
    private let levelBox = LevelBox()
    private var recordingSegmentStart: Date?
    private var accumulatedElapsed: TimeInterval = 0
    /// The moment the system told us the current interruption ended (the
    /// `resumeAvailable` notification), captured at receipt regardless of
    /// `shouldResume`. Consumed (and cleared) the next time the entry closes as
    /// resumed; reset to nil whenever a new interruption begins, since no other
    /// path (route loss, mediaServicesReset, give-up) ever learns a true end
    /// time (issue #19).
    private var pendingInterruptionEndedAt: Date?
    /// Set when the *disk* half of a resume failed (issue #20), so the resulting
    /// `.reacquireFailed` write records why on the manifest — launch recovery
    /// carries `lastError` forward, so the evidence survives a kill. Nil for the
    /// session/engine reacquire failures, whose handling is unchanged.
    private var pendingResumeFailure: String?

    // MARK: Init

    init(capturesRoot: URL,
         session: AudioSessionController,
         makeRecorder: @escaping () -> EngineRecording,
         makeStore: @escaping StoreFactory,
         mintCaptureID: @escaping @Sendable () -> String = { CaptureCoordinator.makeULID() },
         now: @escaping @Sendable () -> Date = Date.init,
         machine: CaptureMachine = CaptureMachine(),
         flushInterval: Duration = .milliseconds(300),
         resumeBackoff: Duration = .milliseconds(500),
         startCue: (@MainActor () async -> Void)? = nil,
         makeSecondarySink: SecondarySinkFactory? = nil) {
        self.capturesRoot = capturesRoot
        self.session = session
        self.makeRecorder = makeRecorder
        self.makeStore = makeStore
        self.mintCaptureID = mintCaptureID
        self.now = now
        self.machine = machine
        self.flushInterval = flushInterval
        self.resumeBackoff = resumeBackoff
        self.startCue = startCue
        self.makeSecondarySink = makeSecondarySink
        subscribeToSession()
    }

    deinit {
        pumpTask?.cancel()
        timerTask?.cancel()
        sessionTask?.cancel()
    }

    // MARK: Launch recovery (design §3)

    /// Scan `capturesRoot`, plan + apply recovery, and publish the banner + finalize
    /// queue. Reads only JSON + file sizes (no PCM decode), so it's cheap.
    func recoverAtLaunch() async {
        let root = capturesRoot
        let clock = now
        let (outcome, durations) = await Task.detached { () -> (RecoveryOutcome, [String: Double]) in
            let snapshot = DirectorySnapshot.gather(capturesRoot: root)
            let actions = RecoveryPlanner.plan(snapshot)
            var durations: [String: Double] = [:]
            for case let .normalizeToCaptured(rec) in actions { durations[rec.captureID] = rec.durationSeconds }
            let executor = RecoveryExecutor(capturesRoot: root, now: clock)
            return (executor.apply(actions), durations)
        }.value

        recoveredRecordings = outcome.recoveredCaptureIDs.map {
            RecoveredRecording(captureID: $0, durationSeconds: durations[$0] ?? 0)
        }
        quarantinedCaptureIDs = outcome.quarantinedCaptureIDs
        for id in outcome.finalizeQueue + outcome.verifyQueue { enqueueFinalize(id) }
    }

    // MARK: UI intents

    /// User tapped Record. Mints the capture ULID and drives the whole prepare→record
    /// chain to completion (returns once recording, or after a prepare failure).
    func record() async {
        guard machineState.phase == .idle else { return }
        lastError = nil
        canResume = false
        await send(.record(captureID: mintCaptureID()))
    }

    /// User tapped Done. From `recording` this opens the flush window; from `interrupted`
    /// it commits `captured` immediately (design §2 rows 12/14).
    func done() async { await send(.done) }

    /// User tapped Resume after an interruption that didn't auto-resume.
    func resume() async {
        guard machineState.phase == .interrupted else { return }
        canResume = false
        await send(.resume)
    }

    // MARK: Event pipeline

    /// Reduce an event, publish the new phase, log the effects in machine order, then
    /// realize them. Illegal (state, event) pairs are no-ops.
    private func send(_ event: Event) async {
        let before = machineState
        let (next, effects) = machine.reduce(before, event)
        guard next != before || !effects.isEmpty else { return }
        machineState = next
        phase = next.phase
        #if DEBUG
        await TransitionBreakpointController.shared.gate(at: next.phase)
        #endif
        executedEffectLog.append(contentsOf: effects)
        await realize(event: event, previousPhase: before.phase, next: next, effects: effects)
    }

    private func subscribeToSession() {
        let stream = session.events
        sessionTask = Task { [weak self] in
            for await ev in stream {
                await self?.handleSessionEvent(ev)
            }
        }
    }

    private func handleSessionEvent(_ event: SessionEvent) async {
        switch event {
        case .interrupted:
            await send(.interruptionBegan)
        case .routeLost:
            // No "interruption ended" ever follows a route loss — the old device is
            // simply gone (macOS device switch, iOS unplug). Auto-resume onto the
            // current default input; reacquire failures fall into the existing
            // backoff/budget path. Guarded on the phase actually having transitioned
            // so a stray config-change can't resume e.g. a diskFull interruption.
            let wasRecording = machineState.phase == .recording
            await send(.routeLost)
            if wasRecording, machineState.phase == .interrupted { await send(.resume) }
        case .mediaServicesReset:
            await send(.mediaServicesReset)
            // The audio daemon restarted; the engine is rebuilt fresh on resume, so a
            // manual Resume is viable — surface the button rather than a dead end.
            if machineState.phase == .interrupted { canResume = true }
        case .resumeAvailable(let shouldResume):
            guard machineState.phase == .interrupted else { return }
            // The only signal we ever get for when the interruption actually ended
            // (issue #19) — capture it regardless of `shouldResume`, since a manual
            // resume later is still closing an interruption whose true end we know.
            pendingInterruptionEndedAt = now()
            if shouldResume { await send(.resume) } else { canResume = true }
        }
    }

    // MARK: Effect realization
    //
    // The store's coarse methods (`begin`/`finish`/`markInterrupted`/`resumeRecording`/
    // `setState`) each bundle a segment close and/or manifest write with the correct
    // internal write-ahead order (§2). So the coordinator realizes a transition's disk
    // effects via ONE store call keyed off the destination phase, while realizing
    // recorder/session effects from the list. For segment-closing transitions the tap
    // is stopped and the PCM pump drained BEFORE the store call, so the closed segment
    // contains every buffered frame (a necessary, documented deviation from strict
    // per-effect ordering; `executedEffectLog` still reflects machine order).

    private func realize(event: Event, previousPhase: CaptureState,
                         next: MachineState, effects: [Effect]) async {
        switch event {
        case .record(let id):
            activeCaptureID = id
            await configureAndStart(captureID: id)

        case .engineReady where previousPhase == .preparing:
            await beginRecording()

        case .engineReady where previousPhase == .resuming:
            // The disk side of the resume already ran, inside `rebuildAndReacquire`
            // (issue #20). Reaching `recording` therefore means the next segment is
            // genuinely open, so the clock may run.
            startRecordingClock(reset: false)

        case .prepareFailed(let error):
            handlePrepareFailed(error)

        case .interruptionBegan, .routeLost, .mediaServicesReset:
            await enterInterrupted(kind: interruptionKind(event))

        case .resume:
            await rebuildAndReacquire()

        case .reacquireFailed:
            await handleReacquireResult(next: next)

        case .done where previousPhase == .recording:
            await store(setState: .stopping)
            await beginFlushWindow()

        case .done where previousPhase == .interrupted:
            // Stop while interrupted: the entry never resumed (issue #9).
            await store(setState: .captured, closingInterruption: false)
            await completeCapture()

        case .tailDrained:
            await drainAndFinish()

        case .diskFull:
            currentRecorder?.stop()
            await store(setState: .interrupted, lastError: "diskFull")
            lastError = message(for: .diskFull)
            stopRecordingClock()

        default:
            // finalize rows (15–18) + last-gasp (20) are out of T7's scope; illegal
            // pairs never reach here (filtered as no-ops in `send`).
            break
        }
    }

    // MARK: prepare → record

    private func configureAndStart(captureID: String) async {
        guard await session.requestPermission() else {
            await send(.prepareFailed(.permissionDenied)); return
        }
        do { try await session.activate() }
        catch { await send(.prepareFailed(.configurationFailed)); return }

        // Cue BEFORE the tap goes live: the blip is the "start talking" signal, and
        // playing it here keeps it out of the recording (§ StartCue).
        await startCue?()

        let recorder = makeRecorder()
        let forwarder = PCMForwarder()
        // The format isn't known yet — `captureFormatDescriptor` only reads back
        // after `start` returns — so the factory gets the ID only and reads
        // `activeFormat` afterwards.
        let secondary = makeSecondarySink?(captureID)
        let tee = TeeSink(branches: [forwarder] + (secondary.map { [$0] } ?? []))
        let level = levelBox
        do {
            try recorder.start(sink: tee, matching: nil, onLevel: { level.set($0) })
        } catch {
            // NOTE: a produced secondary sink is simply dropped here and on the
            // format-guard path below. Harmless while it's inert; once it owns an
            // analyzer (T2) it will need an explicit abandon hook.
            session.deactivate()
            await send(.prepareFailed(.configurationFailed)); return
        }
        guard let format = recorder.captureFormatDescriptor else {
            recorder.stop(); session.deactivate()
            await send(.prepareFailed(.configurationFailed)); return
        }
        currentRecorder = recorder
        currentForwarder = forwarder
        currentTee = tee
        activeFormat = format
        await send(.engineReady)
    }

    private func beginRecording() async {
        guard let id = activeCaptureID, let format = activeFormat,
              let forwarder = currentForwarder else { return }
        let store = makeStore(id, format)
        currentStore = store
        do { try await store.begin() }
        catch {
            lastError = message(for: .diskFull)
            await teardownFailedCapture()
            return
        }
        startPump(store: store, forwarder: forwarder)
        startRecordingClock(reset: true)
    }

    private func handlePrepareFailed(_ error: CaptureError) {
        currentRecorder?.stop()
        session.deactivate()
        lastError = message(for: error)
        resetCaptureWiring()
    }

    // MARK: interruption / resume

    private func enterInterrupted(kind: String) async {
        // A new interruption; any end-time signal captured for a previous one no
        // longer applies (issue #19).
        pendingInterruptionEndedAt = nil
        currentRecorder?.stop()
        await flushPump()
        if let store = currentStore {
            try? await store.markInterrupted(kind: kind, beganAt: now())
        }
        stopRecordingClock()
    }

    private func rebuildAndReacquire() async {
        await store(setState: .resuming)   // write-ahead (§2 row 8) before reacquiring
        do { try await session.activate() }
        catch { await send(.reacquireFailed); return }
        // The tee, not the forwarder: the resume start must install the SAME
        // fan-out, or every branch past the disk one dies at the first
        // interruption while the on-disk result stays perfect.
        guard let tee = currentTee, let format = activeFormat else {
            await send(.reacquireFailed); return
        }
        // Fresh recorder: a new AVAudioEngine binds the CURRENT default input (the old
        // engine can be stale after a device switch / media services reset). Pinned to
        // the capture's canonical format — the new device's rate may differ, and the
        // segment chain must keep one rate (the tap resamples if needed).
        currentRecorder?.stop()
        let recorder = makeRecorder()
        let level = levelBox
        do { try recorder.start(sink: tee, matching: format, onLevel: { level.set($0) }) }
        catch { await send(.reacquireFailed); return }
        currentRecorder = recorder

        // Issue #20: the disk half of the resume (persist `recording`, open the next
        // segment) runs HERE, before the machine is told the engine is ready, because
        // `.reacquireFailed` is only legal from `resuming`. Once `.engineReady` lands
        // the phase is `recording` and there is no honest way back — a swallowed
        // failure would raise the elapsed clock and the red indicator over a capture
        // whose every later chunk the pump discards as `notRecording`.
        //
        // This is the same deviation-from-effect-order the section header documents:
        // one coarse store call, placed where its failure is still expressible.
        if let store = currentStore {
            do {
                try await store.resumeRecording(interruptionEndedAt: pendingInterruptionEndedAt)
                pendingInterruptionEndedAt = nil
            } catch {
                // Not recording: stop the tap we just opened (nothing consumes it —
                // the store has no live segment) and let rows 10/11 decide between
                // another backoff retry and giving up to `captured`. The audio
                // already on disk is untouched by either.
                recorder.stop()
                pendingResumeFailure = "resumeFailed"
                await send(.reacquireFailed)
                return
            }
        }
        await send(.engineReady)
    }

    private func handleReacquireResult(next: MachineState) async {
        let resumeFailure = pendingResumeFailure
        pendingResumeFailure = nil
        if next.phase == .interrupted {
            await store(setState: .interrupted, lastError: resumeFailure,
                        retryCount: next.retryCount)
            if resumeFailure != nil { lastError = "Couldn't resume recording — retrying" }
            scheduleResumeBackoff()
        } else if next.phase == .captured {
            // Resume-retry budget exhausted: gave up without ever resuming (issue #9).
            await store(setState: .captured, lastError: resumeFailure,
                        closingInterruption: false)
            if resumeFailure != nil {
                lastError = "Couldn't resume recording. Saved what was recorded."
            }
            await completeCapture()
        }
    }

    private func scheduleResumeBackoff() {
        let backoff = resumeBackoff
        Task { [weak self] in
            try? await Task.sleep(for: backoff)
            guard let self, await self.machineState.phase == .interrupted else { return }
            await self.send(.resume)
        }
    }

    // MARK: Done / stopping

    private func beginFlushWindow() async {
        if flushInterval == .zero {
            await send(.tailDrained)
        } else {
            let interval = flushInterval
            Task { [weak self] in
                try? await Task.sleep(for: interval)
                await self?.send(.tailDrained)
            }
        }
    }

    private func drainAndFinish() async {
        currentRecorder?.stop()
        await flushPump()
        if let store = currentStore {
            do { try await store.finish(reason: .stop) }
            catch { lastError = message(for: .diskFull) }
        }
        session.deactivate()
        await completeCapture()
    }

    /// A capture reached `captured` (durability commit point). Hand it to the finalizer
    /// queue and tear down the live wiring.
    private func completeCapture() async {
        if let id = activeCaptureID { enqueueFinalize(id) }
        stopRecordingClock()
        finishPump()
        resetCaptureWiring()
    }

    // MARK: Disk helpers

    /// Realize a `writeManifest` effect for a plain state transition via the store's
    /// generic `setState` (no segment close involved).
    private func store(setState state: CaptureState,
                       needsAttention: Bool? = nil, lastError: String? = nil,
                       retryCount: Int? = nil, finalizeAttempts: Int? = nil,
                       closingInterruption resumed: Bool? = nil) async {
        guard let store = currentStore else { return }
        try? await store.setState(state, needsAttention: needsAttention, lastError: lastError,
                                  retryCount: retryCount, finalizeAttempts: finalizeAttempts,
                                  closingInterruption: resumed)
    }

    private func enqueueFinalize(_ id: String) {
        guard !finalizeQueue.contains(id) else { return }
        finalizeQueue.append(id)
    }

    // MARK: PCM pump (tap → store)

    /// A detached loop draining the tap-fed forwarder into the store, serially and off
    /// the main actor. `flushPump()` inserts an ordered barrier so control transitions
    /// observe every buffered frame; `finishPump()` ends the loop after `captured`.
    private func startPump(store: SegmentStore, forwarder: PCMForwarder) {
        pumpTask?.cancel()
        pumpTask = Task.detached { [weak self] in
            for await item in forwarder.stream {
                switch item {
                case .chunk(let chunk):
                    do { try await store.append(chunk) }
                    catch SegmentStore.SegmentStoreError.notRecording { continue }
                    catch { await self?.send(.diskFull); return }
                case .barrier(let id):
                    forwarder.resumeBarrier(id)
                }
            }
        }
    }

    private func flushPump() async {
        guard let forwarder = currentForwarder, pumpTask != nil else { return }
        await forwarder.flush()
    }

    private func finishPump() {
        currentForwarder?.finish()
        pumpTask = nil
    }

    // MARK: Elapsed clock + meter

    private func startRecordingClock(reset: Bool) {
        if reset { accumulatedElapsed = 0 }
        recordingSegmentStart = now()
        elapsed = accumulatedElapsed
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tick() {
        micLevel = levelBox.get()
        if let start = recordingSegmentStart {
            elapsed = accumulatedElapsed + now().timeIntervalSince(start)
        }
    }

    private func stopRecordingClock() {
        if let start = recordingSegmentStart {
            accumulatedElapsed += now().timeIntervalSince(start)
            recordingSegmentStart = nil
            elapsed = accumulatedElapsed
        }
        timerTask?.cancel()
        timerTask = nil
        micLevel = 0
    }

    // MARK: Teardown

    private func teardownFailedCapture() async {
        currentRecorder?.stop()
        session.deactivate()
        finishPump()
        resetCaptureWiring()
    }

    private func resetCaptureWiring() {
        currentRecorder = nil
        currentStore = nil
        currentForwarder = nil
        currentTee = nil
        activeFormat = nil
        activeCaptureID = nil
        recordingSegmentStart = nil
        pendingInterruptionEndedAt = nil
        pendingResumeFailure = nil
    }

    // MARK: Small helpers

    private func interruptionKind(_ event: Event) -> String {
        switch event {
        case .routeLost: return "routeChange"
        case .mediaServicesReset: return "mediaServicesReset"
        default: return "interruption"
        }
    }

    private func message(for error: CaptureError) -> String {
        switch error {
        case .permissionDenied: return "Microphone access denied"
        case .configurationFailed: return "Couldn't start recording"
        case .diskFull: return "Storage full"
        }
    }
}

// MARK: - Recovered banner item

/// One capture rescued at launch, for the "Recovered recording: MM:SS" banner (§3).
struct RecoveredRecording: Identifiable, Equatable, Sendable {
    let captureID: String
    let durationSeconds: Double
    var id: String { captureID }

    /// "MM:SS" for the banner (design §3 `formatDuration`).
    var formattedDuration: String { CaptureCoordinator.formatDuration(durationSeconds) }
}

// MARK: - ULID + duration formatting

extension CaptureCoordinator {
    /// Lexicographically-sortable, time-prefixed ID (design §1 `captureID`). 48-bit
    /// millisecond timestamp + 80 bits of randomness, Crockford base32, 26 chars.
    /// The algorithm moved to `ULID` (M3 T1) because journals mint ids too; this stays
    /// as the capture path's name for it, unchanged for every existing call site.
    nonisolated static func makeULID(now: Date = Date()) -> String {
        ULID.make(now: now)
    }

    nonisolated static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Retroactive engine conformance (T6)

extension AudioEngineRecorder: EngineRecording {
    var captureFormatDescriptor: AudioFormatDescriptor? {
        guard let f = captureFormat else { return nil }
        return AudioFormatDescriptor(from: f)
    }
}

extension AudioFormatDescriptor {
    /// Map an `AVAudioFormat` to the on-disk descriptor. `bytesPerFrame` is left nil —
    /// the store derives it (design §1: sidecar carries it, manifest omits it).
    init(from format: AVAudioFormat) {
        let common: PCMCommonFormat
        switch format.commonFormat {
        case .pcmFormatFloat32: common = .pcmFormatFloat32
        case .pcmFormatFloat64: common = .pcmFormatFloat64
        case .pcmFormatInt16: common = .pcmFormatInt16
        case .pcmFormatInt32: common = .pcmFormatInt32
        case .otherFormat: common = .otherFormat
        @unknown default: common = .otherFormat
        }
        self.init(sampleRate: Int(format.sampleRate),
                  channels: Int(format.channelCount),
                  commonFormat: common,
                  interleaved: format.isInterleaved)
    }
}

// MARK: - PCM forwarder (tap-thread → pump)

/// Bridges the non-blocking tap thread to the serial PCM pump. `receive` yields onto
/// an `AsyncStream` (lock-free); `flush` inserts an ordered barrier the pump resumes
/// once every prior chunk has been appended, giving control transitions a deterministic
/// "all buffered frames are on the store" point.
final class PCMForwarder: PCMSink, @unchecked Sendable {
    enum Item: Sendable { case chunk(PCMChunk); case barrier(UUID) }

    let stream: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation
    private let lock = NSLock()
    private var barriers: [UUID: CheckedContinuation<Void, Never>] = [:]

    init() {
        (stream, continuation) = AsyncStream<Item>.makeStream()
    }

    nonisolated func receive(_ chunk: PCMChunk) {
        continuation.yield(.chunk(chunk))
    }

    func flush() async {
        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock(); barriers[id] = cont; lock.unlock()
            if case .terminated = continuation.yield(.barrier(id)) {
                resumeBarrier(id)
            }
        }
    }

    func resumeBarrier(_ id: UUID) {
        lock.lock()
        let cont = barriers.removeValue(forKey: id)
        lock.unlock()
        cont?.resume()
    }

    func finish() { continuation.finish() }
}

// MARK: - Mic-level box

/// Thread-safe latest-value box so the @Sendable tap-level callback never touches the
/// main actor per buffer; the elapsed timer publishes `micLevel` from it.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    func set(_ value: Float) { lock.lock(); level = value; lock.unlock() }
    func get() -> Float { lock.lock(); defer { lock.unlock() }; return level }
}
