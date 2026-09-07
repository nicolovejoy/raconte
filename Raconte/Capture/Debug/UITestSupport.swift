#if DEBUG
import Foundation

/// UI-test composition root. Active only when `RACONTE_UITEST_ID` is in the launch
/// environment (set by RaconteUITests): synthetic engine + no-op session over an
/// id-keyed captures root, so UI flows run with no microphone, no TCC prompt, and
/// per-test isolation. A relaunch with the same id sees the same disk — the
/// recovery-flow tests rely on that.
/// Where the harness's id-keyed tree lives, factored out so `LibraryScreenModel` (M3 T4)
/// points at the same one `CaptureScreenModel`'s harness uses — two roots for one
/// `RACONTE_UITEST_ID` would make the library scan an empty directory next to the one the
/// capture screen is actually writing.
///
/// The id keys a **container** root with `captures/` beneath it, the same layout
/// `AppContainer` defines. The harness used to key the captures root itself and then pin
/// `journals.json` *inside* it, which contradicted `AppContainer`'s "never inside
/// captures/" rule and left the harness testing a shape no shipping build has. With the
/// container keyed instead, `AppContainer.containerRoot(capturesRoot:)` derives the right
/// place on its own and nothing needs pinning.
enum UITestHarnessRoot {
    @MainActor static func containerRoot(id: String) -> URL {
        CaptureScreenModel.defaultCapturesRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("uitest-\(id)", isDirectory: true)
    }

    @MainActor static func capturesRoot(id: String) -> URL {
        let root = AppContainer.capturesRoot(containerRoot: containerRoot(id: id))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// A pre-made entry with a real revision chain, for the editor's UI test (T7 Task 4.6).
///
/// The synthetic harness records real audio but installs `NoOpPCMSink` as its tee branch, so
/// nothing is ever transcribed under UI test and every recorded entry is
/// `.readOnlyNoTranscript` — an editor flow cannot be built out of one. Seeding a canonical
/// revision directly is the smallest honest fixture: `promoteIfNeeded` sees a non-empty
/// chain and skips (`.skippedAlreadyPromoted`, so no `final/recording.m4a` is needed), the
/// scanner shows a row because a non-empty `transcript/` is durable content, and playback
/// degrades to `.none` exactly as it already does for a capture with no audio.
///
/// Env-gated (`RACONTE_UITEST_SEED_ENTRY`) so every existing capture flow is untouched, and
/// idempotent so a relaunch on the same id does not append a second revision.
enum UITestEntrySeed {
    static let captureID = "01KYX77KK5QM15915EZBVXTQZ4"
    static let text = "the machine heard these words"

    static func seedIfRequested(capturesRoot: URL) {
        guard ProcessInfo.processInfo.environment["RACONTE_UITEST_SEED_ENTRY"] != nil else { return }
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: captureID)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let revision = TranscriptRevision(id: "01KYX77KK5QM15915EZBVXTQZ5",
                                          source: .machineLive,
                                          createdAt: Date(),
                                          spans: [TranscriptSpan(text: text, anchor: .none)])
        try? FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        guard let data = try? CaptureCoding.encoder().encode(revision) else { return }
        try? data.write(to: url)
    }
}

/// A pre-made blank entry (mirrors `BlankEntryMinter`'s finalized-from-creation manifest)
/// WITH one real, ImageIO-decodable image already attached — image capture plan Task 7,
/// for the library-row-thumbnail and remove-round-trip UI tests. Seeded on disk directly,
/// synchronously, rather than through `ImageStore.addImage` (an actor method): this runs
/// from `LibraryScreenModel.live()`, itself synchronous, so there is no `await` to spend
/// here — same reasoning `UITestEntrySeed`/`UITestVoiceMarkingSeed` give for writing their
/// fixtures by hand instead of going through the real (async) stores. Hand-replicates
/// `ImageStore`'s own crash-ordering (orig, then sidecar, then thumbnail) even though a
/// seed never crashes mid-write — consistency with the real writer, not defensiveness.
///
/// Env-gated (`RACONTE_UITEST_SEED_IMAGE_ENTRY`) and idempotent, same shape as the other
/// two seeds. A separate captureID from every other seed's — the library scan under this
/// harness sees every seeded entry in the SAME container when more than one env var is
/// set, and this fixture's whole point is being the library's only image-bearing row.
enum UITestImageSeed {
    static let captureID = "01KYX77KK5QM15915EZBVXTQZ3"
    static let imageID = "01KYX77KK5QM15915EZBVXTQY9"

