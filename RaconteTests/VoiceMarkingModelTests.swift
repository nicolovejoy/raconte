import XCTest
@testable import Raconte

/// T7 Mark Voices (issue #56) Task 5 — the mark-voices screen's whole behaviour.
/// `VoiceMarkingView` is a thin binding over `VoiceMarkingModel`, so every rule belongs
/// here (SwiftUI body rendering isn't reachable from `RaconteTests`).
///
/// `FakeVoiceMarkingStore` mirrors `FakeMarkerCorrectionStore`'s own shape: it holds
/// REAL raw `StructureMarker` records and re-derives its `voiceMarkingLayout` from them
/// on every call via the real `MarkerCorrections`/`TranscriptAttribution` pipeline —
/// never a synthetic answer that only records "a write happened" — so a second `open()`
/// genuinely observes the fold, exactly like `MarkerCorrectionModelTests`' fake does for
/// retract/correct/add.
@MainActor
final class VoiceMarkingModelTests: XCTestCase {

    private let captureID = "cap"
    private let bn = VoiceDisplay.mainVoice
    private var ln: String { VoiceDisplay.other(VoiceDisplay.mainVoice) }

    private func model(_ store: FakeVoiceMarkingStore) -> VoiceMarkingModel {
        VoiceMarkingModel(captureID: captureID, store: store)
    }

