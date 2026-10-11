import XCTest
@testable import Raconte

/// Counts reconcile calls and blocks until released, to prove coalescing.
actor FakeReconciler: SearchReconciling {
    var calls: [[String]] = []
    private var gate: CheckedContinuation<Void, Never>?
    func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report {
        calls.append(entries.map(\.captureID))
        await withCheckedContinuation { gate = $0 }
        return .init()
    }
    /// True when a parked call was released. False means nothing was parked.
    @discardableResult func release() -> Bool {
        guard let g = gate else { return false }
        gate = nil; g.resume(); return true
    }
    /// Returns once `n` calls have parked (or after ~2 s, so a broken build fails an
    /// assertion instead of hanging the suite).
    func waitForParkedCall(_ n: Int) async {
        for _ in 0..<400 where !(calls.count >= n && gate != nil) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Bounded wait for the model to go idle (~2 s), same reason.
@MainActor func waitUntilIdle(_ model: LibraryScreenModel) async {
    for _ in 0..<400 where model.searchIndexing { try? await Task.sleep(for: .milliseconds(5)) }
}

/// #194 Task 6: the library model hands every scan's entries (live and trashed) to the
/// reconciler, one reconcile at a time.
@MainActor
final class LibraryScreenModelSearchTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let liveID = ULID.make()
    private let trashedID = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScreenModelSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func writeCapture(_ id: String, trashed: Bool = false) throws {
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: dir))
        if trashed {
            try EntryMetadataStore.write(EntryMetadata(trashedAt: Date(timeIntervalSince1970: 2_000)),
                                         url: SegmentLayout.entryMetadataURL(captureDirectory: dir))
        }
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    func testRescanHandsAllEntriesAndTrashedToTheReconciler() async throws {
        try writeCapture(liveID)
        try writeCapture(trashedID, trashed: true)
        let model = model()
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        _ = await model.rescan()
        XCTAssertTrue(model.trashed.contains { $0.captureID == trashedID }, "fixture sanity")
        await fake.waitForParkedCall(1)
        let ids = await fake.calls.first ?? []
        XCTAssertEqual(Set(ids), Set([liveID, trashedID]))
        let released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
    }

    func testRescansDuringAReconcileCoalesceIntoExactlyOneMore() async throws {
        try writeCapture(liveID)
        let model = model()
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        _ = await model.rescan()                 // starts reconcile #1
        await fake.waitForParkedCall(1)          // #1 is parked inside the fake
        _ = await model.rescan()
        _ = await model.rescan()                 // two more while #1 runs
        var released = await fake.release(); XCTAssertTrue(released)
        await fake.waitForParkedCall(2)
        let afterFirst = await fake.calls.count
        XCTAssertEqual(afterFirst, 2)
        released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
        let afterSecond = await fake.calls.count
        XCTAssertEqual(afterSecond, 2)           // nothing queued after the follow-up
        XCTAssertFalse(model.searchIndexing)
    }

    func testSearchIndexingIsTrueWhileAReconcileRuns() async throws {
        try writeCapture(liveID)
        let model = model()
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        XCTAssertFalse(model.searchIndexing)
        _ = await model.rescan()
        await fake.waitForParkedCall(1)
        XCTAssertTrue(model.searchIndexing)
        let released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
        XCTAssertFalse(model.searchIndexing)
    }

    func testEachCompletedPassBumpsSearchIndexRevision() async throws {
        try writeCapture(liveID)
        let model = model()
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        XCTAssertEqual(model.searchIndexRevision, 0)
        _ = await model.rescan()
        await fake.waitForParkedCall(1)
        XCTAssertEqual(model.searchIndexRevision, 0)   // not before the pass completes
        let released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
        XCTAssertEqual(model.searchIndexRevision, 1)
    }
}