    /// A 1×1 red PNG — the smallest fixture ImageIO will actually decode (pixel
    /// dimensions and all), so `ImageThumbnailer.generate`/`EntryDetailView`'s
    /// `AsyncCaptureImage` see the same real bytes a genuine capture would produce.
    private static let onePixelRedPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    static func seedIfRequested(capturesRoot: URL) {
        guard ProcessInfo.processInfo.environment["RACONTE_UITEST_SEED_IMAGE_ENTRY"] != nil else { return }
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let manifestURL = SegmentLayout.manifestURL(captureDirectory: captureDirectory)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        guard let data = Data(base64Encoded: onePixelRedPNGBase64) else { return }

        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            let manifestData = try CaptureCoding.encoder().encode(
                BlankEntryMinter.manifest(captureID: captureID, createdAt: Date()))
            try AtomicFile.replace(at: manifestURL, writing: manifestData)

            let sidecar = ImageSidecar(id: imageID, originalExtension: "png", mime: "image/png",
                                       bytes: data.count, sha256: ImageStore.sha256Hex(data),
                                       width: 1, height: 1, capturedAt: nil, addedAt: Date())
            try ImageStore.writeOriginal(data, captureDirectory: captureDirectory, imageID: imageID, ext: "png")
            try ImageStore.writeSidecar(sidecar, captureDirectory: captureDirectory)
            if let thumbnail = ImageThumbnailer.generate(from: data) {
                let thumbnailsDirectory =
                    SegmentLayout.imageThumbnailsDirectory(captureDirectory: captureDirectory)
                try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
                try AtomicFile.replace(
                    at: SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: imageID),
                    writing: thumbnail)
            }
        } catch {
            // Best-effort, matching the other seeds' `try?` stance: a failed seed just
            // means the UI test that depends on it fails loudly downstream, not here.
        }
    }
}

/// A pre-made entry with real frame-bounded spans PLUS an existing `markers.jsonl`, for
/// the mark-voices screen's UI test (T7 Mark Voices, issue #56, Task 6 — was the old
/// marker-correction screen's fixture, `UITestMarkerCorrectionSeed`, renamed to match;
/// same env gate so CI wiring is untouched). `UITestEntrySeed`'s single span is
/// `.none`-anchored (no frames at all — it never needed any for the editor), so it
/// cannot exercise anything here: every word in it is non-placeable, and there is
/// nothing for a voice marker to snap against. A SEPARATE capture id from
/// `UITestEntrySeed` rather than changing the shared fixture — the editor's own UI
/// tests assert the exact seeded text and span shape.
///
/// Three separate spans (`.inherited`, real bounds — the same shape promotion gives a
/// capture with no runs, design §4.2) rather than one multi-run span, so each word is
/// independently placeable. One pre-existing raw tap, a `.voice` opener (bn) at frame 0,
/// so the seeded entry already renders `voiceMarking.paragraph.0.bn` for the flip test.
///
/// `unmarkedCaptureID` is a SECOND seeded entry, same three words, with NO `markers
/// .jsonl` at all — the "voices unmarked" case (`testMarkVoicesOnAnUnmarkedEntryOffers
/// MarkingAndWrites`), which `hasAnyVoiceMarker == false` and `governingVoice`'s
/// gap-case rule both need a genuinely marker-free fixture to exercise. `mergeCaptureID`
/// is a THIRD, documented at its declaration below.
enum UITestVoiceMarkingSeed {
    static let captureID = "01KYX77KK5QM15915EZBVXTQZ6"
    static let unmarkedCaptureID = "01KYX77KK5QM15915EZBVXTQZ2"
    /// A THIRD seeded entry (gate-review fix #1, the drag-path UI test): six words,
    /// two voices already declared (bn at word 0, ln at word 3) so opening the screen
    /// shows two paragraphs — flipping paragraph 0 into paragraph 1's voice (ln) then
    /// merges them into ONE block on reload, the shape needed to drag a range WITHIN a
    /// merged block rather than a freshly-opened one. Tail digit `0` (not `1`/`2`, both
    /// already used for the two 3-word fixtures below) sorts LAST among the three under
    /// `EntryListItem.sortedByEffectiveDate`'s captureID-descending tiebreak, so it
    /// always lands at library row 2 and never disturbs the existing row 0/1 assumptions.
    static let mergeCaptureID = "01KYX77KK5QM15915EZBVXTQZ0"
    static let words: [(text: String, start: Int64, end: Int64)] = [
        ("one", 0, 10_000),
        ("two", 20_000, 30_000),
        ("three", 40_000, 50_000),
    ]
    /// #103 regression test (`EntryPagingUITests`): distinct from `words` on purpose.
    /// `captureID` and `unmarkedCaptureID` are adjacent rows in the marker seed's
    /// deterministic order, and without this the two entries' transcripts would read
    /// identically ("one two three" on both) — a test asserting "the transcript
    /// changed after paging/re-selecting" would pass vacuously (or fail to catch a
    /// real staleness bug) if both entries said the same thing.
    static let unmarkedWords: [(text: String, start: Int64, end: Int64)] = [
        ("alpha", 0, 10_000),
        ("beta", 20_000, 30_000),
        ("gamma", 40_000, 50_000),
    ]
    static let mergeWords: [(text: String, start: Int64, end: Int64)] = [
        ("one", 0, 10_000),
        ("two", 20_000, 30_000),
        ("three", 40_000, 50_000),
        ("four", 60_000, 70_000),
        ("five", 80_000, 90_000),
        ("six", 100_000, 110_000),
    ]

