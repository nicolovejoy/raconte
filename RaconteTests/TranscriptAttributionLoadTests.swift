import XCTest
@testable import Raconte

/// T7 plan step 2: the read-path wire — `EntryTranscriptLoader` → `MarkerLogReader` →
/// `MarkerSnapping` → `TranscriptAttribution` — exercised through real disk fixtures,
/// the way `LibraryScreenModelTests` exercises the transcript-only path it extends.
///
/// Marker-source rules under test (design §7, non-negotiable): `.absent` and
/// `.unreadable` both mean *no voices assigned*, never "single voice" — and the
/// library scanner must never pay for a marker-log read at all.
@MainActor
final class TranscriptAttributionLoadTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptAttributionLoad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    /// A manifest on disk (no journal, no backdate) — enough for `model.transcript(for:)`
    /// to find a capture-frame format and, in step 2, a sample rate.
    private func writeManifest(_ id: String, sampleRate: Int = 48_000) throws {
        let format = AudioFormatDescriptor(sampleRate: sampleRate, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeLiveTranscript(_ id: String,
                                     _ records: [(text: String, start: Int64, end: Int64)]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(id))
        try writer.open()
        for record in records {
            try writer.append(TranscriptRecord(seq: 0, text: record.text,
                                               captureFrameStart: record.start,
                                               captureFrameEnd: record.end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()
    }

    private func writeMarkers(_ id: String, _ markers: [StructureMarker]) throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir(id))
        try writer.open()
        for marker in markers {
            try writer.append(marker)
        }
        try writer.close()
    }

    private func markerLogURL(_ id: String) -> URL {
        SegmentLayout.markerLogURL(captureDirectory: captureDir(id))
    }

    // MARK: - T7 Task 5 fixture helpers (promote + edit through the real store)

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    /// `TranscriptRevisionStore.promoteIfNeeded` requires durable audio to exist before
    /// it will promote `live.jsonl` into revision zero — content doesn't matter, only
    /// that the file is present (mirrors `TranscriptPromotionCanonicalTests`).
    private func writeFinalAudio(_ id: String) throws {
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
    }

    /// Promotes `live.jsonl` into revision zero, then edits it via the REAL draft
    /// lifecycle (`writeDraft` + `closeDraft`, which runs the real `TranscriptSplice`) —
    /// so the current revision is genuinely `.userEdit`, not a hand-built fixture. This
    /// is the exact shape the gate at `EntryTranscript.swift`'s `load` used to block.
    @discardableResult
    private func promoteThenEdit(_ id: String, editedText: String) async throws -> String? {
        try writeFinalAudio(id)
        _ = await store().promoteIfNeeded(captureID: id)
        try await store().writeDraft(captureID: id, text: editedText, now: Date(timeIntervalSince1970: 2_000))
        return try await store().closeDraft(captureID: id, reason: .sessionEnd, now: Date(timeIntervalSince1970: 2_100))
    }

    // MARK: - End-to-end through the detail screen

    func testDetailTranscriptAttributesVoicesFromTheMarkerLog() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: StructureMarker.Voice.littleNico),
        ])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.voice), [StructureMarker.Voice.bigNico, StructureMarker.Voice.littleNico])
        XCTAssertEqual(paragraphs.map(\.text), ["intro words", "reply words"])
        XCTAssertEqual(transcript.text, "intro words reply words", "text is unaffected by attribution")
    }

    // MARK: - Marker-source rules (design §7)

    func testEntryWithNoMarkerFileHasNilParagraphsAndUnchangedText() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        // No markers.jsonl written at all — the common case (single-voice capture).

        let transcript = await model().transcript(for: idA)

        XCTAssertNil(transcript.paragraphs, "absent marker log must never render as single-voice")
        XCTAssertEqual(transcript.text, "hello there")
    }

    func testUnreadableMarkerLogAssignsNoVoices() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])

        let logURL = markerLogURL(idA)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let transcript = await model().transcript(for: idA)

        XCTAssertNil(transcript.paragraphs,
                     "an unreadable log must never be read as 'single voice, nothing to see'")
        XCTAssertEqual(transcript.text, "hello there", "the transcript itself is untouched")
    }

    /// The split is attributable to the marker, not to the transcript's own shape: one
    /// `TranscriptRecord` carrying two timed runs, so without the `.paragraph` tap the
    /// pieces would stay one paragraph (§6's "record text used verbatim when a group
    /// holds every piece of its record" rule) — the same-record boundary is not a
    /// boundary the marker log did not create.
    func testParagraphOnlyMarkersProduceUnlabeledParagraphs() async throws {
        try writeManifest(idA)
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(
            seq: 0, text: "first paragraph second paragraph",
            captureFrameStart: 0, captureFrameEnd: 60_000,
            runs: [
                TranscriptRun(text: "first paragraph", captureFrameStart: 0, captureFrameEnd: 20_000),
                TranscriptRun(text: "second paragraph", captureFrameStart: 40_000, captureFrameEnd: 60_000),
            ],
            generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 30_000, kind: .paragraph),
        ])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.text), ["first paragraph", "second paragraph"])
        XCTAssertTrue(paragraphs.allSatisfy { $0.voice == nil }, "paragraph markers carry no voice")
    }

    func testMarkersWithoutATranscriptLeaveTheAbsentStateAlone() async throws {
        try writeManifest(idA)
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])
        // No live.jsonl: transcription never ran on this capture.

        let transcript = await model().transcript(for: idA)

        XCTAssertEqual(transcript.state, .absent)
        XCTAssertNil(transcript.text)
        XCTAssertNil(transcript.paragraphs)
    }

    // MARK: - T7 Task 5: attribution survives an edit (the test that used to justify
    // the `current.source == .machineLive` gate — brief step 5.4)

    /// Before Task 5, this scenario is EXACTLY what the gate at `EntryTranscript.swift`
    /// blocked: `current` is `.userEdit` (promoted, then one word retyped through the
    /// real draft lifecycle), and markers exist — but the gate forced `paragraphs` to
    /// `nil` unconditionally, discarding the owner's two-voice structure the moment he
    /// made a single edit. This is the regression Task 5 removes.
    func testEditedRevisionStillAttributesVoicesFromMarkers() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        try await promoteThenEdit(idA, editedText: "intro words answer words")   // "reply" -> "answer"
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: StructureMarker.Voice.littleNico),
        ])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs,
                                       "an edited revision must still attribute voices, not fall back to nil")
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.voice), [StructureMarker.Voice.bigNico, StructureMarker.Voice.littleNico])
        XCTAssertTrue(paragraphs[0].text.contains("intro") && !paragraphs[0].text.contains("answer"))
        XCTAssertTrue(paragraphs[1].text.contains("answer") && !paragraphs[1].text.contains("reply"))

        // The paragraphs must still rejoin to exactly what the chain itself considers
        // "current" — computed independently here, not hardcoded, so a bug that
        // attributed over the WRONG revision's spans would still be caught.
        let chain = try XCTUnwrap(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA)))
        let current = try XCTUnwrap(TranscriptChain.current(TranscriptChain.ordered(chain.revisions)))
        let expectedText = TranscriptChain.plainText(current)
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " "), expectedText)
        XCTAssertEqual(transcript.text, expectedText, "text is the edited text, unaffected by attribution")
    }

    /// Baseline invariant either side of the gate's removal: an edited entry with NO
    /// marker log still gets `paragraphs == nil` (design §7's absence rule), and `text`
    /// is the edited plain text regardless. Genuinely useful as a regression guard once
    /// the gate is gone: nothing about removing it may accidentally start synthesizing
    /// paragraphs when there is no marker log to attribute from.
    func testEditedEntryWithNoMarkerLogHasNilParagraphsAndTheEditedText() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        try await promoteThenEdit(idA, editedText: "intro words answer words")
        // No markers.jsonl written at all.

        let transcript = await model().transcript(for: idA)

        XCTAssertNil(transcript.paragraphs, "absent marker log must never render as single-voice, even edited")
        XCTAssertEqual(transcript.text, "intro words answer words")
    }

    // MARK: - Performance contract: the scanner never reads markers.jsonl

    func testLibraryScanDoesNotComputeAttribution() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first { $0.captureID == idA })

        let transcript = LibraryScanner.transcriptSummary(capture)

        XCTAssertNil(transcript.paragraphs,
                     "the scanner defaults to .skip and must not pay for a markers.jsonl read")
        XCTAssertEqual(transcript.text, "hello there", "the scan's own job is unaffected")
    }

    // MARK: - Window size (the mechanism `AttributionMode.compute(sampleRate:)` drives)

    /// Not a manifest test — a direct `AttributionMode.compute(sampleRate:)` call, to pin
    /// down the *mechanism* `testSampleRateComesFromTheManifest` below depends on: two
    /// window sizes that disagree on where a tap snaps, chosen by hand against
    /// `MarkerSnapping.snap`'s rule order (rule 1's gap intersection vs. rule 4's
    /// raw-frame fallback). The narrow window's outcome is asserted on the property the
    /// window size actually changes — `hasApproximateBoundary` — not just a count, so a
    /// change that shuffled paragraph counts for an unrelated reason would not pass this
    /// by accident.
    func testWiderSnapWindowFindsAGapTheNarrowerWindowMisses() throws {
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let wide = EntryTranscriptLoader.load(captureDirectory: captureDir(idA), expectedRecords: nil,
                                              attribution: .compute(sampleRate: 48_000))
        let narrow = EntryTranscriptLoader.load(captureDirectory: captureDir(idA), expectedRecords: nil,
                                                attribution: .compute(sampleRate: 16_000))

        let wideParagraphs = try XCTUnwrap(wide.paragraphs)
        let narrowParagraphs = try XCTUnwrap(narrow.paragraphs)
        XCTAssertEqual(wideParagraphs.count, 2,
                       "the wider 48kHz window reaches the nearby gap and finds the voice boundary")
        XCTAssertFalse(wideParagraphs.contains { $0.hasApproximateBoundary },
                       "the gap was found, so the cut is exact")

        XCTAssertEqual(narrowParagraphs.count, 1,
                       "the narrower 16kHz window misses the gap and the tap lands mid-run")
        XCTAssertTrue(try XCTUnwrap(narrowParagraphs.first).hasApproximateBoundary,
                      "nothing in the window means the raw tap frame is kept, and marked approximate")
    }

    /// The requirement itself: `Manifest.format.sampleRate`, not a constant, is what
    /// reaches `MarkerSnapping.windowFrames`. Same discriminating fixture as the window
    /// test above, but driven end-to-end through `model.transcript(for:)` off a manifest
    /// written at 16kHz — the fixture where 48kHz's window finds the gap (2 paragraphs)
    /// and 16kHz's doesn't (1, approximate). If the loader ever fell back to a literal
    /// 48_000 here, this would still see 2 paragraphs and fail.
    func testSampleRateComesFromTheManifest() async throws {
        try writeManifest(idA, sampleRate: 16_000)
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.count, 1, "16kHz off the manifest gives the narrow window's outcome")
        XCTAssertTrue(try XCTUnwrap(paragraphs.first).hasApproximateBoundary)
    }

    /// `manifestFacts`' 48kHz fallback (no manifest, or one that fails to decode) — the
    /// same discriminating fixture, so a broken fallback (e.g. 0 or a tiny default) would
    /// show up as the narrow-window outcome instead of the wide one.
    func testMissingManifestFallsBackTo48kHzForTheSnapWindow() async throws {
        // No writeManifest(idA) call: `transcript/` is created directly, same as a
        // capture whose manifest write never landed.
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.count, 2, "the 48kHz fallback finds the gap, same as an explicit 48kHz manifest")
        XCTAssertFalse(paragraphs.contains { $0.hasApproximateBoundary })
    }

    // MARK: - T7 Task 6: marker corrections, end to end through the real disk wire

    /// 6.2: a `.correctionVoice` record at frame F can flip whether that boundary
    /// counts as a paragraph break — a re-tap of the SAME voice makes no break
    /// (`TranscriptAttribution.breakpoints`'s own re-tap rule), so two raw `.voice`
    /// taps both saying "bn" render as ONE paragraph; correcting the second to "ln"
    /// (the brief's "correct a voice at an EXISTING boundary" — the correction's
    /// `frame` matches the raw tap's frame exactly) is what splits it into two. The
    /// original tap bytes on disk must stay untouched — corrections are additive,
    /// never a rewrite (locked decision 5).
    func testVoiceCorrectionChangesTheParagraphSplitAndLeavesTheOriginalTapByteUnchanged() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: "bn"),   // same voice: no break yet
        ])

        let originalBytes = try Data(contentsOf: markerLogURL(idA))

        let unsplit = await model().transcript(for: idA)
        XCTAssertEqual(try XCTUnwrap(unsplit.paragraphs).count, 1,
                       "a re-tap of the same voice must not manufacture a split")

        let writer = MarkerLogWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(StructureMarker(seq: 0, frame: 30_000, kind: .correctionVoice, voice: "ln"))
        try writer.close()

        let afterBytes = try Data(contentsOf: markerLogURL(idA))
        XCTAssertTrue(afterBytes.starts(with: originalBytes),
                     "the two original tap lines must be byte-unchanged after the correction append")
        XCTAssertGreaterThan(afterBytes.count, originalBytes.count, "the correction was actually appended")

        let corrected = await model().transcript(for: idA)
        let correctedParagraphs = try XCTUnwrap(corrected.paragraphs)
        XCTAssertEqual(correctedParagraphs.count, 2,
                       "the voice correction now disagrees with the still-active voice, splitting the paragraph")
        XCTAssertEqual(correctedParagraphs.map(\.voice), ["bn", "ln"])
        XCTAssertEqual(correctedParagraphs.map(\.text), ["intro words", "reply words"])
    }

    /// 6.3: a `.correctionRetract` removes the split a mis-tapped `.paragraph` marker
    /// created; a retract of a nonexistent seq is ignored, not an error — a UI retract
    /// action racing another retract (or acting on a stale row) must not crash or
    /// silently remove the wrong thing.
    func testRetractRemovesAMisTappedSplitAndIgnoresANonexistentTarget() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("first part", 0, 96_000),
            ("second part", 96_000, 192_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 96_000, kind: .paragraph)])

        let split = await model().transcript(for: idA)
        XCTAssertEqual(try XCTUnwrap(split.paragraphs).count, 2, "the mis-tapped paragraph split, before retraction")

        let writer1 = MarkerLogWriter(captureDirectory: captureDir(idA))
        try writer1.open()
        // Retract of a seq that never existed: must be a no-op, not a throw and not a
        // crash — and must not touch the real marker at seq 0.
        try writer1.append(StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: 999))
        try writer1.close()

        let stillSplit = await model().transcript(for: idA)
        XCTAssertEqual(try XCTUnwrap(stillSplit.paragraphs).count, 2,
                      "a retract of a nonexistent seq must be ignored, not silently remove something else")

        let writer2 = MarkerLogWriter(captureDirectory: captureDir(idA))
        try writer2.open()
        try writer2.append(StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: 0))
        try writer2.close()

        let retracted = await model().transcript(for: idA)
        // Retracting the ONLY marker leaves nothing usable to attribute — design §7's
        // "nothing usable in the log" rule, same one an empty marker log already gets —
        // never collapsed to "single voice" nor left as the pre-retraction split.
        XCTAssertNil(retracted.paragraphs,
                    "retracting the only marker leaves nothing usable to attribute")
        XCTAssertEqual(retracted.text, "first part second part", "the underlying transcript text is unaffected")
    }

    /// 6.4b, end to end: `MarkerCorrectionWriter.addBoundary` runs against the SAME
    /// `current.spans` the spans-based attribution path (Task 5) reads, and the
    /// resulting paragraph split lands where the picked word's own span starts — not
    /// at the group's start. Three separate `live.jsonl` records (not runs) so
    /// promotion yields three separate placeable spans
    /// (`TranscriptRevisionStore.spans(fromCommitted:)`'s no-runs branch) — the real
    /// chain, not a hand-built fixture, so a bug in how promotion assembles spans
    /// would also be caught.
    ///
    /// **Correction (review Critical 2):** this fixture's words have real GAPS between
    /// them (10_000-frame silences), so `MarkerSnapping`'s gap search is a coincidental
    /// no-op here regardless of whether the boundary-add frame is protected from
    /// snapping at all — the doc comment used to claim "snapping's gap search never
    /// applies here" as if that were structural, which was false: it was an artifact
    /// of this fixture's shape, not a property of the mechanism. The actual guarantee
    /// (`EntryTranscript.snappedMarkers` marking a boundary-add's frame `isExact` and
    /// routing it around `MarkerSnapping.snap` entirely) is pinned by the ADJACENT
    /// test below, `testAddBoundaryOnAbuttingWordsIsNotSnapped`, using the shape that
    /// actually discriminates: words with NO gap between them at all, which is the
    /// device-observed norm for in-record runs.
    func testAddBoundaryEndToEndSplitsTheRenderedParagraphAtThePickedWord() async throws {
        try writeManifest(idA)
        try writeFinalAudio(idA)
        try writeLiveTranscript(idA, [
            ("one", 0, 10_000),
            ("two", 20_000, 30_000),
            ("three", 40_000, 50_000),
        ])
        _ = await store().promoteIfNeeded(captureID: idA)

        let chain = try XCTUnwrap(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA)))
        let current = try XCTUnwrap(TranscriptChain.current(TranscriptChain.ordered(chain.revisions)))
        XCTAssertEqual(current.spans.map(\.text), ["one", "two", "three"], "sanity: one span per record")

        let before = await model().transcript(for: idA)
        XCTAssertNil(before.paragraphs, "no markers.jsonl at all yet — nothing to attribute")

        let written = try MarkerCorrectionWriter.addBoundary(atSpanIndex: 1, spans: current.spans,
                                                              captureDirectory: captureDir(idA))
        XCTAssertEqual(written, 20_000, "span 1's (\"two\") own start frame")

        let after = await model().transcript(for: idA)
        let paragraphs = try XCTUnwrap(after.paragraphs, "the boundary-add must have created something to attribute")
        XCTAssertEqual(paragraphs.map(\.text), ["one", "two three"],
                       "split lands before span 1, not before span 0 (the group's own start)")
    }

    /// Review Critical 1 + 2: the reviewer's own probe, reproduced against the SHIPPED
    /// code before the fix (quoted in the fix commit) — four ABUTTING word intervals
    /// (`[0,10k][10k,20k][20k,30k][30k,50k]`, no gaps at all between any of them) is
    /// the device-observed norm for in-record runs (owner's own marker-session data),
    /// not an edge case. Before the fix: `MarkerSnapping.merged()` fuses all four into
    /// one continuous `[0,50000]` "speech" interval with no gap anywhere; a
    /// boundary-add's frame at word-start `20_000` then reads as "inside speech" (rule
    /// 0 fails), finds no gap (rule 1), and snaps to a boundary or the raw frame
    /// itself depending on window size — landing on frame 0 in the reviewer's probe,
    /// which produced NO visible split at all (the resulting empty leading group gets
    /// filtered). This is exactly what the brief's "must say so rather than silently
    /// placing the boundary somewhere near" forbids: a boundary-add is a WORD-anchored,
    /// exact-by-construction frame, and must never enter `MarkerSnapping`'s gap search
    /// in the first place.
    func testAddBoundaryOnAbuttingWordsIsNotSnapped() async throws {
        try writeManifest(idA)
        try writeFinalAudio(idA)
        try writeLiveTranscript(idA, [
            ("one", 0, 10_000),
            ("two", 10_000, 20_000),
            ("three", 20_000, 30_000),
            ("four", 30_000, 50_000),
        ])
        _ = await store().promoteIfNeeded(captureID: idA)

        let chain = try XCTUnwrap(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA)))
        let current = try XCTUnwrap(TranscriptChain.current(TranscriptChain.ordered(chain.revisions)))
        XCTAssertEqual(current.spans.map(\.text), ["one", "two", "three", "four"])

        let written = try MarkerCorrectionWriter.addBoundary(atSpanIndex: 2, spans: current.spans,
                                                              captureDirectory: captureDir(idA))
        XCTAssertEqual(written, 20_000, "span 2's (\"three\") own start frame")

        let after = await model().transcript(for: idA)
        let paragraphs = try XCTUnwrap(after.paragraphs,
                                       "the boundary-add must produce a real split, not vanish into a fused interval")
        XCTAssertEqual(paragraphs.map(\.text), ["one two", "three four"],
                       "the split must land exactly at word 2's own frame (20_000), never snapped to frame 0 "
                       + "or anywhere else — abutting words leave no gap for MarkerSnapping to search at all")
        XCTAssertFalse(paragraphs.contains { $0.hasApproximateBoundary },
                       "an exact, word-anchored frame is never approximate — nothing here was snapped")
    }
}
