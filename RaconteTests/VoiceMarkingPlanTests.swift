import XCTest
@testable import Raconte

/// T7 Mark Voices (issue #56) Task 4: the pure planner's command shapes.
///
/// Every case is table-driven with cardinality >= 2 (Gate B reco: a single fixture per
/// rule is indistinguishable from a hardcoded answer), built from hand-made spans and
/// paragraphs — no disk. The end-to-end half of this task lives in
/// `VoiceMarkingPlanApplyTests`, which executes these commands through the REAL
/// `MarkerCorrectionWriter` against real capture directories.
final class VoiceMarkingPlanTests: XCTestCase {

    private let bn = VoiceDisplay.mainVoice
    private var ln: String { VoiceDisplay.other(VoiceDisplay.mainVoice) }

    // MARK: - Fixture builders

    /// A placeable span: real, non-degenerate bounds (`TranscriptAttribution.isPlaceableSpan`).
    private func placeable(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .exact, frameStart: start, frameEnd: end)
    }

    /// A span with no usable bounds — the shape a boundary can never anchor to.
    private func unplaceable(_ text: String) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .none)
    }

    /// `n` placeable spans, one word each, 10k frames apart.
    private func words(_ n: Int) -> [TranscriptSpan] {
        (0..<n).map { placeable("w\($0)", Int64($0) * 10_000, Int64($0) * 10_000 + 5_000) }
    }

    /// A paragraph over a span range, with its text derived the same way
    /// `TranscriptAttribution.attribute(spans:snapped:)` derives it.
    private func para(_ voice: String?, _ range: Range<Int>,
                      _ spans: [TranscriptSpan]) -> TranscriptAttribution.Paragraph {
        TranscriptAttribution.Paragraph(voice: voice,
                                        text: TranscriptText.join(spans[range].map(\.text)),
                                        hasApproximateBoundary: false,
                                        spanRange: range)
    }

    // MARK: - Opener rule

    /// Anchoring AT the first placeable span of the whole transcript needs no opener: an
    /// `addOpeningVoice` writes frame 0, which resolves to the SAME attribution cut as
    /// the first placeable span's own start, so it could only ever be overridden by the
    /// anchor that follows it (later seq wins). Two shapes: the anchor at span 0, and the
    /// anchor at the first placeable span with non-placeable text leading it.
    func testFlipOfAnUnmarkedEntrysOnlyParagraphAnchorsAtItsFirstPlaceableSpanWithNoOpener() throws {
        let plain = words(3)
        let leadingUnplaceable = [unplaceable("uh")] + words(3)

        let cases: [(name: String, spans: [TranscriptSpan], expectedAnchor: Int)] = [
            ("every span placeable", plain, 0),
            ("a non-placeable span leads the entry", leadingUnplaceable, 1),
        ]

        for c in cases {
            let paragraphs = [para(nil, 0..<c.spans.count, c.spans)]
            let commands = try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: paragraphs,
                                                              spans: c.spans, hasAnyVoiceMarker: false)
            XCTAssertEqual(commands, [.addVoiceBoundary(spanIndex: c.expectedAnchor, voice: ln)], c.name)
        }
    }

    /// The opener's actual job: everything BEFORE the flipped paragraph must keep the
    /// main voice rather than falling back to "no voice in force". Both cases flip a
    /// paragraph that is neither the first nor the last, so all three commands appear.
    func testFlipOfAMiddleParagraphInAnUnmarkedEntryEmitsOpenerFlipAndRestore() throws {
        let cases: [(name: String, spans: [TranscriptSpan], ranges: [Range<Int>],
                     flip: Int, anchor: Int, restore: Int)] = [
            ("three paragraphs, flip the middle", words(6), [0..<2, 2..<4, 4..<6], 1, 2, 4),
            ("four paragraphs, flip the third", words(8), [0..<2, 2..<4, 4..<6, 6..<8], 2, 4, 6),
        ]

        for c in cases {
            let paragraphs = c.ranges.map { para(nil, $0, c.spans) }
            let commands = try VoiceMarkingPlan.flipParagraph(at: c.flip, paragraphs: paragraphs,
                                                              spans: c.spans, hasAnyVoiceMarker: false)
            XCTAssertEqual(commands, [
                .addOpeningVoice(voice: bn),
                .addVoiceBoundary(spanIndex: c.anchor, voice: ln),
                .addVoiceBoundary(spanIndex: c.restore, voice: bn),
            ], c.name)
        }
    }

    // MARK: - Restore rule

    /// A flip that runs to the end of the entry has nothing to restore — the new voice
    /// legitimately governs everything after it.
    func testFlipOfTheLastParagraphEmitsNoRestore() throws {
        let spans = words(6)

        let unmarked = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(nil, 0..<2, spans), para(nil, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: false)
        XCTAssertEqual(unmarked, [.addOpeningVoice(voice: bn), .addVoiceBoundary(spanIndex: 2, voice: ln)],
                       "two paragraphs, flip the second")

        let marked = try VoiceMarkingPlan.flipParagraph(
            at: 2, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<4, spans), para(bn, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(marked, [.addVoiceBoundary(spanIndex: 4, voice: ln)],
                       "three already-voiced paragraphs, flip the last")
    }

    /// The opener is gated on `hasAnyVoiceMarker`, not on where the anchor sits: both
    /// cases anchor well past the first placeable span (where an unmarked entry WOULD get
    /// an opener) and must still emit none, because a voice is already in force.
    func testFlipOfAMarkedParagraphEmitsNoOpener() throws {
        let spans = words(6)

        let twoParagraphs = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(twoParagraphs, [.addVoiceBoundary(spanIndex: 2, voice: ln)])

        let threeParagraphs = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(ln, 0..<2, spans), para(ln, 2..<4, spans), para(ln, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(threeParagraphs, [
            .addVoiceBoundary(spanIndex: 2, voice: bn),
            .addVoiceBoundary(spanIndex: 4, voice: ln),
        ])
    }

    /// A paragraph that already declares its own voice (its voice differs from the
    /// paragraph before it, which means a voice marker re-declares at its start) needs no
    /// restore — the declaration is already there on disk, and appending a duplicate is
    /// noise. The third row is the adversary: identical shape EXCEPT that the next
    /// paragraph inherits its voice, where the restore must be emitted.
    func testFlipSkipsTheRestoreWhenTheNextParagraphDeclaresItsOwnVoice() throws {
        let spans = words(6)

        let firstOfTwo = try VoiceMarkingPlan.flipParagraph(
            at: 0, paragraphs: [para(bn, 0..<2, spans), para(ln, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(firstOfTwo, [.addVoiceBoundary(spanIndex: 0, voice: ln)],
                       "paragraph 1 declares ln itself")

        let middleOfThree = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(bn, 0..<2, spans), para(ln, 2..<4, spans), para(bn, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(middleOfThree, [.addVoiceBoundary(spanIndex: 2, voice: bn)],
                       "paragraph 2 declares bn itself")

        let inheritingNeighbour = try VoiceMarkingPlan.flipParagraph(
            at: 0, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(inheritingNeighbour, [
            .addVoiceBoundary(spanIndex: 0, voice: ln),
            .addVoiceBoundary(spanIndex: 2, voice: bn),
        ], "paragraph 1 only INHERITS bn — without a restore it would flip too")
    }

    /// Walking forward past a paragraph with nothing to anchor to, and the end of that
    /// walk. The restored voice is the NEXT paragraph's pre-change voice even when the
    /// index it lands on comes from a later paragraph.
    func testRestoreWalksPastAParagraphWithNoPlaceableSpans() throws {
        var spans = words(5)
        spans.insert(unplaceable("mm"), at: 2)      // spans: w0 w1 [mm] w2 w3 w4

        let walked = try VoiceMarkingPlan.flipParagraph(
            at: 0,
            paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<3, spans), para(bn, 3..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(walked, [
            .addVoiceBoundary(spanIndex: 0, voice: ln),
            .addVoiceBoundary(spanIndex: 3, voice: bn),
        ], "paragraph 1 holds only a non-placeable span — the restore lands in paragraph 2")

        let walkedOffTheEnd = try VoiceMarkingPlan.flipParagraph(
            at: 0,
            paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<3, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(walkedOffTheEnd, [.addVoiceBoundary(spanIndex: 0, voice: ln)],
                       "nothing placeable remains to restore at")
    }

    // MARK: - Refusals

    func testFlipThrowsNotMarkableWhenTheParagraphHasNoPlaceableSpan() throws {
        let spans = [unplaceable("uh"), unplaceable("mm")] + words(2)

        let allUnplaceable = [para(nil, 0..<2, spans), para(nil, 2..<4, spans)]
        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: allUnplaceable,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }

        // The committed/pieces attribution path populates no `spanRange` at all.
        let noSpanRange = [TranscriptAttribution.Paragraph(voice: nil, text: "uh mm w0 w1",
                                                           hasApproximateBoundary: false, spanRange: nil)]
        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: noSpanRange,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }

        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 7, paragraphs: allUnplaceable,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }
    }

    /// Endpoints are the caller's responsibility, but the planner refuses rather than
    /// trusting it — `MarkerCorrectionWriter` would throw on the same span anyway, and a
    /// half-written plan (switch appended, restore refused) is worse than no plan.
    func testMarkRangeThrowsNotMarkableWhenAnEndpointIsNotPlaceable() throws {
        var spans = words(4)
        spans[1] = unplaceable("mm")
        let paragraphs = [para(nil, 0..<4, spans)]

        for range in [1...2, 0...1, 0...9] {
            XCTAssertThrowsError(try VoiceMarkingPlan.markRange(range, to: ln, paragraphs: paragraphs,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
                XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "\(range)")
            }
        }
    }

    // MARK: - Same-bounds splice fragments (review Important 1)

    /// The shape: `TranscriptSplice` degrades a touched span into fragments that all carry
    /// the PARENT span's FULL bounds, so two CONSECUTIVE placeable spans can share an
    /// identical `[frameStart, frameEnd)` — exactly the array
    /// `TranscriptAttributionTests`'
    /// `testTwoPlaceableSpansSharingBoundsCutAfterTheFirstFragmentAndFlagItApproximate`
    /// already pins on the read side.
    private var sameBoundsFragments: [TranscriptSpan] {
        [TranscriptSpan(text: "frag one", anchor: .inherited, frameStart: 0, frameEnd: 100_000),
         TranscriptSpan(text: "frag two", anchor: .inherited, frameStart: 0, frameEnd: 100_000),
         TranscriptSpan(text: "after", anchor: .exact, frameStart: 100_000, frameEnd: 200_000)]
    }

    /// A plan is written in span indices but lands on disk as FRAMES. A boundary aimed at
    /// fragment two would be written at frame 0, and `placeableCutPosition` resolves frame
    /// 0 to fragment ONE — so the marked voice would bleed onto text the owner never
    /// selected. Refuse rather than mark the wrong words.
    func testMarkRangeThrowsNotMarkableWhenAnEarlierSpanSharesTheAnchorsStartFrame() throws {
        let spans = sameBoundsFragments

        // The range STARTS on the second fragment: its frame belongs to the first.
        XCTAssertThrowsError(try VoiceMarkingPlan.markRange(
            1...1, to: ln, paragraphs: [para(nil, 0..<3, spans)],
            spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "switch anchored on fragment two")
        }

        // The range ENDS on the first fragment, so the RESTORE lands on fragment two —
        // the same collision, reached through the other emitted command.
        XCTAssertThrowsError(try VoiceMarkingPlan.markRange(
            0...0, to: ln, paragraphs: [para(bn, 0..<3, spans)],
            spans: spans, hasAnyVoiceMarker: true)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "restore anchored on fragment two")
        }

        // The adversary: the same fragment RUN, with the colliding span removed, must
        // still plan normally — the refusal is about colliding frames, not about splice
        // fragments being untouchable.
        let distinctFrames = [spans[0], spans[2]]
        let legal = try VoiceMarkingPlan.markRange(0...0, to: ln,
                                                   paragraphs: [para(bn, 0..<2, distinctFrames)],
                                                   spans: distinctFrames, hasAnyVoiceMarker: true)
        XCTAssertEqual(legal, [.addVoiceBoundary(spanIndex: 0, voice: ln),
                               .addVoiceBoundary(spanIndex: 1, voice: bn)])
    }

    /// The sneakier consequence: with a paragraph break between the two fragments (the
    /// read-side fixture cited above produces exactly that split), a flip plans a switch at
    /// fragment one and a restore at fragment two — BOTH at frame 0, one cut. The restore
    /// is written last, so it wins, and the flip silently does nothing while every write
    /// reports success.
    func testFlipThrowsNotMarkableWhenTheSwitchAndRestoreWouldLandOnTheSameCut() throws {
        let spans = sameBoundsFragments
        let paragraphs = [para(nil, 0..<1, spans), para(nil, 1..<3, spans)]

        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: paragraphs,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "switch and restore share frame 0")
        }

        // Flipping the SECOND paragraph emits no restore at all, but anchors on fragment
        // two, whose frame still belongs to fragment one — refused for the first reason.
        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 1, paragraphs: paragraphs,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "anchor on fragment two")
        }

        // The adversary: a cut between the fragment RUN and what follows it collides with
        // nothing, and must still plan.
        let legal = try VoiceMarkingPlan.flipParagraph(
            at: 0, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<3, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(legal, [.addVoiceBoundary(spanIndex: 0, voice: ln),
                               .addVoiceBoundary(spanIndex: 2, voice: bn)])
    }

    // MARK: - markRange

    /// The three-way split: the marked words take the target voice, and the first
    /// placeable span after them restores whatever governed there before.
    func testMarkRangeMidParagraphEmitsSwitchAndRestoreAtTheFollowingSpan() throws {
        let spans = words(5)

        let unmarked = try VoiceMarkingPlan.markRange(1...2, to: ln, paragraphs: [para(nil, 0..<5, spans)],
                                                       spans: spans, hasAnyVoiceMarker: false)
        XCTAssertEqual(unmarked, [
            .addOpeningVoice(voice: bn),
            .addVoiceBoundary(spanIndex: 1, voice: ln),
            .addVoiceBoundary(spanIndex: 3, voice: bn),
        ], "an unmarked entry needs the opener to voice the words before the range")

        let alreadyVoiced = try VoiceMarkingPlan.markRange(2...3, to: ln,
                                                           paragraphs: [para(bn, 0..<5, spans)],
                                                           spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(alreadyVoiced, [
            .addVoiceBoundary(spanIndex: 2, voice: ln),
            .addVoiceBoundary(spanIndex: 4, voice: bn),
        ], "the restore carries the voice governing the span it lands on")

        let acrossParagraphs = try VoiceMarkingPlan.markRange(
            1...3, to: bn,
            paragraphs: [para(ln, 0..<2, spans), para(bn, 2..<3, spans), para(ln, 3..<5, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(acrossParagraphs, [
            .addVoiceBoundary(spanIndex: 1, voice: bn),
            .addVoiceBoundary(spanIndex: 4, voice: ln),
        ], "span 4's governing paragraph is the ln one it sits in, not the range's own paragraph")
    }

    func testMarkRangeToTheEndOfTheEntryEmitsNoRestore() throws {
        let spans = words(5)
        let toTheLastSpan = try VoiceMarkingPlan.markRange(3...4, to: ln, paragraphs: [para(bn, 0..<5, spans)],
                                                           spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(toTheLastSpan, [.addVoiceBoundary(spanIndex: 3, voice: ln)])

        var withTrailingUnplaceable = words(4)
        withTrailingUnplaceable.append(unplaceable("mm"))
        let toTheLastPlaceableSpan = try VoiceMarkingPlan.markRange(
            2...3, to: ln, paragraphs: [para(bn, 0..<5, withTrailingUnplaceable)],
            spans: withTrailingUnplaceable, hasAnyVoiceMarker: true)
        XCTAssertEqual(toTheLastPlaceableSpan, [.addVoiceBoundary(spanIndex: 2, voice: ln)],
                       "a trailing non-placeable span can anchor nothing — no restore exists to emit")
    }
}

/// The D6 property (task-4-brief.md, the task's core): a plan, EXECUTED through the real
/// `MarkerCorrectionWriter` against a real capture directory and re-derived through
/// `EntryTranscript.voiceMarkingLayout`, must (a) leave the transcript's text byte-for-byte
/// unchanged and (b) produce exactly the voices the gesture intended — no more, no fewer.
///
/// Every expectation below is written out literally, per fixture, rather than re-derived
/// from the planner's own output: a computed expectation would agree with any planner,
/// including a wrong one (memory: vacuous-fixtures-need-an-adversary).
final class VoiceMarkingPlanApplyTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private let bn = VoiceDisplay.mainVoice
    private var ln: String { VoiceDisplay.other(VoiceDisplay.mainVoice) }

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMarkingPlanApply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    // MARK: - Disk fixture helpers (same shapes as TranscriptAttributionLoadTests)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    private func writeManifest(_ id: String) throws {
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    /// `promoteIfNeeded` requires durable audio before it will promote `live.jsonl` into
    /// revision zero — content is irrelevant, only presence.
    private func writeFinalAudio(_ id: String) throws {
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
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
        for marker in markers { try writer.append(marker) }
        try writer.close()
    }

    /// A capture promoted from `live.jsonl` into revision zero — one span per record.
    private func promoted(_ id: String, _ records: [(text: String, start: Int64, end: Int64)]) async throws {
        try writeManifest(id)
        try writeFinalAudio(id)
        try writeLiveTranscript(id, records)
        _ = await store().promoteIfNeeded(captureID: id)
    }

    private func currentSpans(_ id: String) throws -> [TranscriptSpan] {
        let chain = try XCTUnwrap(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(id)))
        return try XCTUnwrap(TranscriptChain.current(TranscriptChain.ordered(chain.revisions))).spans
    }

    // MARK: - The property

    private struct VoicedParagraph: Equatable, CustomStringConvertible {
        var voice: String?
        var text: String
        var description: String { "(\(voice ?? "nil"), \"\(text)\")" }
    }

    private enum Gesture {
        case flip(paragraph: Int)
        case markRange(ClosedRange<Int>, to: String)
    }

    /// Runs one fixture end to end: read the layout, assert the pre-state literally, plan,
    /// EXECUTE through `MarkerCorrectionWriter`, re-read, assert the post-state literally,
    /// and assert the joined transcript text is untouched by the whole round trip.
    private func assertPlanApplies(_ name: String, id: String,
                                   gesture: Gesture,
                                   before: [VoicedParagraph],
                                   hasAnyVoiceMarkerBefore: Bool,
                                   after: [VoicedParagraph],
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .ready(let spans, let paragraphs, let hasAnyVoiceMarker) =
                EntryTranscript.voiceMarkingLayout(captureDirectory: captureDir(id), sampleRate: 48_000) else {
            return XCTFail("\(name): expected .ready before marking", file: file, line: line)
        }
        let observedBefore = paragraphs.map { VoicedParagraph(voice: $0.voice, text: $0.text) }
        XCTAssertEqual(observedBefore, before, "\(name): pre-state", file: file, line: line)
        XCTAssertEqual(hasAnyVoiceMarker, hasAnyVoiceMarkerBefore, "\(name): hasAnyVoiceMarker",
                       file: file, line: line)

        let commands: [VoiceMarkingPlan.Command]
        switch gesture {
        case .flip(let index):
            commands = try VoiceMarkingPlan.flipParagraph(at: index, paragraphs: paragraphs,
                                                          spans: spans, hasAnyVoiceMarker: hasAnyVoiceMarker)
        case .markRange(let range, let voice):
            commands = try VoiceMarkingPlan.markRange(range, to: voice, paragraphs: paragraphs,
                                                      spans: spans, hasAnyVoiceMarker: hasAnyVoiceMarker)
        }
        XCTAssertFalse(commands.isEmpty, "\(name): a marking gesture that plans nothing marks nothing",
                       file: file, line: line)

        for command in commands {
            switch command {
            case .addOpeningVoice(let voice):
                try MarkerCorrectionWriter.addOpeningVoice(voice: voice, captureDirectory: captureDir(id))
            case .addVoiceBoundary(let spanIndex, let voice):
                try MarkerCorrectionWriter.addVoiceBoundary(atSpanIndex: spanIndex, spans: spans,
                                                            voice: voice, captureDirectory: captureDir(id))
            }
        }

        guard case .ready(_, let newParagraphs, _) =
                EntryTranscript.voiceMarkingLayout(captureDirectory: captureDir(id), sampleRate: 48_000) else {
            return XCTFail("\(name): expected .ready after marking", file: file, line: line)
        }
        let observedAfter = newParagraphs.map { VoicedParagraph(voice: $0.voice, text: $0.text) }
        XCTAssertEqual(observedAfter, after, "\(name): post-state", file: file, line: line)
        XCTAssertEqual(TranscriptText.join(newParagraphs.map(\.text)),
                       TranscriptText.join(paragraphs.map(\.text)),
                       "\(name): marking is a voice operation and must never touch the text",
                       file: file, line: line)
    }

    func testAppliedPlansPreserveParagraphTextsAndProduceTheIntendedVoices() async throws {
        // 1. Unmarked, single paragraph. The anchor IS the transcript's first placeable
        //    span, so no opener is written — the flip alone voices the whole entry.
        let single = "01AAAAAAAAAAAAAAAAAAAAAAAA"
        try await promoted(single, [("one", 0, 10_000), ("two", 20_000, 30_000), ("three", 40_000, 50_000)])
        try assertPlanApplies("unmarked single paragraph", id: single,
                              gesture: .flip(paragraph: 0),
                              before: [VoicedParagraph(voice: nil, text: "one two three")],
                              hasAnyVoiceMarkerBefore: false,
                              after: [VoicedParagraph(voice: ln, text: "one two three")])

        // 2. Unmarked, THREE paragraphs made by voiceless ¶ boundary adds. Flipping the
        //    middle one is the restore rule's whole reason to exist: without the trailing
        //    restore, paragraph 3 would flip too, and without the opener paragraph 1 would
        //    be left voiceless.
        let multi = "01BBBBBBBBBBBBBBBBBBBBBBBB"
        try await promoted(multi, [("one", 0, 10_000), ("two", 20_000, 30_000),
                                   ("three", 40_000, 50_000), ("four", 60_000, 70_000),
                                   ("five", 80_000, 90_000), ("six", 100_000, 110_000)])
        let multiSpans = try currentSpans(multi)
        for spanIndex in [2, 4] {
            try MarkerCorrectionWriter.addBoundary(atSpanIndex: spanIndex, spans: multiSpans,
                                                   captureDirectory: captureDir(multi))
        }
        try assertPlanApplies("unmarked multi-paragraph (¶ adds)", id: multi,
                              gesture: .flip(paragraph: 1),
                              before: [VoicedParagraph(voice: nil, text: "one two"),
                                       VoicedParagraph(voice: nil, text: "three four"),
                                       VoicedParagraph(voice: nil, text: "five six")],
                              hasAnyVoiceMarkerBefore: false,
                              after: [VoicedParagraph(voice: bn, text: "one two"),
                                      VoicedParagraph(voice: ln, text: "three four"),
                                      VoicedParagraph(voice: bn, text: "five six")])

        // 3. A real captured two-voice entry: RAW taps (a frame-0 opener and a mid-entry
        //    switch), which are snapped rather than exact. Flipping the last paragraph
        //    overrides the switch tap's voice at the very cut it created — the tap itself
        //    stays on disk untouched, and the paragraph break survives.
        let twoVoice = "01CCCCCCCCCCCCCCCCCCCCCCCC"
        try await promoted(twoVoice, [("intro words", 0, 20_000), ("reply words", 40_000, 60_000)])
        try writeMarkers(twoVoice, [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: bn),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: ln),
        ])
        try assertPlanApplies("captured two-voice, raw taps", id: twoVoice,
                              gesture: .flip(paragraph: 1),
                              before: [VoicedParagraph(voice: bn, text: "intro words"),
                                       VoicedParagraph(voice: ln, text: "reply words")],
                              hasAnyVoiceMarkerBefore: true,
                              after: [VoicedParagraph(voice: bn, text: "intro words"),
                                      VoicedParagraph(voice: bn, text: "reply words")])

        // 4. A leading span with no usable bounds — here an anchor spelling this build
        //    doesn't recognise (`SpanAnchor.unknown`, the documented foreign/imported
        //    shape that round-trips verbatim). It can anchor nothing, so the flip lands on
        //    the first placeable span and that leading text HONESTLY keeps no voice rather
        //    than being swept into a claim the markers can't support.
        let leading = "01DDDDDDDDDDDDDDDDDDDDDDDD"
        try writeManifest(leading)
        try await store().append(
            TranscriptRevision(id: "01DDDDDDDDDDDDDDDDDDDDDDDE", source: .import,
                               createdAt: Date(timeIntervalSince1970: 3_000),
                               spans: [TranscriptSpan(text: "prelude", anchor: .unknown("approximate"),
                                                      frameStart: 0, frameEnd: 5_000),
                                       TranscriptSpan(text: "one", anchor: .exact,
                                                      frameStart: 10_000, frameEnd: 20_000),
                                       TranscriptSpan(text: "two", anchor: .exact,
                                                      frameStart: 20_000, frameEnd: 30_000),
                                       TranscriptSpan(text: "three", anchor: .exact,
                                                      frameStart: 30_000, frameEnd: 40_000)],
                               parentID: nil),
            captureID: leading)
        try assertPlanApplies("leading non-placeable span", id: leading,
                              gesture: .flip(paragraph: 0),
                              before: [VoicedParagraph(voice: nil, text: "prelude one two three")],
                              hasAnyVoiceMarkerBefore: false,
                              after: [VoicedParagraph(voice: nil, text: "prelude"),
                                      VoicedParagraph(voice: ln, text: "one two three")])

        // 5. Abutting exact-frame runs (the device-observed norm: no silence between
        //    in-record words, so `MarkerSnapping` has no gap to search). Marking a range in
        //    the MIDDLE of the only paragraph must split it three ways — [prev, target,
        //    prev] — with every boundary landing on the exact word it was anchored to.
        let abutting = "01EEEEEEEEEEEEEEEEEEEEEEEE"
        try await promoted(abutting, [("one", 0, 10_000), ("two", 10_000, 20_000),
                                      ("three", 20_000, 30_000), ("four", 30_000, 50_000)])
        try assertPlanApplies("abutting exact-frame runs, mid-paragraph range", id: abutting,
                              gesture: .markRange(1...2, to: ln),
                              before: [VoicedParagraph(voice: nil, text: "one two three four")],
                              hasAnyVoiceMarkerBefore: false,
                              after: [VoicedParagraph(voice: bn, text: "one"),
                                      VoicedParagraph(voice: ln, text: "two three"),
                                      VoicedParagraph(voice: bn, text: "four")])

        // 6. An entry someone has already marked (opening voice + a voice-carrying
        //    boundary add). Re-marking the same cut is a plain append: later seq wins, and
        //    the earlier add stays on disk. This is what makes the whole design retract-free.
        let corrected = "01FFFFFFFFFFFFFFFFFFFFFFFF"
        try await promoted(corrected, [("one", 0, 10_000), ("two", 20_000, 30_000),
                                       ("three", 40_000, 50_000), ("four", 60_000, 70_000)])
        let correctedSpans = try currentSpans(corrected)
        try MarkerCorrectionWriter.addOpeningVoice(voice: bn, captureDirectory: captureDir(corrected))
        try MarkerCorrectionWriter.addVoiceBoundary(atSpanIndex: 2, spans: correctedSpans, voice: ln,
                                                    captureDirectory: captureDir(corrected))
        try assertPlanApplies("already-corrected entry, re-flipped at the same cut", id: corrected,
                              gesture: .flip(paragraph: 1),
                              before: [VoicedParagraph(voice: bn, text: "one two"),
                                       VoicedParagraph(voice: ln, text: "three four")],
                              hasAnyVoiceMarkerBefore: true,
                              after: [VoicedParagraph(voice: bn, text: "one two"),
                                      VoicedParagraph(voice: bn, text: "three four")])

        // 7. The consequence the controller (Task 5/6) has to show the owner: flipping a
        //    paragraph INTO the voice its neighbour already declares leaves the neighbour's
        //    voice marker changing nothing, and a voice marker that changes nothing is not
        //    a paragraph break — so the two paragraphs RE-RENDER AS ONE. Voices are still
        //    exactly what was asked for and the text is untouched; it is the visible
        //    paragraph split that goes away. Nothing is lost: both records are still on
        //    disk, and flipping the merged paragraph back re-separates them, because the
        //    older marker starts disagreeing with the active voice again. A break made by
        //    a ¶ marker (fixture 2) or by a raw tap is unaffected — those break
        //    unconditionally.
        let merging = "01GGGGGGGGGGGGGGGGGGGGGGGG"
        try await promoted(merging, [("one", 0, 10_000), ("two", 20_000, 30_000),
                                     ("three", 40_000, 50_000), ("four", 60_000, 70_000)])
        let mergingSpans = try currentSpans(merging)
        try MarkerCorrectionWriter.addOpeningVoice(voice: bn, captureDirectory: captureDir(merging))
        try MarkerCorrectionWriter.addVoiceBoundary(atSpanIndex: 2, spans: mergingSpans, voice: ln,
                                                    captureDirectory: captureDir(merging))
        try assertPlanApplies("flipping into the neighbour's voice merges the paragraphs", id: merging,
                              gesture: .flip(paragraph: 0),
                              before: [VoicedParagraph(voice: bn, text: "one two"),
                                       VoicedParagraph(voice: ln, text: "three four")],
                              hasAnyVoiceMarkerBefore: true,
                              after: [VoicedParagraph(voice: ln, text: "one two three four")])
    }

    /// Review Important 1, end to end on disk: the same-bounds splice-fragment shape
    /// (`TranscriptSplice` fragments carrying the PARENT span's FULL bounds, the read-side
    /// fixture in `TranscriptAttributionTests`), where a boundary aimed at fragment two
    /// would be WRITTEN at fragment one's frame. The planner refuses — and because it
    /// refuses before returning any commands at all, the marker log on disk is untouched:
    /// no opener, no half-applied switch. A planner that validated per-command instead of
    /// per-plan would leave the first one or two records behind forever (the log is
    /// append-only).
    func testMarkingRefusesOnSameBoundsSpliceFragmentsAndLeavesTheMarkerLogUntouched() async throws {
        let id = "01HHHHHHHHHHHHHHHHHHHHHHHH"
        try writeManifest(id)
        try await store().append(
            TranscriptRevision(id: "01HHHHHHHHHHHHHHHHHHHHHHHI", source: .userEdit,
                               createdAt: Date(timeIntervalSince1970: 3_000),
                               spans: [TranscriptSpan(text: "frag one", anchor: .inherited,
                                                      frameStart: 0, frameEnd: 100_000),
                                       TranscriptSpan(text: "frag two", anchor: .inherited,
                                                      frameStart: 0, frameEnd: 100_000),
                                       TranscriptSpan(text: "after", anchor: .exact,
                                                      frameStart: 100_000, frameEnd: 200_000)],
                               parentID: nil),
            captureID: id)

        // A legal, exact ¶ boundary add first, so the log is non-empty and its bytes can be
        // compared rather than merely "still absent".
        let spansBefore = try currentSpans(id)
        try MarkerCorrectionWriter.addBoundary(atSpanIndex: 2, spans: spansBefore,
                                               captureDirectory: captureDir(id))
        let logURL = SegmentLayout.markerLogURL(captureDirectory: captureDir(id))
        let bytesBefore = try Data(contentsOf: logURL)

        guard case .ready(let spans, let paragraphs, let hasAnyVoiceMarker) =
                EntryTranscript.voiceMarkingLayout(captureDirectory: captureDir(id), sampleRate: 48_000) else {
            return XCTFail("expected .ready")
        }
        XCTAssertEqual(paragraphs.map(\.text), ["frag one frag two", "after"], "sanity: the shape is on disk")
        XCTAssertFalse(hasAnyVoiceMarker)

        // Marking from fragment two: without the refusal this plans an opener, a switch at
        // frame 0 (which resolves to fragment ONE) and a restore — three appended records
        // and "frag one" wrongly voiced.
        XCTAssertThrowsError(try VoiceMarkingPlan.markRange(1...1, to: ln, paragraphs: paragraphs,
                                                            spans: spans, hasAnyVoiceMarker: hasAnyVoiceMarker)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }

        XCTAssertEqual(try Data(contentsOf: logURL), bytesBefore,
                       "a refused plan writes nothing — the append-only log is byte-identical")
        guard case .ready(_, let paragraphsAfter, _) =
                EntryTranscript.voiceMarkingLayout(captureDirectory: captureDir(id), sampleRate: 48_000) else {
            return XCTFail("expected .ready after the refusal")
        }
        XCTAssertEqual(paragraphsAfter.map(\.voice), paragraphs.map(\.voice), "no voice was assigned")
        XCTAssertEqual(paragraphsAfter.map(\.text), paragraphs.map(\.text))
    }
}
