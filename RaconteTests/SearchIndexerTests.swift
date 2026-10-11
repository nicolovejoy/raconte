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
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .empty)
        let report = await indexer.reconcile([.init(captureID: ULID.make(), directory: dir)])
        XCTAssertEqual(report, .init(indexed: 0, removed: 0, unchanged: 0, failed: 0))
        let known = try await index.fingerprints()
        XCTAssertTrue(known.isEmpty)
    }

    /// A read error is not evidence the text is gone: the entry counts as failed and
    /// whatever the index holds for it stays, findable, under its old fingerprint.
    func testUnreadableTranscriptIsCountedFailedAndItsRowIsKept() async throws {
        let index = try SearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let indexer = SearchIndexer(index: index)
        var entries: [SearchIndexer.Entry] = []
        for name in ["known", "never-indexed"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            entries.append(.init(captureID: ULID.make(), directory: dir))
        }
        let known = try XCTUnwrap(entries.first), neverIndexed = try XCTUnwrap(entries.last)
        try SearchCaptureFixture.writeLiveLog(known.directory, records: ["alpha one"])
        let first = await indexer.reconcile([known])
        XCTAssertEqual(first, .init(indexed: 1, removed: 0, unchanged: 0, failed: 0))
        let before = try await index.fingerprints()

        // The log grows (so its fingerprint moves) and then cannot be read.
        try SearchCaptureFixture.writeLiveLog(known.directory, records: ["alpha one", "beta two"])
        try SearchCaptureFixture.sealLiveLog(known.directory)
        try SearchCaptureFixture.writeLiveLog(neverIndexed.directory, records: ["gamma three"])
        try SearchCaptureFixture.sealLiveLog(neverIndexed.directory)
        XCTAssertNotEqual(SearchFingerprint.compute(directory: known.directory), before[known.captureID],
                          "fixture sanity: the fingerprint moved, so the body is read")
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: known.directory), .unreadable)

        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report, .init(indexed: 0, removed: 0, unchanged: 0, failed: 2))
        let found = try await ids(index, "alpha")
        XCTAssertEqual(found, [known.captureID])
        let after = try await index.fingerprints()
        XCTAssertEqual(after, before, "the old row and its old fingerprint, nothing else")
    }

    /// Readable and wordless is a different answer: the words really are gone.
    func testAKnownEntryWhoseTextBecameEmptyIsRemovedNotFailed() async throws {
        let (index, indexer, entries) = try makeThree()
        _ = await indexer.reconcile(entries)
        try SearchCaptureFixture.writeCanonical(entries[0].directory, n: 2, spans: [""])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: entries[0].directory), .empty)
        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report, .init(indexed: 0, removed: 1, unchanged: 2, failed: 0))
        let gone = try await ids(index, "alpha")
        XCTAssertTrue(gone.isEmpty)
        let known = try await index.fingerprints()
        XCTAssertNil(known[entries[0].captureID])
    }

    // MARK: Read-only against the archive

    private struct FileStamp: Equatable {
        var size: UInt64
        var modified: Date
        var fileNumber: UInt64
    }

    /// Every file and directory under `directory`, by relative path.
    private func snapshot(_ directory: URL) throws -> [String: FileStamp] {
        var out: [String: FileStamp] = [:]
        let base = directory.standardizedFileURL.path
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: base))
        for case let relative as String in walker {
            let attributes = try FileManager.default.attributesOfItem(atPath: base + "/" + relative)
            out[relative] = FileStamp(
                size: try XCTUnwrap(attributes[.size] as? UInt64),
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date),
                fileNumber: try XCTUnwrap(attributes[.systemFileNumber] as? UInt64))
        }
        return out
    }

    /// The paths that differ between two snapshots: added, removed, or restamped.
    private func differences(_ a: [String: FileStamp], _ b: [String: FileStamp]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// The indexer's whole licence is to READ `captures/`. A cold pass (everything indexed)
    /// and a warm pass (nothing to do) over every shape of entry leave each path, size,
    /// modification date and file number exactly as they were.
    func testReconcileWritesNothingUnderCaptures() async throws {
        let capturesRoot = AppContainer.capturesRoot(containerRoot: root)
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot, deviceIDProvider: { "test-device" })
        var entries: [SearchIndexer.Entry] = []
        func makeEntry() throws -> SearchIndexer.Entry {
            let id = ULID.make()
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let entry = SearchIndexer.Entry(captureID: id, directory: dir)
            entries.append(entry)
            return entry
        }

        // A trusted head: `head.json` matches the chain, so no revision body is decoded.
        let trusted = try makeEntry()
        try SearchCaptureFixture.writeCanonical(trusted.directory, n: 1, spans: ["alpha trusted"])
        try await store.persistHead(captureID: trusted.captureID)
        // No head at all.
        let headless = try makeEntry()
        try SearchCaptureFixture.writeCanonical(headless.directory, n: 1, spans: ["beta first"])
        try SearchCaptureFixture.writeCanonical(headless.directory, n: 2, spans: ["beta second"])
        // A stale head: persisted, then the chain moved on.
        let stale = try makeEntry()
        try SearchCaptureFixture.writeCanonical(stale.directory, n: 1, spans: ["gamma first"])
        try await store.persistHead(captureID: stale.captureID)
        try SearchCaptureFixture.writeCanonical(stale.directory, n: 2, spans: ["gamma second"])
        // A trashed entry: handed over like any other, and its head is never stamped.
        let trashed = try makeEntry()
        try SearchCaptureFixture.writeCanonical(trashed.directory, n: 1, spans: ["delta trashed"])
        try EntryMetadataStore.write(EntryMetadata(trashedAt: Date(timeIntervalSince1970: 2_000)),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: trashed.directory))
        // The live log only.
        let liveOnly = try makeEntry()
        try SearchCaptureFixture.writeLiveLog(liveOnly.directory, records: ["epsilon live", "log"])
        // An undecodable revision beside a readable log.
        let damaged = try makeEntry()
        try SearchCaptureFixture.writeLiveLog(damaged.directory, records: ["zeta fallback"])
        try SearchCaptureFixture.writeUndecodableCanonical(damaged.directory, n: 1)
        // Nothing to index: an empty log, an undecodable revision alone, an empty directory.
        try SearchCaptureFixture.writeLiveLog(try makeEntry().directory, records: [])
        try SearchCaptureFixture.writeUndecodableCanonical(try makeEntry().directory, n: 1)
        _ = try makeEntry()
        // Unreadable: counted failed on every pass.
        let sealed = try makeEntry()
        try SearchCaptureFixture.writeLiveLog(sealed.directory, records: ["eta sealed"])
        try SearchCaptureFixture.sealLiveLog(sealed.directory)

        // The index is a sibling of captures/, as in the app.
        let index = try SearchIndex(databaseURL: AppContainer.searchIndexURL(containerRoot: root))
        let indexer = SearchIndexer(index: index)

        let before = try snapshot(capturesRoot)
        XCTAssertGreaterThan(before.count, 25, "fixture sanity: the snapshot covers the fixture tree")
        XCTAssertNotNil(before["\(trusted.captureID)/transcript/head.json"], "fixture sanity: a head was persisted")

        let cold = await indexer.reconcile(entries)
        let afterCold = try snapshot(capturesRoot)
        let warm = await indexer.reconcile(entries)
        let afterWarm = try snapshot(capturesRoot)

        // The passes really did read these directories.
        XCTAssertEqual(cold, .init(indexed: 6, removed: 0, unchanged: 0, failed: 1))
        XCTAssertEqual(warm, .init(indexed: 0, removed: 0, unchanged: 6, failed: 1))
        let found = try await ids(index, "gamma")
        XCTAssertEqual(found, [stale.captureID])

        XCTAssertEqual(differences(before, afterCold), [], "the cold pass changed these paths under captures/")
        XCTAssertEqual(differences(before, afterWarm), [], "the warm pass changed these paths under captures/")

        // Control: the snapshot does see a write, a growth and a new file.
        try Data("x".utf8).write(to: liveOnly.directory.appendingPathComponent("stray"))
        let handle = try FileHandle(forWritingTo: SegmentLayout.liveTranscriptURL(captureDirectory: damaged.directory))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let changed = differences(before, try snapshot(capturesRoot))
        XCTAssertTrue(changed.contains("\(liveOnly.captureID)/stray"), "a new file")
        XCTAssertTrue(changed.contains("\(liveOnly.captureID)"), "its directory's modification date")
        XCTAssertTrue(changed.contains("\(damaged.captureID)/transcript/live.jsonl"), "a file that grew")
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
