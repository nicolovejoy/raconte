import XCTest
@testable import Raconte

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
        let handed = await fake.calls.first ?? []
        XCTAssertEqual(Set(handed.map(\.captureID)), Set([liveID, trashedID]))
        for entry in handed {
            XCTAssertEqual(entry.directory,
                           SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: entry.captureID))
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory.path))
        }
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
        XCTAssertEqual(model.searchIndexRevision, 2)   // two completed passes
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

    /// Counts the publishes the model announces, to prove a scan did or did not happen.
    private final class CountingObserver: LibraryRescanObserver {
        var count = 0
        func libraryDidRescan() { count += 1 }
    }

    func testAttachAfterAPublishedScanReconcilesThePublishedEntriesWithoutRescanning() async throws {
        try writeCapture(liveID)
        try writeCapture(trashedID, trashed: true)
        let model = model()
        let observer = CountingObserver()
        model.rescanObserver = observer
        _ = await model.rescan()
        XCTAssertEqual(observer.count, 1)
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        await fake.waitForParkedCall(1)
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 1)
        let firstCall = try XCTUnwrap(calls.first, "attach produced no reconcile call")
        XCTAssertEqual(Set(firstCall.map(\.captureID)), Set([liveID, trashedID]))
        XCTAssertEqual(observer.count, 1, "attach must not scan again")
        let released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
    }

    func testAttachBeforeAnyScanStartsNothing() async throws {
        try writeCapture(liveID)
        let model = model()
        let fake = FakeReconciler()
        model.attach(searchReconciler: fake)
        var count = await fake.calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(model.searchIndexing)
        _ = await model.rescan()
        await fake.waitForParkedCall(1)
        count = await fake.calls.count
        XCTAssertEqual(count, 1)
        let first = await fake.calls.first ?? []
        XCTAssertEqual(first.map(\.captureID), [liveID], "never an empty list")
        let released = await fake.release(); XCTAssertTrue(released)
        await waitUntilIdle(model)
        count = await fake.calls.count
        XCTAssertEqual(count, 1)
    }
}
