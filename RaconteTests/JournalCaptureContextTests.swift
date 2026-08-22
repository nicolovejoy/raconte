import XCTest
import AVFAudio
@testable import Raconte

private final class ContextFakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

private final class ContextFakeRecorder: EngineRecording, @unchecked Sendable {
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

/// M3 T3's guarantees, which had no unit coverage: which journal a capture files into,
/// that the answer reaches `entry.json` while the capture is still live, and what happens
/// when the registry is damaged.
@MainActor
final class JournalCaptureContextTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var journalsURL: URL { AppContainer.journalsURL(containerRoot: containerRoot) }
    private var prefs: InMemoryJournalPreferenceStore!

    /// The live-capture write boundary truncates the picker's `Date` to `PartialDate` at
    /// `precision` (`.day` unless the test sets otherwise) before it reaches the sidecar.
    private func expectedBackdate(_ seconds: Double, precision: DatePrecision = .day) -> PartialDate {
        PartialDate(from: Date(timeIntervalSince1970: seconds), precision: precision,
                   calendar: .gregorianCurrent)
    }

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalCaptureContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        prefs = InMemoryJournalPreferenceStore()
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func makeModel(recorder: ContextFakeRecorder = ContextFakeRecorder())
    -> CaptureScreenModel {
        CaptureScreenModel(
            capturesRoot: capturesRoot,
            makeSession: { ContextFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: containerRoot,
            journalPreferenceStore: prefs)
    }

    /// The sidecar is written by a task the model enqueues, so every assertion about it
    /// polls the file rather than assuming the write has landed.
    private func waitForSidecar(_ captureID: String,
                                timeout: TimeInterval = 5,
                                _ message: String,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ predicate: (EntryMetadata) -> Bool) async {
        let url = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let metadata = try? EntryMetadataStore.read(url: url), predicate(metadata) { return }
            if Date() > deadline {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "<no file>"
                XCTFail("\(message) — sidecar is \(text)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func startRecording(_ model: CaptureScreenModel,
                                _ recorder: ContextFakeRecorder) async throws -> String {
        await model.record()
        recorder.feed(frames: 480)
        model.handlePhase()   // the view's onChange(of: phase) relay
        return try XCTUnwrap(model.coordinator.activeCaptureID)
    }

    /// An absent sidecar reads as `.defaults`, so "the first write has landed" cannot be
    /// asked of the decoded value — only of the file.
    private func waitForSidecarFile(_ captureID: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let url = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() > deadline {
                return XCTFail("entry.json was never written", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: (a) first launch

    func testFirstLaunchMintsAndSelectsTheDefaultJournal() async throws {
        let model = makeModel()
        await model.bootstrap()

        XCTAssertEqual(model.journals.map(\.name), ["Journal"])
        XCTAssertEqual(model.selectedJournalID, model.journals.first?.id)
        XCTAssertEqual(model.selectedJournalName, "Journal")
        XCTAssertFalse(model.registryUnreadable)
        XCTAssertEqual(prefs.string(forKey: CurrentJournal.defaultsKey), model.selectedJournalID)

        // Persisted, not just in memory: the next launch must not mint a second one.
        let registry = try JournalStore.load(url: journalsURL)
        XCTAssertEqual(registry.journals.map(\.name), ["Journal"])

        let relaunch = makeModel()
        await relaunch.bootstrap()
        XCTAssertEqual(relaunch.journals.count, 1)
        XCTAssertEqual(relaunch.selectedJournalID, model.selectedJournalID)
    }

    // MARK: (b) the capture carries the selection

    func testCaptureSidecarCarriesTheSelectedJournalWhileRecording() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let selected = try XCTUnwrap(model.selectedJournalID)

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "journal never reached entry.json") {
            $0.journalID == selected
        }
        // The default is a semantic, not a value: an un-backdated entry writes no date.
        await waitForSidecar(captureID, "originalDate must stay absent") {
            $0.journalID == selected && $0.originalDate == nil
        }
    }

    // MARK: (c) switching mid-capture

    func testSwitchingJournalMidCaptureRewritesTheSidecar() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let first = try XCTUnwrap(model.selectedJournalID)

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "first journal never landed") { $0.journalID == first }

        let created = await model.createJournal(name: "  Trip to France  ")
        let second = try XCTUnwrap(created)
        XCTAssertEqual(second.name, "Trip to France", "insert normalizes the name")
        model.selectJournal(second.id)

        await waitForSidecar(captureID, "switch never reached the live capture's sidecar") {
            $0.journalID == second.id
        }
    }

    /// The backdate reaches the same file by the same path — and the write is enqueued
    /// synchronously, so the *last* value set is the one that lands, whatever order the
    /// store's actor serves the writes in.
    func testLastBackdateSetWinsRegardlessOfWriteCompletionOrder() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let captureID = try await startRecording(model, recorder)

        model.setBackdateEnabled(true)
        for seconds in stride(from: 100.0, through: 1_000.0, by: 100.0) {
            model.setBackdateDate(Date(timeIntervalSince1970: seconds))
        }
        let last = expectedBackdate(1_000)

        await waitForSidecar(captureID, "sidecar settled on a stale date") {
            $0.originalDate == last
        }
        // And it stays there — a straggler from an earlier set must not arrive late.
        try await Task.sleep(for: .milliseconds(200))
        await waitForSidecar(captureID, "a stale write landed after the last one") {
            $0.originalDate == last
        }
    }

    func testTurningTheBackdateOffClearsItFromTheSidecar() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let captureID = try await startRecording(model, recorder)

        model.setBackdateEnabled(true)
        model.setBackdateDate(Date(timeIntervalSince1970: 500))
        await waitForSidecar(captureID, "backdate never landed") {
            $0.originalDate == expectedBackdate(500)
        }
        model.setBackdateEnabled(false)
        await waitForSidecar(captureID, "backdate never cleared") { $0.originalDate == nil }
    }

