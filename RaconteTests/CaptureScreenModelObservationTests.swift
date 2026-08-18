import XCTest
import AVFAudio
@testable import Raconte

/// Records every `setIdleTimerDisabled` call in order; `current` is the latest value,
/// mirroring how a real idle-timer hold is read.
@MainActor
final class FakeIdleTimer: IdleTimerControlling {
    private(set) var calls: [Bool] = []
    var current: Bool? { calls.last }
    func setIdleTimerDisabled(_ disabled: Bool) { calls.append(disabled) }
}

/// nav T2: the coordinator dispatch (finalize queue drain, phase-triggered transcription
/// activation + sidecar write) and the iOS idle-timer hold used to live entirely in
/// `CaptureView.body`'s `.onChange`/`.onAppear`/`.onDisappear` — guarantees about a
/// per-capture side effect that only held while a SwiftUI view happened to be mounted.
/// Once `CaptureView` can be pushed off a `NavigationSplitView` selection (nav T4), that
/// stops being true: a capture that commits while the owner is elsewhere in the app must
/// still finalize. These tests construct no view at all — that absence is the whole point.
@MainActor
final class CaptureScreenModelObservationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureScreenModelObservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Reuses `ModelFakeSession`/`ModelFakeRecorder` from `CaptureScreenModelTests.swift`
    /// rather than minting a second set of fakes.
    private func makeModel(
        idleTimer: any IdleTimerControlling = FakeIdleTimer()
    ) -> (model: CaptureScreenModel, recorder: ModelFakeRecorder) {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            // Explicit, root-scoped registry root — see the same override's comment in
            // CaptureScreenModelTests.swift: without it every test in this target shares
            // one journals.json under the system temp dir.
            journalsContainerRoot: root,
            idleTimer: idleTimer)
        return (model, recorder)
    }

    private struct WaitTimeoutError: Error {}

    /// Polls the observable state to convergence. Deliberately `Task.yield()`, never
    /// `Task.sleep`, between attempts — a sleep-shielded assertion is exactly what hid
    /// `testFailedResumeDiskWriteReturnsToInterruptedNotRecording` (the #4/#22 flake
    /// family): the point of polling is to keep checking the REAL signal, not to wait a
    /// fixed duration and hope it landed.
    private func waitFor(timeout: TimeInterval = 5,
                         _ message: String = "condition not met",
                         file: StaticString = #filePath, line: UInt = #line,
                         _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail(message, file: file, line: line)
                throw WaitTimeoutError()
            }
            await Task.yield()
        }
    }

    // MARK: - finalize dispatch with no view mounted

    func testACaptureFinalizesWithNoViewMounted() async throws {
        let (model, recorder) = makeModel()
        await model.bootstrap()

        await model.record()
        try await waitFor("never entered .recording") { model.coordinator.phase == .recording }
        recorder.feed(frames: 1000)
        await model.done()

        // The receipt is built at the END of finishCurrentCapture, after the finalizer,
        // the transcript ref, revision promotion, spoken-date detection and the rescan —
        // so waiting for it is waiting for the whole chain, not just the phase flip.
        try await waitFor("receipt never built — capture never finalized with no view mounted") {
            model.receipt != nil
        }
        XCTAssertEqual(model.library.allEntries.count, 1)
    }

    /// Cardinality ≥ 2: `finishCurrentCapture` REPLACES the coordinator
    /// (`coordinator = spawn()`), so an observation armed against the first instance and
    /// never re-armed would pass the single-capture test above and fail here.
    func testASecondCaptureFinalizesToo() async throws {
        let (model, recorder) = makeModel()
        await model.bootstrap()

        await model.record()
        try await waitFor("never entered .recording (capture 1)") { model.coordinator.phase == .recording }
        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("capture 1 never finalized") { model.receipt != nil }
        XCTAssertEqual(model.library.allEntries.count, 1)

        model.dismissReceipt()

        await model.record()
        try await waitFor("never entered .recording (capture 2)") { model.coordinator.phase == .recording }
        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("capture 2 never finalized") { model.receipt != nil }
        XCTAssertEqual(model.library.allEntries.count, 2)
    }

    // MARK: - idle timer hold

    func testIdleTimerIsHeldWhileRecordingAndReleasedAfterwards() async throws {
        let timer = FakeIdleTimer()
        let (model, recorder) = makeModel(idleTimer: timer)
        await model.bootstrap()
        XCTAssertEqual(timer.current, false, "an idle model must not hold the display awake")

        await model.record()
        try await waitFor("idle timer never engaged for .recording") { timer.current == true }

        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("idle timer never released after done()") { timer.current == false }
    }

    /// Same re-arm hazard as `testASecondCaptureFinalizesToo`, on the idle-timer half:
    /// an observation that only fires once would hold the timer disabled through the
    /// first capture and then go silent forever, leaking the hold on every capture after.
    func testIdleTimerFollowsTheRespawnedCoordinator() async throws {
        let timer = FakeIdleTimer()
        let (model, recorder) = makeModel(idleTimer: timer)
        await model.bootstrap()

        await model.record()
        try await waitFor("idle timer never engaged (capture 1)") { timer.current == true }
        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("idle timer never released (capture 1)") { timer.current == false }
        try await waitFor("capture 1 never finalized") { model.receipt != nil }
        model.dismissReceipt()

        await model.record()
        try await waitFor("idle timer never engaged (capture 2, respawned coordinator)") {
            timer.current == true
        }
        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("idle timer never released (capture 2)") { timer.current == false }
    }

    // MARK: - coalescing, not losing, changes inside one main-actor turn

    /// The observation is LEVEL-triggered, not edge-triggered: every handler re-reads
    /// current state off `coordinator`, so a phase that moves twice inside one main-actor
    /// turn (no `await` between `record()` and `done()` here) still ends with the handlers
    /// agreeing with the coordinator, and the capture still finalizes.
    func testAPhaseChangeDuringTheDispatchHopIsNotLost() async throws {
        let (model, recorder) = makeModel()
        await model.bootstrap()

        // Back to back, no intermediate wait for `.recording` to be observed: both
        // transitions land ahead of the dispatch Task's first chance to run. `record()`
        // itself must be awaited to completion before the fake recorder has a sink to
        // feed (it is installed inside `coordinator.record()`'s effect chain), so the
        // feed sits between the two calls rather than before both.
        await model.record()
        recorder.feed(frames: 1000)
        await model.done()

        try await waitFor("receipt never built after a back-to-back record()/done()") {
            model.receipt != nil
        }
        XCTAssertEqual(model.library.allEntries.count, 1)
    }
}
