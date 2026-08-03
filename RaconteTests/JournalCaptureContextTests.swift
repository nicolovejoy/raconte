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
        let last = Date(timeIntervalSince1970: 1_000)

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
            $0.originalDate == Date(timeIntervalSince1970: 500)
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
            $0.originalDate == Date(timeIntervalSince1970: 700)
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
}
