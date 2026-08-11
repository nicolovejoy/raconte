import XCTest
@testable import Raconte

/// T7 Task 6, step 6.5 — the marker-correction screen's whole behaviour.
/// `MarkerCorrectionView` is a thin binding over `MarkerCorrectionModel`, so every rule
/// belongs here (SwiftUI body rendering isn't reachable from `RaconteTests`).
///
/// `FakeMarkerCorrectionStore` is used throughout, mirroring `TranscriptEditorModelTests`'
/// own `FakeEditorStore`: the states under test (a write that throws, a non-placeable
/// word) are field cases a real disk fixture either can't build independently or would
/// entangle with the read side.
@MainActor
final class MarkerCorrectionModelTests: XCTestCase {

    private let captureID = "cap"

    private func model(_ store: FakeMarkerCorrectionStore) -> MarkerCorrectionModel {
        MarkerCorrectionModel(captureID: captureID, store: store)
    }

    // MARK: - open()

    func testOpenPopulatesBoundariesSortedByFrameAndWordsWithPlaceability() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [
            StructureMarker(seq: 1, frame: 96_000, kind: .paragraph),
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"),
        ]
        store.spans = [
            TranscriptSpan(text: "hello", anchor: .exact, frameStart: 0, frameEnd: 10_000),
            TranscriptSpan(text: "typed", anchor: .none),
        ]

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.boundaries.map(\.id), [0, 1], "sorted by frame, not by seq or file order")
        XCTAssertEqual(model.boundaries.map(\.frame), [0, 96_000])
        XCTAssertEqual(model.words.map(\.text), ["hello", "typed"])
        XCTAssertEqual(model.words.map(\.isPlaceable), [true, false],
                       "the .none-anchored word must not be offerable")
    }

    /// Correction kinds are never listed as boundaries — this screen shows the
    /// EFFECTIVE state (folded), and a correction record showing up as something to
    /// retract would let the owner retract a retract. The retract here deliberately
    /// targets a seq that ISN'T the voice marker's own (99, nonexistent) — the point
    /// under test is "a correction record is never itself a row", not "a retract
    /// removed the row it targeted" (that is a separate test, below).
    func testCorrectionRecordsThemselvesAreNeverListedAsBoundaries() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"),
            StructureMarker(seq: 1, frame: 0, kind: .correctionRetract, retractsSeq: 99),
        ]
        store.spans = []

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.boundaries.map(\.id), [0])
    }

    func testNoSpansAndNoMarkersIsNothingToCorrect() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = []
        store.spans = nil

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.state, .nothingToCorrect)
    }

    /// Markers can exist with no readable current revision (a degraded chain) — the
    /// boundary list is still worth showing (retracting a bad tap needs no spans at
    /// all), even though the word list is empty.
    func testMarkersWithNoSpansIsStillReady() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [StructureMarker(seq: 0, frame: 0, kind: .paragraph)]
        store.spans = nil

        let model = model(store)
        await model.open()

        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.words.isEmpty)
    }

    // MARK: - retract

    /// Real disk behaviour (locked decision 5): a retract never removes the original
    /// raw marker, it APPENDS a `.correctionRetract` record beside it. The fake
    /// mirrors that exactly — `onRetract` ADDS a correction record, never deletes the
    /// original from `store.markers` — so this test also exercises the fold inside
    /// `open()` itself, not just "did re-open happen".
    func testRetractCallsTheStoreWithTheRowsSeqAndReopens() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [StructureMarker(seq: 3, frame: 4_800, kind: .paragraph)]
        store.spans = []

        let model = model(store)
        await model.open()
        XCTAssertEqual(model.boundaries.count, 1)

        store.onRetract = { seq in
            store.markers.append(StructureMarker(seq: 4, frame: 0, kind: .correctionRetract, retractsSeq: seq))
        }
        await model.retract(model.boundaries[0])

        XCTAssertEqual(store.retractedSeqs, [3])
        XCTAssertTrue(model.boundaries.isEmpty,
                      "the fold must remove the retracted row on re-open, not just append the correction record")
        XCTAssertNil(model.errorMessage)
    }

    func testRetractFailureSurfacesAnErrorAndKeepsTheRow() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [StructureMarker(seq: 0, frame: 0, kind: .paragraph)]
        store.spans = []
        store.retractError = MarkerLogError.notOpen

        let model = model(store)
        await model.open()
        await model.retract(model.boundaries[0])

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.boundaries.count, 1, "a failed write must not silently drop the row")

        model.acknowledgeError()
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - correctVoice

    func testCorrectVoiceIsANoOpForAParagraphRow() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [StructureMarker(seq: 0, frame: 0, kind: .paragraph)]
        store.spans = []

        let model = model(store)
        await model.open()
        await model.correctVoice(model.boundaries[0], to: "ln")

        XCTAssertTrue(store.voiceCorrections.isEmpty,
                      "a .paragraph row has no voice — the model must guard, not trust the view")
    }

    func testCorrectVoiceCallsTheStoreWithTheRowsFrame() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = [StructureMarker(seq: 0, frame: 30_000, kind: .voice, voice: "bn")]
        store.spans = []

        let model = model(store)
        await model.open()
        await model.correctVoice(model.boundaries[0], to: "ln")

        XCTAssertEqual(store.voiceCorrections.count, 1)
        XCTAssertEqual(store.voiceCorrections[0].frame, 30_000)
        XCTAssertEqual(store.voiceCorrections[0].voice, "ln")
    }

    // MARK: - addBoundary

    /// The view disables a non-placeable row, but the model is checked again here
    /// (the same "never trust the UI already enforced it" reasoning `writeDraft`'s own
    /// guards use) — asserted by the store never being called at all.
    func testAddBoundaryOnANonPlaceableWordNeverCallsTheStoreAndStatesWhy() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = []
        store.spans = [TranscriptSpan(text: "typed", anchor: .none)]

        let model = model(store)
        await model.open()
        await model.addBoundary(model.words[0])

        XCTAssertEqual(store.addBoundaryCallCount, 0)
        XCTAssertEqual(model.errorMessage, MarkerCorrectionWriter.boundaryAddRejectionMessage())
    }

    /// `.correctionBoundaryAdd` is the RAW record the writer appends — it must never
    /// itself show up in `boundaries` (that list is raw `.voice`/`.paragraph` taps
    /// only, per `testCorrectionRecordsThemselvesAreNeverListedAsBoundaries`), so
    /// "re-opened" here is proven by a second read, not by a boundary-count change.
    func testAddBoundaryOnAPlaceableWordCallsTheStoreWithItsSpanIndexAndReopens() async {
        let store = FakeMarkerCorrectionStore()
        store.markers = []
        store.spans = [
            TranscriptSpan(text: "one", anchor: .inherited, frameStart: 0, frameEnd: 10_000),
            TranscriptSpan(text: "two", anchor: .inherited, frameStart: 20_000, frameEnd: 30_000),
        ]

        let model = model(store)
        await model.open()
        XCTAssertEqual(store.spansReadCount, 1)

        await model.addBoundary(model.words[1])

        XCTAssertEqual(store.addedSpanIndices, [1])
        XCTAssertEqual(store.spansReadCount, 2, "addBoundary() must re-open (a second read), not just write")
        XCTAssertNil(model.errorMessage)
    }
}