    // MARK: Finding 1 — an unreadable registry is not an empty one

    func testUnreadableRegistryIsReportedAndNotOverwritten() async throws {
        let damaged = Data("{ not a registry".utf8)
        try damaged.write(to: journalsURL)

        let model = makeModel()
        await model.bootstrap()

        XCTAssertTrue(model.registryUnreadable)
        XCTAssertTrue(model.journals.isEmpty)
        XCTAssertNil(model.selectedJournalID, "nothing may claim to be selected")
        XCTAssertNotEqual(model.selectedJournalName, "Journal",
                          "the literal would present a selection that does not exist")
        XCTAssertEqual(try Data(contentsOf: journalsURL), damaged,
                       "a registry we failed to parse must not be replaced by a default")
    }

    /// The user-visible half: with no selection, a capture's sidecar keeps whatever
    /// journal it already had. `handlePhase` re-runs on every re-entry to `.recording`
    /// (an interruption resume does exactly that), so writing nil would unfile an entry
    /// a working earlier launch had filed.
    func testNoSelectionLeavesAnExistingJournalIDAlone() async throws {
        try Data("{ not a registry".utf8).write(to: journalsURL)
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        XCTAssertTrue(model.registryUnreadable)

        let captureID = try await startRecording(model, recorder)
        await waitForSidecarFile(captureID)   // let the phase-triggered write land first
        let url = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        // Stand in for a sidecar an earlier, working launch wrote.
        try EntryMetadataStore.write(EntryMetadata(journalID: "FILED-EARLIER"), url: url)

        // Any later sidecar write — here a backdate — must not carry nil into journalID.
        model.setBackdateEnabled(true)
        model.setBackdateDate(Date(timeIntervalSince1970: 700))
        await waitForSidecar(captureID, "backdate never landed") {
            $0.originalDate == expectedBackdate(700)
        }
        XCTAssertEqual(try EntryMetadataStore.read(url: url).journalID, "FILED-EARLIER",
                       "an absent selection unfiled an already-filed entry")
    }

    /// A registry that is merely *empty* still mints the default — the absent/unreadable
    /// line has to fall on the right side for both answers.
    func testEmptyRegistryFileStillMintsTheDefault() async throws {
        try JournalStore.encode(JournalRegistry()).write(to: journalsURL)
        let model = makeModel()
        await model.bootstrap()
        XCTAssertFalse(model.registryUnreadable)
        XCTAssertEqual(model.journals.map(\.name), ["Journal"])
    }

    // MARK: precision write path (adversarial-review test gap)