    /// A placeable span: real, non-degenerate bounds (`TranscriptAttribution.isPlaceableSpan`).
    private func placeable(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .exact, frameStart: start, frameEnd: end)
    }

    /// `n` placeable spans, one word each, 10k frames apart — same fixture shape
    /// `VoiceMarkingPlanTests` uses.
    private func words(_ n: Int) -> [TranscriptSpan] {
        (0..<n).map { placeable("w\($0)", Int64($0) * 10_000, Int64($0) * 10_000 + 5_000) }
    }

    // MARK: - open()

    /// A raw `.paragraph` marker splits an unmarked entry into two paragraphs; the
    /// second paragraph's tokens must carry the GLOBAL span index (2, 3), not a
    /// per-paragraph-local one (0, 1) — a later marking gesture hands span indices
    /// straight to `VoiceMarkingPlan`, which only understands the global space. The
    /// fixture also mixes in a non-placeable span to pin `Token.isPlaceable`.
    func testOpenBuildsParagraphRowsWithGlobalSpanIndexedTokens() async {
        let store = FakeVoiceMarkingStore()
        store.spans = [
            placeable("w0", 0, 5_000),
            placeable("w1", 10_000, 15_000),
            TranscriptSpan(text: "typed", anchor: .none),
            placeable("w3", 30_000, 35_000),
        ]
        store.records = [StructureMarker(seq: 0, frame: 30_000, kind: .paragraph)]

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.rows.map(\.id), [0, 1])
        XCTAssertEqual(model.rows[0].tokens.map(\.id), [0, 1, 2], "global indices, not paragraph-local")
        XCTAssertEqual(model.rows[0].tokens.map(\.text), ["w0", "w1", "typed"])
        XCTAssertEqual(model.rows[0].tokens.map(\.isPlaceable), [true, true, false])
        XCTAssertEqual(model.rows[1].tokens.map(\.id), [3])
        XCTAssertEqual(model.rows[1].tokens.map(\.text), ["w3"])
    }

    func testOpenMapsUnreadableAndUnavailableToTheirOwnStates() async {
        let store = FakeVoiceMarkingStore()
        store.forcedLayout = .unavailable

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.state, .nothingToMark, "no readable canonical revision to mark onto")
        XCTAssertTrue(model.rows.isEmpty)

        store.forcedLayout = .markersUnreadable("permission denied")
        await model.open()
        XCTAssertEqual(model.state, .unreadable("permission denied"),
                       "an unreadable marker log must never collapse into .nothingToMark")
        XCTAssertTrue(model.rows.isEmpty)
    }

    // MARK: - flipParagraph

    /// The end-to-end shape: voice visibly flipped in `rows` after. Fixture is an
    /// already-voiced (hasAnyVoiceMarker: true) three-paragraph entry, all "bn" — flip
    /// the LAST paragraph (no restore needed), and confirm the row the owner actually
    /// looks at now says "ln".
    func testFlipParagraphWritesThePlannedCommandsInOrderAndReloads() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: bn),
            StructureMarker(seq: 1, frame: 20_000, kind: .paragraph),
            StructureMarker(seq: 2, frame: 40_000, kind: .paragraph),
        ]

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.map(\.voice), [bn, bn, bn], "precondition: three bn paragraphs")

        await model.flipParagraph(2)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows.map(\.voice), [bn, bn, ln],
                       "the flipped row must show the NEW voice after the reload, not the old one")
    }

    /// Order-pinning test (Gate B-style mutation target): an unmarked, two-paragraph
    /// entry, flip the LAST paragraph — exactly two commands, opener then boundary. The
    /// fake's re-derivation would end up correct even if the model executed these in
    /// the WRONG order (append-only + later-seq-wins means the final voices come out
    /// the same either way), so the thing that actually catches a reordering mutation
    /// is asserting the store's recorded call order directly.
    func testFlipOnAnUnmarkedEntryWritesOpenerThenBoundary() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [StructureMarker(seq: 0, frame: 20_000, kind: .paragraph)]

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.map(\.voice), [nil, nil], "precondition: unmarked, two paragraphs")

        await model.flipParagraph(1)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.writeLog, [
            .opener(voice: bn),
            .boundary(spanIndex: 2, voice: ln),
        ], "the opener must be written BEFORE the boundary — call order, not just final content")
    }

    // MARK: - markRange

    func testMarkRangeMarksAndRestores() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.count, 1, "precondition: unmarked, single paragraph")

        await model.markRange(first: 2, last: 3, to: ln)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows.map(\.voice), [bn, ln, bn],
                       "the range is marked ln, everything after it is restored to bn")
        XCTAssertEqual(model.rows[1].tokens.map(\.text), ["w2", "w3"])
    }

    // MARK: - Write failure (constraint 1: non-atomic plan execution)

    /// The fake fails the FIRST write — nothing reaches disk, so `rows` must be
    /// byte-identical to what they were before the gesture.
    func testWriteFailureSurfacesTheErrorAndLeavesRowsUnchanged() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [StructureMarker(seq: 0, frame: 20_000, kind: .paragraph)]
        store.failOnCallNumber = 1

        let model = model(store)
        await model.open()
        let rowsBefore = model.rows

        await model.flipParagraph(1)

        XCTAssertEqual(model.errorMessage, "That couldn’t be saved. Try again.")
        XCTAssertEqual(model.rows, rowsBefore, "the first write failed — nothing changed on disk")
    }

    /// The other half of constraint 1: the fake lets the FIRST command through and
    /// fails the SECOND. Something genuinely changed on disk (the opener), so `rows`
    /// after the mandatory reload must reflect exactly that — not the pre-gesture
    /// state (which would hide the partial write) and not the fully-flipped state
    /// (which would claim a gesture that didn't finish).
    func testPartialWriteFailureSurfacesErrorAndReloadsToTheFirstCommandsEffect() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [StructureMarker(seq: 0, frame: 20_000, kind: .paragraph)]
        store.failOnCallNumber = 2

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.map(\.voice), [nil, nil], "precondition: unmarked, two paragraphs")

        await model.flipParagraph(1)

        XCTAssertEqual(model.errorMessage, "That couldn’t be saved. Try again.")
        XCTAssertEqual(store.writeLog, [.opener(voice: bn), .boundary(spanIndex: 2, voice: ln)],
                       "both calls were attempted — the second is the one that threw")
        XCTAssertEqual(model.rows.map(\.voice), [bn, bn],
                       "the opener's effect survives the reload; the boundary that threw does not — " +
                       "never the pre-gesture state, never the fully-flipped state")
    }

    // MARK: - .notMarkable refusal (constraint 2)

    /// A paragraph with no placeable span at all cannot anchor a flip —
    /// `VoiceMarkingPlan` refuses with `.notMarkable` before returning any commands.
    /// The model must surface the same rejection copy
    /// `MarkerCorrectionWriter.boundaryAddRejectionMessage()` already uses, and the
    /// store must never see a write for a refused plan.
    func testNotMarkableRefusalSurfacesTheRejectionMessageAndWritesNothing() async {
        let store = FakeVoiceMarkingStore()
        store.spans = [TranscriptSpan(text: "uh", anchor: .none), TranscriptSpan(text: "um", anchor: .none)]

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.count, 1, "precondition: one paragraph, nothing placeable in it")

        await model.flipParagraph(0)

        XCTAssertEqual(model.errorMessage, MarkerCorrectionWriter.boundaryAddRejectionMessage())
        XCTAssertTrue(store.writeLog.isEmpty, "a refused plan must write nothing at all")
    }

    // MARK: - alternativeVoice

    func testAlternativeVoiceOffersTheOtherOfTheGoverningVoice() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: bn),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: ln),
        ]

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.map(\.voice), [bn, ln], "precondition: bn then ln")

        XCTAssertEqual(model.alternativeVoice(forRangeStartingAt: 1), ln, "governed by bn -> offers ln")
        XCTAssertEqual(model.alternativeVoice(forRangeStartingAt: 4), bn, "governed by ln -> offers bn")
    }

    // MARK: - hasApproximateBoundary (review finding 1)

    /// `ParagraphRow.hasApproximateBoundary` must carry EACH paragraph's own flag, not a
    /// constant — cardinality >= 2 (one `true`, one `false`) in one fixture, per the
    /// plan's standing rule against single-value fixtures indistinguishable from a
    /// hardcoded answer (the exact shape that let Task 3's `hasAnyVoiceMarker`
    /// hardcoded-`true` survive 1155 tests). Built via `forcedLayout` directly — a real
    /// approximate boundary is a `MarkerSnapping` outcome the fake's own derivation
    /// doesn't reproduce (it always snaps exact, see its doc comment), so this pins the
    /// MODEL's field mapping in isolation from that unrelated concern.
    func testOpenCarriesEachParagraphsOwnApproximateBoundaryFlag() async {
        let store = FakeVoiceMarkingStore()
        let spans = words(4)
        let paragraphs = [
            TranscriptAttribution.Paragraph(voice: nil, text: "w0 w1",
                                            hasApproximateBoundary: false, spanRange: 0..<2),
            TranscriptAttribution.Paragraph(voice: nil, text: "w2 w3",
                                            hasApproximateBoundary: true, spanRange: 2..<4),
        ]
        store.forcedLayout = .ready(spans: spans, paragraphs: paragraphs, hasAnyVoiceMarker: false)

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.rows.map(\.hasApproximateBoundary), [false, true],
                       "each row must carry ITS OWN paragraph's flag, not a constant")
    }

    // MARK: - In-flight guard (review finding 3)

    /// The concrete failure the review named: a second gesture entering while the first
    /// is still suspended on a store `await` must be a no-op, not a second concurrent
    /// write racing the first's. The fake holds its FIRST store call open (via a
    /// continuation) until released, so this test can deterministically observe "the
    /// second gesture's store calls happened DURING the hold" rather than relying on
    /// incidental scheduling.
    func testASecondGestureDuringAnInFlightWriteIsANoOp() async {
        let store = FakeVoiceMarkingStore()
        store.spans = words(6)
        store.records = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: bn),
            StructureMarker(seq: 1, frame: 20_000, kind: .paragraph),
            StructureMarker(seq: 2, frame: 40_000, kind: .paragraph),
        ]

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.rows.map(\.voice), [bn, bn, bn], "precondition: three bn paragraphs")

        store.holdWrites = true
        async let first: Void = model.flipParagraph(0)
        while !store.isHolding { await Task.yield() }

        // The first gesture's own store call is suspended inside the hold right now —
        // its FIRST command hasn't even been recorded yet. A second gesture arriving
        // in this window must be entirely refused.
        await model.markRange(first: 2, last: 3, to: ln)
        XCTAssertEqual(store.writeLog, [],
                       "the second gesture must never reach the store while the first is in flight")

        store.releaseHold()
        _ = await first

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.writeLog, [
            .boundary(spanIndex: 0, voice: ln),
            .boundary(spanIndex: 2, voice: bn),
        ], "only the first gesture's own commands were ever written")
        XCTAssertEqual(model.rows.map(\.voice), [ln, bn, bn],
                       "the second gesture's mark-range must have had zero effect")
    }
}

