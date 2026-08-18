import XCTest
import AVFAudio
@testable import Raconte

/// nav T3, #62: the receipt-reconcile invariant moves out of `CaptureView`'s
/// `.onChange(of: model.library.allEntries)` and into a model-to-model notification —
/// `LibraryScreenModel.rescan()` tells `CaptureScreenModel` directly, via
/// `LibraryRescanObserver`, with no view involved. "A receipt whose entry left the
/// library is cleared" becomes a model invariant that holds regardless of what is
/// mounted.
///
/// The three existing #62 pins in `CaptureScreenModelTests` (clears/keeps/
/// restore-does-not-revive) exercise `reconcileReceipt()` itself and stay green
/// unmodified — this file exercises the WIRING that calls it, which those three do NOT
/// cover (mutation check 3 proves it: an empty `libraryDidRescan()` body leaves all
/// three of them green while this file's first test goes red).
@MainActor
final class LibraryRescanObserverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRescanObserverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Reuses `ModelFakeSession`/`ModelFakeRecorder`/`FakeAudioEncoder` from
    /// `CaptureScreenModelTests.swift` and the `journalsContainerRoot` override pattern
    /// from `CaptureScreenModelObservationTests.swift` — not a second set of fakes.
    private func makeModel(
        library: LibraryScreenModel? = nil
    ) -> (model: CaptureScreenModel, recorder: ModelFakeRecorder) {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: root,
            library: library)
        return (model, recorder)
    }

    private struct WaitTimeoutError: Error {}

    /// `Task.yield()`, never `Task.sleep`, between polls — see
    /// `CaptureScreenModelObservationTests.waitFor`'s own comment on why.
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

    /// Runs one capture through the real finish path until its receipt exists — no view
    /// constructed anywhere in this file, matching
    /// `CaptureScreenModelObservationTests`'s whole premise.
    private func makeModelWithACommittedReceipt() async throws -> (model: CaptureScreenModel, captureID: String) {
        let (model, recorder) = makeModel()
        await model.bootstrap()
        await model.record()
        try await waitFor("never entered .recording") { model.coordinator.phase == .recording }
        recorder.feed(frames: 1000)
        await model.done()
        try await waitFor("receipt never built") { model.receipt != nil }
        let captureID = try XCTUnwrap(model.receipt?.captureID)
        return (model, captureID)
    }

    // MARK: - The behavioral RED

    func testTrashingThroughTheLibraryClearsTheReceiptWithNoViewMounted() async throws {
        // RED reason (verified via `git stash` on LibraryScreenModel.swift /
        // CaptureScreenModel.swift / CaptureView.swift, restoring pre-task-3 code):
        // `reconcileReceipt()` used to be called only from `CaptureView`'s
        // `.onChange(of: model.library.allEntries)`. With no view built, nothing calls
        // it, so trashing the receipt's entry left `model.receipt` naming a captureID
        // that had just left the library — the #62 symptom, one layer down.
        let (model, captureID) = try await makeModelWithACommittedReceipt()

        let trashed = await model.library.trashEntry(captureID)   // ends in rescan()
        XCTAssertTrue(trashed, "harness failure: trash itself must succeed")

        XCTAssertNil(model.receipt,
                     "the model-to-model rescan hook must clear the receipt with no view mounted")
    }

    // MARK: - Restore-does-not-revive, through the wiring (no explicit call)

    /// #62 adjacent ruling, now pinned on the path production actually uses.
    /// `CaptureScreenModelTests.testRestoreDoesNotReviveAReconciledReceipt` drives
    /// `reconcileReceipt()` by an EXPLICIT call — but `reconcileReceipt()` now has
    /// exactly one production caller, `libraryDidRescan()`, so that test alone
    /// survives an empty `libraryDidRescan()` body (mutation check 3 already proves
    /// the same gap for the trash half). This continues the trash scenario through
    /// `restoreEntry` with NO explicit `reconcileReceipt()` call anywhere: both the
    /// trash-side clear and the restore-side non-revive must happen purely through
    /// the new wiring, or this goes red.
    func testRestoringThroughTheLibraryDoesNotReviveTheReceiptWithNoViewMounted() async throws {
        let (model, captureID) = try await makeModelWithACommittedReceipt()

        let trashed = await model.library.trashEntry(captureID)   // ends in rescan()
        XCTAssertTrue(trashed, "harness failure: trash itself must succeed")
        XCTAssertNil(model.receipt, "harness failure: the wiring must clear it before restore")

        let restored = await model.library.restoreEntry(captureID)   // ends in rescan() too
        XCTAssertTrue(restored, "harness failure: restore itself must succeed")

        XCTAssertNil(model.receipt,
                     "a dismissed-by-trash receipt must stay dismissed after restore, through the "
                     + "wiring, with no explicit reconcileReceipt() call")
    }

    // MARK: - Ordering safety against finishCurrentCapture's own rescan

    /// `finishCurrentCapture` does `rescan()` THEN `buildReceipt()` — pins that the new
    /// hook, firing from inside that rescan, cannot reconcile away a receipt that has
    /// not been built yet (`receipt` is nil at that point, so `reconcileReceipt()` is a
    /// guarded no-op), and that the entry the finished receipt names is genuinely
    /// present in `allEntries` once the whole chain has settled.
    func testAFreshReceiptSurvivesTheRescanThatPrecedesIt() async throws {
        let (model, captureID) = try await makeModelWithACommittedReceipt()

        XCTAssertEqual(model.receipt?.captureID, captureID)
        XCTAssertTrue(model.library.allEntries.contains { $0.captureID == captureID },
                      "the receipt's own entry must be visible in the library the rescan just published")
    }

    // MARK: - Ownership

    func testTheObserverIsHeldWeakly() async throws {
        let library = LibraryScreenModel(capturesRoot: root, journalsContainerRoot: root)
        do {
            let (capture, _) = makeModel(library: library)
            XCTAssertNotNil(library.rescanObserver, "the capture model must have registered itself")
            _ = capture
        }
        XCTAssertNil(library.rescanObserver, "a strong back-reference would be a retain cycle")
    }

    // MARK: - The generation guard

    /// Snapshots `journalScope` at the moment it is notified — the pin is not just
    /// "called once" but "called once, and only after the scan that actually published
    /// is the one it describes". A notify placed above `rescan()`'s
    /// `guard generation == scanGeneration` line would hand this spy a view of the world
    /// the model never adopted (the superseded scan's scope, not the winning one's).
    private final class RecordingRescanObserver: LibraryRescanObserver {
        private(set) var callCount = 0
        private(set) var scopeAtLastCall: JournalScope?
        private let library: LibraryScreenModel
        init(library: LibraryScreenModel) { self.library = library }
        func libraryDidRescan() {
            callCount += 1
            scopeAtLastCall = library.journalScope
        }
    }

    func testASupersededRescanDoesNotNotify() async throws {
        // Same construction as `LibraryScreenModelTests
        // .testTheLastStartedScanWinsRegardlessOfWhichFinishesFirst`: a non-`.all` scope
        // runs a SECOND scan for `recent`, so it reliably lands slower than — and after
        // — an `.all` scan started later. "Started first, finishes last" is exactly the
        // shape `scanGeneration` exists to reject.
        let library = LibraryScreenModel(capturesRoot: root, journalsContainerRoot: root)
        let spy = RecordingRescanObserver(library: library)
        library.rescanObserver = spy

        library.journalScope = .journal("does-not-exist")
        let stale = Task { await library.rescan() }
        await Task.yield()   // let it snapshot the narrow scope and suspend

        await library.selectJournalScope(.all)   // started later, must be the one that wins
        await stale.value

        XCTAssertEqual(spy.callCount, 1, "a superseded scan must not notify at all")
        XCTAssertEqual(spy.scopeAtLastCall, .all,
                       "the one notification must describe the scan that actually published")
        XCTAssertEqual(library.journalScope, .all)
    }
}
