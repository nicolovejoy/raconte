import XCTest
import AVFAudio
@testable import Raconte

private final class MultiVoiceFakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

/// Mirrors `JournalCaptureContextTests.ContextFakeRecorder`: retains the sink so the test
/// can push frames through the tee — which is what makes the frame clock (step 1) real.
private final class MultiVoiceFakeRecorder: EngineRecording, @unchecked Sendable {
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

/// T6 §14 step 4 — the multi-voice toggle's per-journal, durable carry-over.
///
/// **Deliberately auto-enabling**, which inverts `BackdateCarryOverTests`'
/// `testCarryOverNeverAutoEnablesTheToggle`. Recorded as a divergence in the design doc
/// (§2): a wrong voice attribute is visible and editable in the T7 editor, where a wrong
/// backdate is a quiet data error. Do not "fix" this to match the backdate rule.
@MainActor
final class MultiVoiceCarryOverTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var journalsURL: URL { AppContainer.journalsURL(containerRoot: containerRoot) }
    private var prefs: InMemoryJournalPreferenceStore!

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    private let idC = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiVoiceCarryOver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        prefs = InMemoryJournalPreferenceStore()
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    // MARK: fixtures

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    /// One scannable capture. Mirrors `LibraryScreenModelTests.writeCapture`, extended to
    /// take a whole `EntryMetadata` — a bare `entry.json` is NOT enough to produce a row
    /// (`LibraryScanner.holdsSomethingToShow` wants durable content or segment frames),
    /// so the pcm + manifest are load-bearing here, not decoration.
    private func writeCapture(_ id: String,
                              capturedAt: Double,
                              metadata: EntryMetadata,
                              frames: Int = 48_000) throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: frames * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))

        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: capturedAt)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
        try EntryMetadataStore.write(
            metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: journalsURL)
    }

    private func journal(_ id: String, _ name: String) -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    /// Built over the SAME roots as the fixtures — `CaptureScreenModel` asserts its
    /// library's captures root matches its own.
    private func makeModel(recorder: MultiVoiceFakeRecorder = MultiVoiceFakeRecorder())
    -> CaptureScreenModel {
        let library = LibraryScreenModel(capturesRoot: capturesRoot,
                                         journalsContainerRoot: containerRoot)
        return CaptureScreenModel(
            capturesRoot: capturesRoot,
            makeSession: { MultiVoiceFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            journalsContainerRoot: containerRoot,
            journalPreferenceStore: prefs,
            library: library)
    }

    /// The view's `onChange(of: phase)` relay — nothing calls it in a test but the test.
    private func startRecording(_ model: CaptureScreenModel,
                                _ recorder: MultiVoiceFakeRecorder) async throws -> String {
        await model.record()
        recorder.feed(frames: 480)
        model.handlePhase()
        return try XCTUnwrap(model.coordinator.activeCaptureID)
    }

    private func waitForSidecar(_ captureID: String,
                                timeout: TimeInterval = 5,
                                _ message: String,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ predicate: (EntryMetadata) -> Bool) async {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID))
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

    private func waitForSidecarFile(_ captureID: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() > deadline {
                return XCTFail("entry.json was never written", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: carry-over off disk

    /// The divergence, asserted: no user action, and the toggle comes up ON because the
    /// journal's most recent entry was multi-voice. The inverse of
    /// `BackdateCarryOverTests.testCarryOverNeverAutoEnablesTheToggle`, on purpose.
    func testMultiVoiceAutoEnablesFromTheJournalsMostRecentEntry() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, metadata: EntryMetadata(journalID: "J1",
                                                                        multiVoice: true))
        let model = makeModel()
        await model.bootstrap()

        XCTAssertEqual(model.selectedJournalID, "J1")
        XCTAssertTrue(model.multiVoiceEnabled,
                      "carry-over must auto-enable from the journal's latest entry")
    }

    func testCarryOverDoesNotCrossJournals() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "1991")])
        try writeCapture(idA, capturedAt: 1_000, metadata: EntryMetadata(journalID: "J1",
                                                                        multiVoice: true))
        try writeCapture(idB, capturedAt: 2_000, metadata: EntryMetadata(journalID: "J2"))

        let model = makeModel()
        await model.bootstrap()
        model.selectJournal("J1")
        XCTAssertTrue(model.multiVoiceEnabled)

        model.selectJournal("J2")
        XCTAssertFalse(model.multiVoiceEnabled, "J2's own latest entry is single-voice")
    }

    /// A journal with no entries at all has nothing on disk to read, so only the
    /// in-session override map can hold the choice across a switch away and back.
    func testCarryOverSurvivesJournalSwitchAndBack() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "1991")])

        let model = makeModel()
        await model.bootstrap()
        model.selectJournal("J1")
        XCTAssertFalse(model.multiVoiceEnabled)

        model.setMultiVoiceEnabled(true)
        XCTAssertTrue(model.multiVoiceEnabled)

        model.selectJournal("J2")
        XCTAssertFalse(model.multiVoiceEnabled, "the choice is J1's, not the app's")

        model.selectJournal("J1")
        XCTAssertTrue(model.multiVoiceEnabled, "switching back restores J1's own choice")
    }

    /// Durable, not merely in-session: a fresh model over the same container reads the
    /// journal's state back off disk, with no refresh call anywhere.
    func testCarryOverIsDurableAcrossRelaunch() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, metadata: EntryMetadata(journalID: "J1",
                                                                        multiVoice: true))

        let first = makeModel()
        await first.bootstrap()
        XCTAssertTrue(first.multiVoiceEnabled)
        // An in-session override is in-session only — it must not be what the next
        // launch reads.
        first.setMultiVoiceEnabled(false)
        XCTAssertFalse(first.multiVoiceEnabled)

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertTrue(relaunched.multiVoiceEnabled,
                      "the disk value, not the previous session's override")
    }

    /// `mostRecentlyCaptured` orders by `capturedAt` descending — the newest entry decides,
    /// not "any entry ever was multi-voice".
    func testMostRecentEntryDecidesWhenEntriesDisagree() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, metadata: EntryMetadata(journalID: "J1",
                                                                        multiVoice: true))
        try writeCapture(idB, capturedAt: 2_000, metadata: EntryMetadata(journalID: "J1"))

        let model = makeModel()
        await model.bootstrap()
        XCTAssertFalse(model.multiVoiceEnabled, "the newer, single-voice entry decides")
        XCTAssertFalse(model.library.lastMultiVoice(forJournal: "J1"))

        // And the other way round, to prove the ordering rather than a constant.
        try writeCapture(idC, capturedAt: 3_000, metadata: EntryMetadata(journalID: "J1",
                                                                        multiVoice: true))
        await model.library.rescan()
        XCTAssertTrue(model.multiVoiceEnabled)
    }

    // MARK: the recording path

    func testRecordingWritesMultiVoiceToTheSidecar() async throws {
        try writeJournals([journal("J1", "1987")])

        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.setMultiVoiceEnabled(true)

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "multiVoice never reached entry.json") {
            $0.multiVoice && $0.journalID == "J1"
        }
        await model.done()

        // Toggled off, the key is absent entirely — the sidecar-shape convention.
        let otherRecorder = MultiVoiceFakeRecorder()
        let second = makeModel(recorder: otherRecorder)
        await second.bootstrap()
        second.setMultiVoiceEnabled(false)

        let secondID = try await startRecording(second, otherRecorder)
        await waitForSidecar(secondID, "the second capture never filed") {
            $0.journalID == "J1"
        }
        let text = try String(
            contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(secondID)),
            encoding: .utf8)
        XCTAssertFalse(text.contains("multiVoice"), "single-voice entries write no key: \(text)")
        XCTAssertFalse(try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(secondID))).multiVoice)
        await second.done()
    }

    /// The frame-0 `bn` opener (owner decision 4), driven from the screen model rather
    /// than the coordinator directly — this is the seam the toggle actually controls.
    func testMultiVoiceCaptureOpensWithFrameZeroBigNico() async throws {
        try writeJournals([journal("J1", "1987")])

        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.setMultiVoiceEnabled(true)

        let captureID = try await startRecording(model, recorder)
        let loaded = MarkerLogReader.load(captureDirectory: captureDir(captureID))
        // Field-wise, not full-struct equality: `MarkerLogWriter.append` now stamps `at`
        // from the coordinator's real (unfixed here) clock (M4 T1), so a literal
        // comparison can never match. `at != nil` is checked separately below.
        XCTAssertEqual(loaded.markers.map(\.seq), [0])
        XCTAssertEqual(loaded.markers.map(\.frame), [0])
        XCTAssertEqual(loaded.markers.map(\.kind), [.voice])
        XCTAssertEqual(loaded.markers.map(\.voice), [StructureMarker.Voice.bigNico])
        XCTAssertNotNil(loaded.markers.first?.at, "M4 T1: every append is stamped")
        XCTAssertEqual(model.coordinator.currentVoice, StructureMarker.Voice.bigNico)
        await model.done()

        // Single-voice: no opener, and therefore no `transcript/` at all (the lazy-open
        // rule — an eager open would make a mis-tap's directory undeletable).
        let otherRecorder = MultiVoiceFakeRecorder()
        let second = makeModel(recorder: otherRecorder)
        await second.bootstrap()
        second.setMultiVoiceEnabled(false)

        let secondID = try await startRecording(second, otherRecorder)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptDirectory(
                captureDirectory: captureDir(secondID)).path),
            "a single-voice capture must not create transcript/")
        XCTAssertEqual(MarkerLogReader.load(captureDirectory: captureDir(secondID)).source,
                       .absent)
        await second.done()
    }

    /// Carry-over chooses the NEXT capture's mode; it never mutates a running one.
    /// `selectJournal` mid-capture runs `syncActiveEntryMetadata`, which shares the
    /// sidecar writer with `handlePhase` — a live read of the computed toggle inside that
    /// closure would re-derive the *new* journal's carry-over and rewrite the running
    /// entry out from under the markers already on disk.
    func testMidCaptureJournalSwitchDoesNotRewriteMultiVoice() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "1991")])
        try writeCapture(idB, capturedAt: 2_000, metadata: EntryMetadata(journalID: "J2"))

        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.selectJournal("J1")
        model.setMultiVoiceEnabled(true)
        XCTAssertFalse(model.library.lastMultiVoice(forJournal: "J2"),
                       "J2 must be the single-voice journal for this test to mean anything")

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "multiVoice never landed") { $0.multiVoice }

        model.selectJournal("J2")
        await waitForSidecar(captureID, "the journal switch never reached the live sidecar") {
            $0.journalID == "J2"
        }
        // Let any straggler on the write chain land before asserting nothing changed.
        try await Task.sleep(for: .milliseconds(200))
        let after = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID)))
        XCTAssertTrue(after.multiVoice,
                      "a mid-capture journal switch rewrote the running entry's multiVoice")
        XCTAssertEqual(after.journalID, "J2")
        await waitForSidecarFile(captureID)
        await model.done()
    }
}