/// Records every call made against it so tests can assert on WHAT was written AND in
/// what ORDER — mirrors `FakeMarkerCorrectionStore`'s role. Re-derives
/// `voiceMarkingLayout` from real `records` through the real
/// `MarkerCorrections.effectiveMarkers` + `TranscriptAttribution.attribute(spans:
/// snapped:)` pipeline on every call (never a canned answer), so a second `open()`
/// genuinely observes whatever the model's writes actually did.
@MainActor
final class FakeVoiceMarkingStore: VoiceMarkingStore {
    var spans: [TranscriptSpan] = []
    /// Raw markers as they'd sit in `markers.jsonl` — corrections included, exactly
    /// like the real file. Seeded by a test for a pre-existing-markers fixture; grown
    /// by `addVoiceBoundary`/`addOpeningVoice` below with the SAME record shapes
    /// `MarkerCorrectionWriter` actually appends.
    var records: [StructureMarker] = []
    /// Overrides `voiceMarkingLayout`'s answer independent of `spans`/`records` — a
    /// test checking `.unavailable`/`.markersUnreadable` sets this. `nil` (the
    /// default) means "derive from `spans`/`records`".
    var forcedLayout: EntryTranscript.VoiceMarkingLayout?

    /// One entry in `writeLog`, in call order — `.opener`/`.boundary` mirror
    /// `VoiceMarkingPlan.Command` exactly so an order-pinning assertion reads directly
    /// against what the plan asked for.
    enum WriteCall: Equatable {
        case opener(voice: String)
        case boundary(spanIndex: Int, voice: String)
    }
    private(set) var writeLog: [WriteCall] = []