    static func seedIfRequested(capturesRoot: URL) {
        guard ProcessInfo.processInfo.environment["RACONTE_UITEST_SEED_MARKER_ENTRY"] != nil else { return }
        seedMarked(capturesRoot: capturesRoot)
        seedUnmarked(capturesRoot: capturesRoot)
        seedMerge(capturesRoot: capturesRoot)
    }

    private static func seedMarked(capturesRoot: URL) {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: captureID)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        writeSpans(captureDirectory: captureDirectory, revisionID: "01KYX77KK5QM15915EZBVXTQZ7")

        let writer = MarkerLogWriter(captureDirectory: captureDirectory)
        try? writer.open()
        try? writer.append(StructureMarker(seq: 0, frame: 0, kind: .voice,
                                           voice: StructureMarker.Voice.bigNico))
        try? writer.close()
    }

    private static func seedUnmarked(capturesRoot: URL) {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: unmarkedCaptureID)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        writeSpans(captureDirectory: captureDirectory, revisionID: "01KYX77KK5QM15915EZBVXTQZ1",
                  words: unmarkedWords)
        // No markers.jsonl written at all — the .absent case.
    }

    /// bn at word 0, ln at word 3 (`mergeWords`' index 3, "four") — two paragraphs
    /// (words 0-2 bn, words 3-5 ln) already on open, so `testDragMarksARangeWithinAMerged
    /// Block` can flip paragraph 0 into ln and get one 6-word merged block before ever
    /// touching the drag gesture under test.
    private static func seedMerge(capturesRoot: URL) {
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: mergeCaptureID)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        writeSpans(captureDirectory: captureDirectory, revisionID: "01KYX77KK5QM15915EZBVXTQZ8",
                  words: mergeWords)

        let writer = MarkerLogWriter(captureDirectory: captureDirectory)
        try? writer.open()
        try? writer.append(StructureMarker(seq: 0, frame: 0, kind: .voice,
                                           voice: StructureMarker.Voice.bigNico))
        try? writer.append(StructureMarker(seq: 1, frame: mergeWords[3].start, kind: .voice,
                                           voice: StructureMarker.Voice.littleNico))
        try? writer.close()
    }

    private static func writeSpans(captureDirectory: URL, revisionID: String,
                                   words: [(text: String, start: Int64, end: Int64)] = words) {
        let spans = words.map { word in
            TranscriptSpan(text: word.text, anchor: .inherited, frameStart: word.start, frameEnd: word.end)
        }
        let revision = TranscriptRevision(id: revisionID, source: .machineLive, createdAt: Date(), spans: spans)
        try? FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        guard let data = try? CaptureCoding.encoder().encode(revision) else { return }
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0)
        try? data.write(to: url)
    }
}

