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

/// #118 §4 — a reading becomes two-voice by MARKING a voice, not by arming a toggle
/// first. The first live mark writes the frame-0 opener (idempotent), the tap's own
/// marker, and `multiVoice: true` to the sidecar. A reading with no voice mark writes
/// none of those.
@MainActor
final class MultiVoiceMarkingTests: XCTestCase {

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

    // MARK: no mark → single voice

    /// The sidecar-shape convention: a single-voice entry writes no `multiVoice` key at
    /// all, and no `transcript/` directory (the lazy-open rule — an eager open would make
    /// a mis-tap's directory undeletable).
    func testRecordingWithoutAVoiceMarkIsSingleVoice() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "the capture never filed") { $0.journalID == "J1" }
        await model.done()

        let text = try String(
            contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID)),
            encoding: .utf8)
        XCTAssertFalse(text.contains("multiVoice"), "single-voice entries write no key: \(text)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptDirectory(captureDirectory: captureDir(captureID)).path),
            "a single-voice capture must not create transcript/")
        XCTAssertEqual(MarkerLogReader.load(captureDirectory: captureDir(captureID)).source, .absent)
    }

    // MARK: the first mark

    /// One tap, three effects: the frame-0 `bn` opener, the tap's own marker at the
    /// current frame, and `multiVoice: true` in the sidecar. Frame order == seq order,
    /// so the opener is appended BEFORE the tap.
    func testFirstVoiceMarkWritesOpenerThenMarkAndSetsMultiVoice() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)          // advance the clock so the tap is not at 0
        model.markVoice(StructureMarker.Voice.littleNico)

        await waitForSidecar(captureID, "multiVoice never reached entry.json") { $0.multiVoice }

        let loaded = MarkerLogReader.load(captureDirectory: captureDir(captureID))
        XCTAssertEqual(loaded.markers.map(\.seq), [0, 1])
        XCTAssertEqual(loaded.markers.map(\.kind), [.voice, .voice])
        XCTAssertEqual(loaded.markers.map(\.voice),
                       [StructureMarker.Voice.bigNico, StructureMarker.Voice.littleNico])
        XCTAssertEqual(loaded.markers.first?.frame, 0, "the opener is at the literal frame 0")
        XCTAssertGreaterThan(loaded.markers[1].frame, 0, "the tap lands on the live clock")
        XCTAssertEqual(model.coordinator.currentVoice, StructureMarker.Voice.littleNico)
        await model.done()
    }

    /// The opener is once per capture — `CaptureCoordinator.didWriteOpeningVoice` — so
    /// a second tap appends exactly one marker, and the sidecar is not rewritten.
    func testSecondVoiceMarkDoesNotDuplicateTheOpener() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.littleNico)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.bigNico)
        await waitForSidecar(captureID, "multiVoice never landed") { $0.multiVoice }

        let loaded = MarkerLogReader.load(captureDirectory: captureDir(captureID))
        XCTAssertEqual(loaded.markers.count, 3, "opener + two taps, no second opener")
        XCTAssertEqual(loaded.markers.filter { $0.frame == 0 }.count, 1)
        await model.done()
    }

    /// Marking is live-only: outside `.recording` there is no frame to anchor to, and the
    /// model must not write `multiVoice` for a capture that has none.
    func testMarkVoiceOutsideRecordingIsANoOp() async throws {
        try writeJournals([journal("J1", "1987")])
        let model = makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.coordinator.phase, .idle)

        model.markVoice(StructureMarker.Voice.littleNico)

        XCTAssertNil(model.coordinator.currentVoice, "an idle tap must not change the voice")
        XCTAssertEqual(model.coordinator.markerCount, 0)
    }

    // MARK: sidecar sharing

    /// A mid-capture journal switch runs `syncActiveEntryMetadata`, which shares the
    /// sidecar writer with the mark path. It must move the entry without touching
    /// `multiVoice` (nil-defaulted parameter — "leave it alone").
    func testMidCaptureJournalSwitchKeepsMultiVoice() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "1991")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.selectJournal("J1")

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.littleNico)
        await waitForSidecar(captureID, "multiVoice never landed") { $0.multiVoice }

        model.selectJournal("J2")
        await waitForSidecar(captureID, "the journal switch never reached the live sidecar") {
            $0.journalID == "J2"
        }
        try await Task.sleep(for: .milliseconds(200))
        let after = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID)))
        XCTAssertTrue(after.multiVoice, "a mid-capture journal switch rewrote multiVoice")
        XCTAssertEqual(after.journalID, "J2")
        await model.done()
    }
}