/// Records every call made against it so tests can assert on WHAT was written, not
/// just that `open()` was re-run — mirrors `FakeEditorStore`'s role for
/// `TranscriptEditorModelTests`.
@MainActor
final class FakeMarkerCorrectionStore: MarkerCorrectionStore {
    var markers: [StructureMarker] = []
    var spans: [TranscriptSpan]?
    private(set) var spansReadCount = 0

    var retractError: (any Error)?
    var voiceCorrectionError: (any Error)?
    var addBoundaryError: (any Error)?

    private(set) var retractedSeqs: [Int] = []
    private(set) var voiceCorrections: [(frame: Int64, voice: String)] = []
    private(set) var addedSpanIndices: [Int] = []
    var addBoundaryCallCount: Int { addedSpanIndices.count }

    /// Fires AFTER recording the call, so a test can simulate the write actually
    /// taking effect before the model's own re-`open()` reads it back.
    var onRetract: ((Int) -> Void)?

    nonisolated func currentSpans(for captureID: String) async -> [TranscriptSpan]? {
        await MainActor.run {
            spansReadCount += 1
            return spans
        }
    }

    nonisolated func rawMarkers(for captureID: String) async -> [StructureMarker] {
        await MainActor.run { markers }
    }

    func retractMarker(seq: Int, captureID: String) async throws {
        if let retractError { throw retractError }
        retractedSeqs.append(seq)
        onRetract?(seq)
    }

    func correctVoice(frame: Int64, voice: String, captureID: String) async throws {
        if let voiceCorrectionError { throw voiceCorrectionError }
        voiceCorrections.append((frame, voice))
    }

    @discardableResult
    func addBoundary(atSpanIndex: Int, captureID: String) async throws -> Int64 {
        if let addBoundaryError { throw addBoundaryError }
        addedSpanIndices.append(atSpanIndex)
        return spans?[atSpanIndex].frameStart ?? 0
    }
}