/// A "complete" entry (a real, finalized manifest — the same shape `BlankEntryMinter`
/// mints) whose `entry.json` sidecar is present but is not valid JSON at all. Feeds
/// #81's repair UI test (Task 6): `LibraryScreenModel.unreadableEntries`/
/// `quarantineUnreadable(captureID:)` need a fixture whose sidecar EXISTS and fails to
/// parse, which is a different shape from an ABSENT sidecar (`EntryMetadata.defaults`,
/// no degradation at all — see `EntryMetadataStore.read`). `journalID: nil` on the
/// `BlankEntryMinter.create` call is deliberate: that path only writes `entry.json`
/// when a journal is given, leaving this fixture free to write the file's bytes itself.
///
/// Env-gated (`RACONTE_UITEST_SEED_UNREADABLE_ENTRY`) and idempotent, same shape as the
/// other seeds — the idempotency guard checks the LAST file this seed writes
/// (`entry.json`), matching `UITestEntrySeed`'s guard on its own last-written file.
enum UITestUnreadableEntrySeed {
    static let captureID = "01KYX77KK5QM15915EZBVXTQZC"

    static func seedIfRequested(capturesRoot: URL) {
        guard ProcessInfo.processInfo.environment["RACONTE_UITEST_SEED_UNREADABLE_ENTRY"] != nil else { return }
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                              captureID: captureID)
        let entryURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        guard !FileManager.default.fileExists(atPath: entryURL.path) else { return }
        guard BlankEntryMinter.create(capturesRoot: capturesRoot, journalID: nil,
                                      captureID: captureID) != nil else { return }
        try? Data("not json".utf8).write(to: entryURL)
    }
}

extension CaptureScreenModel {
    /// `library` is threaded through (M3 T4.5) rather than dropped: `ContentView`'s
    /// `navigationDestination(for: LibraryDestination.self)` reads its OWN
    /// `LibraryScreenModel.item(_:)`, which only ever sees rows that instance itself
    /// scanned — if the harness quietly built a second, disconnected `LibraryScreenModel`
    /// here, a tap on a capture-screen recent row would push a detail screen for an id
    /// the caller's library never scanned, and render nothing.
    @MainActor static func uiTestHarness(library: LibraryScreenModel) -> CaptureScreenModel? {
        guard let id = ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"] else { return nil }
        let root = UITestHarnessRoot.capturesRoot(id: id)
        return CaptureScreenModel(
            capturesRoot: root,
            makeSession: { UITestSessionController() },
            makeRecorder: { SyntheticRecorder() },
            encoder: AVAssetWriterAudioEncoder(),
            // A second branch on every capture, so the simulator suite drives
            // record→finalize→relaunch over a two-branch tee rather than the
            // one-branch shape no shipping build will use.
            makeSecondarySink: { _ in NoOpPCMSink() },
            // No `journalsContainerRoot` override: the id keys the container, so the
            // production derivation lands `journals.json` beside `captures/` — isolated
            // per test id and the same layout the shipping app has.
            library: library)
    }
}

/// A tee branch that does nothing. Exists so the tested path has the same shape
/// as the shipping path.
final class NoOpPCMSink: PCMSink {
    nonisolated func receive(_ chunk: PCMChunk) {}
}

/// Grants permission and activates unconditionally; never emits a session event.
final class UITestSessionController: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    init() { (events, continuation) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

/// Engine stand-in generating a continuous 440 Hz sine (canonical mono Float32) in
/// 100 ms chunks, so capture/finalize/playback run end-to-end with real bytes and a
/// non-silent verify — no audio hardware involved.
final class SyntheticRecorder: EngineRecording, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var captureFormatDescriptor: AudioFormatDescriptor?
    private var task: Task<Void, Never>?

    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws {
        guard !isRunning else { return }
        let rate = canonical?.sampleRate ?? 48_000
        captureFormatDescriptor = AudioFormatDescriptor(
            sampleRate: rate, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)
        isRunning = true
        task = Task.detached {
            let chunkFrames = rate / 10
            var frame = 0
            while !Task.isCancelled {
                var samples = [Float](repeating: 0, count: chunkFrames)
                for i in 0..<chunkFrames {
                    samples[i] = Float(sin(2 * Double.pi * 440 * Double(frame + i) / Double(rate)) * 0.5)
                }
                frame += chunkFrames
                let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                sink.receive(PCMChunk(data: data, frameCount: .init(chunkFrames),
                                      sampleRate: Double(rate)))
                onLevel?(0.35)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
#endif
