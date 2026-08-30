import XCTest
import AVFAudio
@testable import Raconte

final class ModelFakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

final class ModelFakeRecorder: EngineRecording, @unchecked Sendable {
    var isRunning = false
    var captureFormatDescriptor: AudioFormatDescriptor? =
        AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    private let lock = NSLock()
    private var sink: PCMSink?

    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws {
        lock.withLock { self.sink = sink }
        isRunning = true
    }
    func stop() { isRunning = false }

    func feed(frames: Int) {
        let s = lock.withLock { sink }
        s?.receive(PCMChunk(data: Data(count: frames * 4),
                            frameCount: AVAudioFrameCount(frames), sampleRate: 48000))
    }
}

@MainActor
final class CaptureScreenModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureScreenModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 5,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Regression (macOS smoke run 8): finalize must run in-session after Done. The
    /// old wiring keyed off the phase flipping to `.captured`, which happens BEFORE
    /// the commit effects fill `finalizeQueue` — the drain no-op'd and the m4a only
    /// ever appeared via next-launch recovery. `handleFinalizeQueue` keys off the
    /// queue itself.
    func testDoneFinalizesInSessionWithoutRelaunch() async throws {
        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()
        let liveCoordinator = model.coordinator

        await model.record()
        recorder.feed(frames: 1000)
        await model.done()

        // The flush window commits the capture, then enqueueFinalize fills the queue.
        await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")

        // Simulate the view's onChange(of: finalizeQueue) relay.
        model.handleFinalizeQueue()

        await waitUntil({ model.library.items.isEmpty == false }, "library never refreshed")
        XCTAssertEqual(encoder.calls.count, 1, "encoder must run in-session, not at next launch")

        // Waited for, not asserted outright — and the difference is a CI failure.
        //
        // A refreshed library is NOT the signal that the coordinator has been replaced.
        // `finishCurrentCapture` does `await library.rescan()`, then `await
        // buildReceipt(...)` — which itself awaits a transcript read off disk — and only
        // then `coordinator = spawn()`. So the gate above goes true strictly before this
        // line's subject is set, with real I/O in between. It passed for as long as that
        // gap was one continuation; the post-stop receipt (a509a1b6) put a disk read in it,
        // and the first loaded CI runner to see the widened window lost the race
        // (run 31928162420, on a docs-only commit, which is the tell that nothing in the
        // product changed).
        //
        // This is the #4/#22 family again: gate on the effect you are asserting, never on
        // an earlier one that merely tends to precede it. `waitUntil` still XCTFails on
        // timeout, so a coordinator that genuinely never resets still fails here.
        //
        // Verified by inserting a 300 ms sleep in exactly that window, which reproduces the
        // CI message verbatim against the old assertion and passes against this one.
        await waitUntil({ model.coordinator !== liveCoordinator },
                        "model should reset to a fresh idle coordinator after the commit")

        let captureID = liveCoordinator.finalizeQueue[0]
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        let m4a = SegmentLayout.finalRecordingURL(captureDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path),
                      "final m4a missing — live finalize did not complete")
    }

    /// #62: trashing the receipt's entry must retire the receipt. The receipt's own
    /// "stays until dismissed, never on a timer" ruling stands — but it never considered
    /// the entry vanishing underneath it, and a receipt naming a trashed entry reads as
    /// the library having lost a recording.
    func testReconcileClearsTheReceiptWhenItsEntryIsTrashed() async throws {
        let model = try await modelWithAFinishedCaptureReceipt()
        let captureID = try XCTUnwrap(model.receipt?.captureID)

        let trashed = await model.library.trashEntry(captureID)
        XCTAssertTrue(trashed, "harness failure: trash itself must succeed")
        model.reconcileReceipt()

        XCTAssertNil(model.receipt, "receipt must not outlive its entry in the library")
    }

    /// The other direction: reconcile against an intact library is a no-op — the receipt
    /// keeps its never-on-a-timer guarantee for entries that still exist.
    func testReconcileKeepsTheReceiptWhileItsEntryExists() async throws {
        let model = try await modelWithAFinishedCaptureReceipt()

        model.reconcileReceipt()

        XCTAssertNotNil(model.receipt, "reconcile must never clear a receipt whose entry is present")
    }

    /// #62 adjacent ruling: restoring the entry from the trash does NOT bring the receipt
    /// back. The clear is a state change, not a live computation over the library — a
    /// computed "hide while missing" implementation would fail exactly here.
    func testRestoreDoesNotReviveAReconciledReceipt() async throws {
        let model = try await modelWithAFinishedCaptureReceipt()
        let captureID = try XCTUnwrap(model.receipt?.captureID)

        _ = await model.library.trashEntry(captureID)
        model.reconcileReceipt()
        XCTAssertNil(model.receipt)

        let restored = await model.library.restoreEntry(captureID)
        XCTAssertTrue(restored, "harness failure: restore itself must succeed")
        model.reconcileReceipt()

        XCTAssertNil(model.receipt, "a dismissed-by-trash receipt stays dismissed after restore")
    }

    /// Shared #62 fixture: run one capture through the real finish path until its
    /// receipt exists.
    private func modelWithAFinishedCaptureReceipt() async throws -> CaptureScreenModel {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let liveCoordinator = model.coordinator

        await model.record()
        recorder.feed(frames: 1000)
        await model.done()
        await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")
        model.handleFinalizeQueue()
        await waitUntil({ model.receipt != nil }, "receipt never built")
        return model
    }

    /// Doc test 22 (rapid start/stop cycles): every cycle must land as its own
    /// finalized entry — none merged, none dropped, no stuck non-idle state after.
    ///
    /// Investigated as a suspected #4/#22/08-07-family flake ("cycle 4 never
    /// committed", 733/734 in a full-suite CI run). Unlike that family, this loop
    /// already polls the correct terminal signal (`finalizeQueue`, not `phase`), and
    /// `finalizeQueue.append` runs in the SAME MainActor continuation as its own
    /// trigger (`completeCapture()` has no `await` before the append) — there is no
    /// competing task that can observe a "done" marker before this one lands, unlike
    /// the confirmed race in `testFailedResumeDiskWriteReturnsToInterruptedNotRecording`
    /// below. Reproduction attempts (24-spinner CPU load, a full 771-test suite run
    /// under that load, and reading every intermediate await in the `.done` →
    /// `.tailDrained` → `drainAndFinish` chain) found no wrong-value read — only that
    /// each cycle pays a real, unavoidable ~300ms `flushInterval` sleep plus real
    /// `SegmentStore` disk I/O (this test uses the real store, not a fake), so the
    /// per-cycle budget genuinely has less headroom than the family's microsecond-
    /// scale races. Widened from the default 5s accordingly — a right-sized bound for
    /// confirmed-non-racy real I/O, not a blind timeout bump.
    func testRapidRecordDoneCyclesProduceTenSeparateEntries() async throws {
        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()

        for cycle in 1...10 {
            let live = model.coordinator
            await model.record()
            recorder.feed(frames: 100)
            await model.done()
            await waitUntil({ live.finalizeQueue.isEmpty == false }, timeout: 15,
                            "cycle \(cycle) never committed")
            model.handleFinalizeQueue()   // the view's onChange relay
            await waitUntil({ model.library.items.count == cycle && model.coordinator !== live }, timeout: 15,
                            "cycle \(cycle) did not finalize + respawn")
        }

        XCTAssertEqual(model.library.items.count, 10)
        XCTAssertEqual(Set(model.library.items.map(\.captureID)).count, 10, "entries must be distinct")
        XCTAssertEqual(encoder.calls.count, 10)
        XCTAssertEqual(model.coordinator.phase, .idle, "stuck non-idle state after last cycle")
    }

    /// Doc test 7 (idle relaunch): a fresh launch over a root holding only complete
    /// captures shows no spurious recovery banner and keeps the entries playable.
    func testIdleRelaunchShowsNoSpuriousRecoveryBannerAndKeepsRecordings() async throws {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let live = model.coordinator
        await model.record()
        recorder.feed(frames: 1000)
        await model.done()
        await waitUntil({ live.finalizeQueue.isEmpty == false }, "capture never committed")
        model.handleFinalizeQueue()
        await waitUntil({ model.library.items.count == 1 }, "capture never finalized")

        // "Relaunch": a brand-new model over the same root.
        let relaunch = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder())
        await relaunch.bootstrap()

        XCTAssertTrue(relaunch.visibleRecovered.isEmpty, "spurious recovery banner")
        XCTAssertEqual(Set(relaunch.library.items.map(\.captureID)),
                       Set(model.library.items.map(\.captureID)))
    }

    /// Launch-recovery fills the queue while the phase is idle — the onChange relay
    /// must NOT respawn the coordinator then (bootstrap drains that queue itself).
    func testLaunchRecoveryQueueDoesNotRespawnCoordinator() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let coordinator = model.coordinator
        model.handleFinalizeQueue()   // queue empty and/or phase idle → no-op
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.coordinator === coordinator)
    }

    // MARK: - T6c: finalize wiring promotes revision zero

    /// The finalize call-site wiring (design §5's brief, step 4.6): after a capture
    /// finalizes with a real transcript, it must end up with exactly one canonical
    /// revision whose `coverageFrames` is non-nil — non-nil specifically PROVES
    /// promotion ran after `recordTranscriptRef` wrote `manifest.transcript`, not
    /// before it (the mutation check below).
    ///
    /// Drives a real `LiveTranscriptionCoordinator` over a `ScriptedTranscriptionEngine`
    /// (no models, no hardware — same fake `TranscriptionSessionTests` uses) so
    /// `recordTranscriptRef` has a real `TranscriptRef` to write, exactly as it would
    /// on device.
    func testFinalizePromotesRevisionZeroWithNonNilCoverageAfterTranscriptRefIsRecorded() async throws {
        let recorder = ModelFakeRecorder()
        let engine = ScriptedTranscriptionEngine()
        let transcription = LiveTranscriptionCoordinator(capturesRoot: root, makeEngine: { engine })
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            makeSecondarySink: { [weak transcription] id in transcription?.begin(captureID: id) },
            transcription: transcription)
        await model.bootstrap()

        await model.record()
        model.handlePhase()   // the view's onChange(of: phase) relay — activates transcription
        let captureID = try XCTUnwrap(model.coordinator.activeCaptureID)

        await waitUntil({ engine.calls.contains(.start) }, "transcription engine never started")

        recorder.feed(frames: 4_800)
        engine.emit(TranscriptResult(text: "hello", range: FrameRange(start: 0, end: 4_800),
                                     isVolatile: false, confidence: nil))

        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        await waitUntil({ !LiveTranscriptReader.load(captureDirectory: dir).records.isEmpty },
                        "committed result never reached live.jsonl")

        await model.done()
        await waitUntil({ model.coordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")
        model.handleFinalizeQueue()

        await waitUntil({ model.library.items.contains { $0.captureID == captureID } },
                        "library never refreshed after finalize")

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: dir)
        XCTAssertEqual(chain?.revisions.count, 1, "exactly one canonical revision after finalize")
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(revision.source, .machineLive)
        XCTAssertNotNil(revision.coverageFrames,
                        "coverageFrames must be copied from the manifest.transcript ref "
                        + "recordTranscriptRef just wrote — proves promotion ran AFTER it")
    }

    // MARK: selectedJournalVoiceLabels (owner ruling 2026-08-12, issue #56 follow-up:
    // the capture-time voice switch must speak the SELECTED journal's own voice
    // labels, not hardcoded "LN"/"BN")

    /// Cardinality-2 case 1: a journal with no configured labels reads as `[:]`, which
    /// is exactly the input `VoiceDisplay.accessibilityName` needs to fall back to the
    /// old uppercased-id behaviour — unlabelled journals must render unchanged.
    func testSelectedJournalVoiceLabelsIsEmptyForAnUnlabelledJournal() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            // Explicit, root-scoped registry root — `AppContainer.containerRoot(capturesRoot:)`
            // is `capturesRoot.deletingLastPathComponent()`, which for this file's
            // `root` (a direct child of the shared system temp dir) lands on that
            // SHARED temp dir. Without this override every test in this file writes
            // `journals.json` to the same place and pollutes every other test's
            // journal list.
            journalsContainerRoot: root)
        await model.bootstrap()

        XCTAssertEqual(model.selectedJournalVoiceLabels, [:])
    }

    /// Cardinality-2 case 2: once the current journal has labels configured, they are
    /// visible through this property with no separate cache to go stale — proving the
    /// capture screen's voice switch will pick up a save from the Voice Labels sheet.
    func testSelectedJournalVoiceLabelsReflectsTheConfiguredLabels() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            // Explicit, root-scoped registry root — `AppContainer.containerRoot(capturesRoot:)`
            // is `capturesRoot.deletingLastPathComponent()`, which for this file's
            // `root` (a direct child of the shared system temp dir) lands on that
            // SHARED temp dir. Without this override every test in this file writes
            // `journals.json` to the same place and pollutes every other test's
            // journal list.
            journalsContainerRoot: root)
        await model.bootstrap()

        let saved = await model.setCurrentJournalVoiceLabels(["bn": "Grandpa", "ln": "Me"])
        XCTAssertTrue(saved)
        XCTAssertEqual(model.selectedJournalVoiceLabels, ["bn": "Grandpa", "ln": "Me"])
    }

    /// A journal switch must not carry the old journal's labels forward — each
    /// journal's labels are its own, and a stale read here would leak one journal's
    /// voice names onto another journal's recording screen.
    func testSelectedJournalVoiceLabelsSwitchesWithTheJournal() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            // Explicit, root-scoped registry root — `AppContainer.containerRoot(capturesRoot:)`
            // is `capturesRoot.deletingLastPathComponent()`, which for this file's
            // `root` (a direct child of the shared system temp dir) lands on that
            // SHARED temp dir. Without this override every test in this file writes
            // `journals.json` to the same place and pollutes every other test's
            // journal list.
            journalsContainerRoot: root)
        await model.bootstrap()
        _ = await model.setCurrentJournalVoiceLabels(["bn": "Grandpa"])

        let created = await model.createJournal(name: "Second Journal")
        let second = try XCTUnwrap(created)
        model.selectJournal(second.id)

        XCTAssertEqual(model.selectedJournalVoiceLabels, [:],
                       "the freshly created journal has no labels of its own")
    }

    // MARK: journal create/rename must reach the shared library (nav T5 review, Important 2)
    //
    // `LibraryScreenModel.journals` (what the sidebar reads) and `CaptureScreenModel.journals`
    // (this model's own copy, appended/patched in place by `createJournal`/
    // `renameCurrentJournal`) are separate arrays that only reconcile through a rescan.
    // Discovered empirically by nav T5's own UI test: a journal created on the capture
    // screen was invisible in the sidebar until some UNRELATED place selection happened
    // to trigger a rescan first. `createJournal`/`renameCurrentJournal` must trigger that
    // rescan themselves rather than leaving it to whatever the caller does next.

    func testCreateJournalIsVisibleThroughTheSharedLibrary() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: root)
        await model.bootstrap()

        let result = await model.createJournal(name: "Second Journal")
        let created = try XCTUnwrap(result)

        XCTAssertTrue(model.library.journals.contains(where: { $0.id == created.id }),
                      "the shared library's own journals array never learned about the new journal")
    }

    /// Rename is the worse failure mode of the two: not a missing row, but a STALE NAME
    /// sitting in the sidebar.
    func testRenameCurrentJournalIsVisibleThroughTheSharedLibrary() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: root)
        await model.bootstrap()
        let id = try XCTUnwrap(model.selectedJournalID,
                               "harness failure: no default journal selected after bootstrap")

        await model.renameCurrentJournal(to: "Renamed Journal")

        let inLibrary = model.library.journals.first(where: { $0.id == id })
        XCTAssertEqual(inLibrary?.name, "Renamed Journal",
                       "the shared library still has the journal's OLD name")
    }

    // MARK: #94 secondary finding — bootstrap must push what it healed, same launch

    /// #94 secondary finding: a capture healed by LAUNCH recovery must be enqueued
    /// for sync in the same launch — before this fix, `bootstrap` ran the finalizer
    /// but never called `FinalizeArtifactPush.push`, so the heal waited a full
    /// relaunch to sync. End-to-end through the real pipeline: planner emits
    /// `.verifyFinal`, the finalizer stamps off the existing m4a (Task 2), and
    /// bootstrap pushes the now-eligible names into the recorded hooks.
    func testBootstrapPushesACaptureHealedByLaunchRecovery() async throws {
        let id = "01J000000000000000000097"
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let manifestFmt = AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: .finalizing, stateSeq: 7,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: 3,
                                lastKnownFrameOffset: 2500)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir),
                               writing: CaptureCoding.encoder().encode(manifest))

        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 2500, nonSilent: true)
        let hooks = RecordingSyncHooks()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: encoder)
        model.attach(syncHooks: hooks)

        await model.bootstrap()

        let names = await hooks.names
        XCTAssertTrue(names.contains(.entry(captureID: id)),
                      "a launch-healed capture must sync this launch, not the next one")
        XCTAssertTrue(names.contains(.audio(captureID: id)))
    }

    // MARK: Discard (record-flow plan, Task 2)

    /// A discarded capture still finalizes — the audio is committed and verified on disk —
    /// and is then trashed. Trash, not a hard delete: owner ruling 2026-08-29, the same
    /// "delete anywhere, recoverable 30 days" rule `delete(_:)` refuses to make an exception
    /// to. The library therefore ends with nothing visible and exactly one trashed entry.
    func testDiscardFinalizesTheCaptureAndThenTrashesIt() async throws {
        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()
        let liveCoordinator = model.coordinator

        await model.record()
        recorder.feed(frames: 1000)
        await model.discardCurrentCapture()

        await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")
        model.handleFinalizeQueue()

        await waitUntil({ model.coordinator !== liveCoordinator },
                        "model should reset to a fresh idle coordinator after the commit")
        XCTAssertEqual(encoder.calls.count, 1,
                       "a discarded capture must still finalize — the audio is trashed, not abandoned")
        XCTAssertTrue(model.library.items.isEmpty,
                      "a discarded capture must not be visible in the library")
        XCTAssertEqual(model.library.trashed.count, 1,
                       "the discarded capture belongs in the trash, recoverable")
    }

    /// No receipt. The receipt says "here is the reading you just made" — for a mis-tap that
    /// is exactly the cruft the owner asked not to be left with.
    func testDiscardLeavesNoReceipt() async throws {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let liveCoordinator = model.coordinator

        await model.record()
        recorder.feed(frames: 1000)
        await model.discardCurrentCapture()
        await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false }, "no commit")
        model.handleFinalizeQueue()
        await waitUntil({ model.coordinator !== liveCoordinator }, "no coordinator reset")

        XCTAssertNil(model.receipt, "a discarded capture must not produce a receipt")
        XCTAssertEqual(model.discardNotice, "Discarded to Trash",
                       "the screen must say what just happened")
    }

    /// The very next reading is an ordinary one. The discard flag is per-capture: if it
    /// survived, the next entry would silently trash itself — a data-loss bug, and the one
    /// this test exists to prevent.
    func testTheCaptureAfterADiscardIsKeptNormally() async throws {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()

        var live = model.coordinator
        await model.record()
        recorder.feed(frames: 1000)
        await model.discardCurrentCapture()
        await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit (discarded capture)")
        model.handleFinalizeQueue()
        await waitUntil({ model.coordinator !== live }, "no coordinator reset (discarded capture)")

        // Assert the notice immediately, before the second capture's four `waitUntil`
        // loops below can eat into its 3-second auto-clear on a loaded runner — a check
        // made only at the very end would pass whether or not `record()` actually clears
        // anything (fix round 1, Minor 3).
        XCTAssertEqual(model.discardNotice, "Discarded to Trash",
                       "the first capture's discard notice must be showing right after its finish")

        live = model.coordinator
        await model.record()
        XCTAssertNil(model.discardNotice, "starting the next reading must retire the discard notice")
        recorder.feed(frames: 1000)
        await model.done()
        await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit (kept capture)")
        model.handleFinalizeQueue()
        await waitUntil({ model.coordinator !== live }, "no coordinator reset (kept capture)")

        XCTAssertEqual(model.library.items.count, 1,
                       "the capture after a discard must be kept")
        XCTAssertNotNil(model.receipt, "a kept capture still gets its receipt")
        XCTAssertNil(model.discardNotice, "the notice must still be gone once the kept capture finishes")
    }

    /// Discard is only meaningful while the owner is holding a capture open. From idle it is
    /// a no-op — it must never arm the flag and trash whatever the NEXT reading turns out to
    /// be.
    func testDiscardFromIdleIsANoOp() async throws {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()

        await model.discardCurrentCapture()
        XCTAssertNil(model.discardNotice, "discard from idle must do nothing at all")

        let live = model.coordinator
        await model.record()
        recorder.feed(frames: 1000)
        await model.done()
        await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit")
        model.handleFinalizeQueue()
        await waitUntil({ model.coordinator !== live }, "no coordinator reset")

        XCTAssertEqual(model.library.items.count, 1,
                       "an idle-phase discard must not trash the next capture")
    }
}