    func testPrecisionReachesTheSidecarAlongsideOriginalDate() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let captureID = try await startRecording(model, recorder)

        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.yearMonth)
        model.setBackdateDate(Date(timeIntervalSince1970: 500))
        await waitForSidecar(captureID, "precision never reached entry.json") {
            $0.originalDate == expectedBackdate(500, precision: .yearMonth)
                && $0.originalDate?.precision == .yearMonth
        }
    }

    func testTogglingOffClearsBothOriginalDateAndPrecision() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let captureID = try await startRecording(model, recorder)

        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.year)
        model.setBackdateDate(Date(timeIntervalSince1970: 500))
        await waitForSidecar(captureID, "precision never landed") {
            $0.originalDate?.precision == .year
        }
        model.setBackdateEnabled(false)
        await waitForSidecar(captureID, "toggle-off left precision or date behind") {
            $0.originalDate == nil
        }
    }

    /// FIX 6 regression: `handlePhase` re-runs `enqueueEntryMetadataWrite` on every
    /// re-entry to `.recording`, including an interruption resume. Before the fix, that
    /// write carried `originalDate = nil` unconditionally whenever the live-capture
    /// toggle was off — even when the sidecar already held a backdate the detail screen
    /// wrote while the capture sat interrupted. Resume must leave that backdate alone.
    func testResumeWithBackdateOffDoesNotEraseAPreviouslyStoredBackdate() async throws {
        let recorder = ContextFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let captureID = try await startRecording(model, recorder)
        await waitForSidecarFile(captureID)

        // Stand in for a backdate set from the detail screen while interrupted —
        // the live model's own `backdateEnabled` never turned on for this capture.
        let url = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                             captureID: captureID))
        var stored = try EntryMetadataStore.read(url: url)
        stored.originalDate = PartialDate(year: 1970)
        try EntryMetadataStore.write(stored, url: url)

        // Re-enter `.recording` the way a resume does, without ever enabling the
        // live-capture backdate toggle.
        XCTAssertFalse(model.backdateEnabled)
        model.handlePhase()
        // Give the (no-op, by contract) write a chance to land and settle before
        // asserting nothing changed.
        try await Task.sleep(for: .milliseconds(200))
        let after = try EntryMetadataStore.read(url: url)
        XCTAssertEqual(after.originalDate, PartialDate(year: 1970),
                       "resume erased a backdate the live capture never set")
    }

    // MARK: Voice labels (T7 Mark Voices, issue #56)

    /// Mirrors `renameCurrentJournal`'s shape: the store call is the source of truth,
    /// and the model patches its own `journals` array in place — no rescan required for
    /// the change to be visible through `model.journals`.
    func testSetCurrentJournalVoiceLabelsPersistsAndPatchesInPlace() async throws {
        let model = makeModel()
        await model.bootstrap()
        let id = try XCTUnwrap(model.selectedJournalID)

        let succeeded = await model.setCurrentJournalVoiceLabels(["bn": "Grandpa", "ln": "Nico"])
        XCTAssertTrue(succeeded)

        XCTAssertEqual(model.journals.first(where: { $0.id == id })?.voiceLabels,
                       ["bn": "Grandpa", "ln": "Nico"],
                       "model.journals must reflect the new labels without a rescan")

        let onDisk = try await JournalStore(containerRoot: containerRoot).journal(id: id)
        XCTAssertEqual(onDisk?.voiceLabels, ["bn": "Grandpa", "ln": "Nico"],
                       "labels must be visible via journalStore.journal(id:)")
    }

    // MARK: Task A2 (issue #79, second half) — capture picker tracks sync-adopted journals

    /// The capture picker used to hold a bootstrap-once copy of `journals` that only a
    /// relaunch (or one of this model's own mutating intents) ever refreshed. A journal
    /// adopted from another device lands via `JournalStore.applySyncMerge` +
    /// `library.rescan()` (`SyncCoordinator.swift:120`), with nothing routing through
    /// `createJournal`/`renameCurrentJournal` — so the picker never saw it until the app
    /// relaunched. This pins the model-to-model refresh: no direct call on
    /// `CaptureScreenModel` at all, just the same rescan a background sync pull drives.
    func testCapturePickerTracksAJournalAdoptedFromSyncWithoutRelaunch() async throws {
        let model = makeModel()
        await model.bootstrap()
        let selected = try XCTUnwrap(model.selectedJournalID)

        let adopted = Journal(id: "SYNC-ADOPTED", name: "From Phone",
                              createdAt: Date(timeIntervalSince1970: 500_000))
        try await model.library.journalStore.applySyncMerge(adopted)

        // Exactly what a background sync ingest drives — never a direct call on
        // `CaptureScreenModel`.
        await model.library.rescan()

        XCTAssertTrue(model.journals.contains(where: { $0.id == "SYNC-ADOPTED" }),
                      "a sync-adopted journal must appear in the capture picker without relaunch")
        XCTAssertEqual(model.journals, model.journals.displayOrdered,
                      "the refreshed list must stay in display order (#79), never insertion order")

        // #67-class guard: a background sync rescan must never move the user's capture
        // target, even though the set of journals just changed under it.
        XCTAssertEqual(model.selectedJournalID, selected,
                       "a background sync rescan must not change the capture target")
    }

    /// Second half of the #67-class guarantee: the selected journal's OWN name changing
    /// remotely must update the label the picker shows, without touching selection.
    func testCapturePickerLabelUpdatesWhenSelectedJournalIsRenamedRemotely() async throws {
        let model = makeModel()
        await model.bootstrap()
        let selected = try XCTUnwrap(model.selectedJournalID)
        let original = try XCTUnwrap(model.journals.first(where: { $0.id == selected }))
        XCTAssertNotEqual(original.name, "Renamed On Phone")

        var renamed = original
        renamed.name = "Renamed On Phone"
        try await model.library.journalStore.applySyncMerge(renamed)
        await model.library.rescan()

        XCTAssertEqual(model.selectedJournalID, selected,
                       "a remote rename must not change which journal is selected")
        XCTAssertEqual(model.selectedJournalName, "Renamed On Phone",
                       "the picker label must reflect the remotely-renamed journal")
    }

    /// Task A2 review, Finding 1: `selectedJournalID`/`selectedJournalName` alone do
    /// NOT discriminate the #67-class guard from its removal — `JournalSelection.resolve`
    /// is idempotent whenever the stored id still resolves, so an unconditional
    /// re-resolve on every rescan would land on the same id either way. What the guard
    /// actually suppresses is `resolveBackdateForJournalChange()`/`syncActiveEntryMetadata()`
    /// firing on every rescan regardless of relevance — and
    /// `resolveBackdateForJournalChange()` re-anchors `backdateDate` off the carried
    /// `PartialDate` (noon for `.day` precision), which is a DIFFERENT instant than
    /// whatever exact `Date` the owner actually dialled unless it happened to already be
    /// noon. A background rescan silently nudging a live backdate is the same bug class
    /// as the m4/sync merge gate's F1 (a no-op visit re-stamping `span` with `now`).
    ///
    /// This drives a rescan that is IRRELEVANT to the current selection (a different
    /// journal is adopted from sync) and asserts the live backdate is untouched.
    func testIrrelevantBackgroundRescanDoesNotReanchorTheLiveBackdate() async throws {
        let model = makeModel()
        await model.bootstrap()
        let selected = try XCTUnwrap(model.selectedJournalID)

        model.setBackdateEnabled(true)
        // 500s past epoch is 00:08:20 UTC — nowhere near the noon `anchorDate()` would
        // reconstruct for `.day` precision, so a silent re-anchor is guaranteed visible.
        model.setBackdateDate(Date(timeIntervalSince1970: 500))
        let backdateBefore = model.backdateDate
        let precisionBefore = model.backdatePrecision

        let adopted = Journal(id: "OTHER-JOURNAL", name: "From Phone",
                              createdAt: Date(timeIntervalSince1970: 999_000))
        try await model.library.journalStore.applySyncMerge(adopted)
        await model.library.rescan()

        XCTAssertEqual(model.selectedJournalID, selected,
                       "sanity: this rescan must not touch selection at all")
        XCTAssertEqual(model.backdateDate, backdateBefore,
                       "an irrelevant rescan must not re-anchor the live backdate")
        XCTAssertEqual(model.backdatePrecision, precisionBefore)
    }

    /// Phase B (not yet built) will make deletion reachable; this pins the fallback
    /// ahead of it, per the plan. Standing in for "the selected id left the registry" by
    /// simulating what a sync rescan would show if the journal were gone — some OTHER
    /// journal must be adopted as the new selection, never a nil/dangling one, mirroring
    /// `JournalSelection.resolve`'s rule (the same one `resolveCurrentJournal()` uses at
    /// bootstrap).
    func testSelectionFallsBackWhenTheSelectedJournalLeavesTheRegistryOnRescan() async throws {
        let model = makeModel()
        await model.bootstrap()
        let original = try XCTUnwrap(model.selectedJournalID)

        // A second journal exists so the fallback has something real to land on.
        let survivor = try await model.createJournal(name: "Survivor")
        XCTAssertNotNil(survivor)
        model.selectJournal(original)
        XCTAssertEqual(model.selectedJournalID, original)

        // Simulate the selected journal vanishing from the registry (Phase B's shape —
        // no code today can produce this, so it is forced directly at the store).
        var registry = try JournalStore.load(url: journalsURL)
        registry.journals.removeAll { $0.id == original }
        try JournalStore.encode(registry).write(to: journalsURL)
        await model.library.rescan()

        XCTAssertNotEqual(model.selectedJournalID, original,
                          "a selection whose journal left the registry must not be kept")
        XCTAssertTrue(model.journals.contains(where: { $0.id == model.selectedJournalID }),
                      "the fallback selection must resolve to a journal that still exists")
    }

    func testSetCurrentJournalVoiceLabelsFailureReturnsFalse() async throws {
        let model = makeModel()
        await model.bootstrap()
        let id = try XCTUnwrap(model.selectedJournalID)
        let before = model.journals.first(where: { $0.id == id })?.voiceLabels

        // `AtomicFile.replace` writes `journals.json.part` beside the target and renames
        // it in — both need the *directory* writable, so the target file's own
        // permissions are irrelevant here.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: containerRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containerRoot.path)
        }

        let succeeded = await model.setCurrentJournalVoiceLabels(["bn": "Grandpa"])
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.journals.first(where: { $0.id == id })?.voiceLabels, before,
                       "a failed write must not patch the in-memory journal either")
    }
}