    /// 1-indexed across BOTH write methods combined (a plan's commands interleave
    /// them) — set to make the Nth write throw, everything before it succeeds and
    /// mutates `records` for real, everything after it never runs.
    var failOnCallNumber: Int?
    private var callCount = 0

    /// Suspends the FIRST store write (across either method) on a real continuation
    /// until `releaseHold()` is called — lets a test deterministically park a gesture
    /// mid-flight (review finding 3) instead of relying on incidental scheduling.
    /// Self-consuming: only ever the first call holds, so the gesture that owns it can
    /// complete its later commands normally once released.
    var holdWrites = false
    private(set) var isHolding = false
    private var holdContinuation: CheckedContinuation<Void, Never>?

    private func maybeHold() async {
        guard holdWrites else { return }
        holdWrites = false
        isHolding = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            holdContinuation = continuation
        }
        isHolding = false
    }

    func releaseHold() {
        holdContinuation?.resume()
        holdContinuation = nil
    }

    private func nextSeq() -> Int { (records.map(\.seq).max() ?? -1) + 1 }

    func voiceMarkingLayout(for captureID: String) async -> EntryTranscript.VoiceMarkingLayout {
        if let forcedLayout { return forcedLayout }
        let effective = MarkerCorrections.effectiveMarkers(records)
        let hasAnyVoiceMarker = effective.contains { $0.marker.kind == .voice }
        // The model only ever writes through `addVoiceBoundary`/`addOpeningVoice`,
        // both of which mint EXACT (word-anchored or frame-0) frames — no snapping
        // window needed to reproduce the real read path for records this fake grows
        // itself. A test seeding raw `.voice`/`.paragraph` markers directly picks
        // frames that already sit exactly on a span boundary for the same reason.
        let snapped = effective.map {
            MarkerSnapping.SnappedMarker(marker: $0.marker, snappedFrame: $0.marker.frame, approximate: false)
        }
        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: snapped)
        return .ready(spans: spans, paragraphs: paragraphs, hasAnyVoiceMarker: hasAnyVoiceMarker)
    }

    @discardableResult
    func addVoiceBoundary(atSpanIndex spanIndex: Int, voice: String, captureID: String) async throws -> Int64 {
        await maybeHold()
        writeLog.append(.boundary(spanIndex: spanIndex, voice: voice))
        callCount += 1
        if failOnCallNumber == callCount { throw FakeVoiceMarkingStoreError.writeFailed }
        let frame = spans[spanIndex].frameStart ?? 0
        records.append(StructureMarker(seq: nextSeq(), frame: frame, kind: .correctionBoundaryAdd, voice: voice))
        return frame
    }

    func addOpeningVoice(voice: String, captureID: String) async throws {
        await maybeHold()
        writeLog.append(.opener(voice: voice))
        callCount += 1
        if failOnCallNumber == callCount { throw FakeVoiceMarkingStoreError.writeFailed }
        records.append(StructureMarker(seq: nextSeq(), frame: 0, kind: .correctionBoundaryAdd, voice: voice))
    }
}

private enum FakeVoiceMarkingStoreError: Error, Equatable {
    case writeFailed
}
