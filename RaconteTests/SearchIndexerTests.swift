import GRDB
import XCTest
@testable import Raconte

final class SearchIndexerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchIndexer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeThree() throws -> (SearchIndex, SearchIndexer, [SearchIndexer.Entry]) {
        let index = try SearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        var entries: [SearchIndexer.Entry] = []
        for (i, text) in ["alpha one", "beta two", "charlie three"].enumerated() {
            let dir = root.appendingPathComponent("captures-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: [text])
            entries.append(.init(captureID: ULID.make(), directory: dir))
        }
        return (index, SearchIndexer(index: index), entries)
    }

    private func ids(_ index: SearchIndex, _ word: String) async throws -> [String] {
        try await index.search(SearchQuery(text: word)).map(\.captureID)
    }

    func testFirstReconcileIndexesEverythingSecondIndexesNothing() async throws {
        let (index, indexer, entries) = try makeThree()
        let first = await indexer.reconcile(entries)
        XCTAssertEqual(first, .init(indexed: 3, removed: 0, unchanged: 0, failed: 0))
        let second = await indexer.reconcile(entries)
        XCTAssertEqual(second, .init(indexed: 0, removed: 0, unchanged: 3, failed: 0))
        let found = try await ids(index, "alpha")
        XCTAssertEqual(found, [entries[0].captureID])
    }

    func testEditedEntryIsReindexed() async throws {
        let (index, indexer, entries) = try makeThree()
        _ = await indexer.reconcile(entries)
        try SearchCaptureFixture.writeCanonical(entries[1].directory, n: 2, spans: ["beta gamma"])
        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(report.unchanged, 2)
        let edited = try await ids(index, "gamma")
        let old = try await ids(index, "two")
        let a = try await ids(index, "alpha")
        let c = try await ids(index, "charlie")
        XCTAssertEqual(edited, [entries[1].captureID])
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(a, [entries[0].captureID])
        XCTAssertEqual(c, [entries[2].captureID])
    }

    func testGoneEntryIsRemoved() async throws {
        let (index, indexer, entries) = try makeThree()
        _ = await indexer.reconcile(entries)
        let report = await indexer.reconcile(Array(entries.dropLast()))
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.unchanged, 2)
        let gone = try await ids(index, "charlie")
        let a = try await ids(index, "alpha")
        let b = try await ids(index, "beta")
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(a, [entries[0].captureID])
        XCTAssertEqual(b, [entries[1].captureID])
    }

    func testUnreadableEntryIsCountedFailedAndOthersStillIndex() async throws {
        let (index, indexer, entries) = try makeThree()
        try FileManager.default.removeItem(at: entries[2].directory)   // gone but still listed
        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report.indexed, 2)
        XCTAssertEqual(report.failed, 1)
        let a = try await ids(index, "alpha")
        XCTAssertEqual(a, [entries[0].captureID])
    }

    func testEmptyTextEntryIsNotIndexedAndNotFailed() async throws {
        let index = try SearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let indexer = SearchIndexer(index: index)
        let dir = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SearchCaptureFixture.writeLiveLog(dir, records: [])
        // Precondition: the log exists, so the fingerprint is non-nil and the body is what is empty.
        XCTAssertNotNil(SearchFingerprint.compute(directory: dir))
        XCTAssertNil(EntryTranscriptLoader.fullText(captureDirectory: dir))
        let report = await indexer.reconcile([.init(captureID: ULID.make(), directory: dir)])
        XCTAssertEqual(report, .init(indexed: 0, removed: 0, unchanged: 0, failed: 0))
        let known = try await index.fingerprints()
        XCTAssertTrue(known.isEmpty)
    }

    /// Damages the real index from a second connection: `fingerprints()` still reads the
    /// state table, but `remove` and `upsert` need `entry_text` and now throw.
    private func dropFullTextTable() throws {
        let queue = try DatabaseQueue(path: root.appendingPathComponent("index.sqlite").path)
        try queue.write { try $0.execute(sql: "DROP TABLE entry_text") }
    }

    func testFailedRemoveIsCountedFailedNotRemoved() async throws {
        let (_, indexer, entries) = try makeThree()
        _ = await indexer.reconcile(entries)
        try dropFullTextTable()
        let report = await indexer.reconcile(Array(entries.dropLast()))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.unchanged, 2)
    }

    func testFailedUpsertIsCountedFailedNotIndexedAndRunContinues() async throws {
        let (_, indexer, entries) = try makeThree()
        _ = await indexer.reconcile(entries)
        try dropFullTextTable()
        try SearchCaptureFixture.writeCanonical(entries[0].directory, n: 2, spans: ["alpha edited"])
        try SearchCaptureFixture.writeCanonical(entries[1].directory, n: 2, spans: ["beta edited"])
        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report.indexed, 0)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.unchanged, 1)
    }
}
