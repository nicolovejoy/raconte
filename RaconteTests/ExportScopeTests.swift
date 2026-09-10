import XCTest
@testable import Raconte

/// #157: the pure scope value and the inventory the confirmation sheet renders.
final class ExportScopeTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        containerRoot = base.appendingPathComponent("RaconteExportScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: Fixture helpers (shape copied from ArchiveExporterTests — do not import across files)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func writeCapture(_ id: String, journalID: String?) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try EntryMetadataStore.encode(EntryMetadata(journalID: journalID))
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeCaptureWithoutSidecar(_ id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
    }

    private func writeCaptureWithGarbageSidecar(_ id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    // MARK: ExportScope.includes

    func testAllIncludesEveryBucket() {
        let a = ULID.make()
        XCTAssertTrue(ExportScope.all.includes(bucket: a))
        XCTAssertTrue(ExportScope.all.includes(bucket: nil))
    }

    func testSelectedIncludesOnlyChosenJournalsAndTheUnfiledFlagDecidesNil() {
        let a = ULID.make(), b = ULID.make()
        let withoutUnfiled = ExportScope.selected(journalIDs: [a], includeUnfiled: false)
        XCTAssertTrue(withoutUnfiled.includes(bucket: a))
        XCTAssertFalse(withoutUnfiled.includes(bucket: b))
        XCTAssertFalse(withoutUnfiled.includes(bucket: nil))

        // Mutation proof: flipping ONLY the flag flips ONLY the nil bucket.
        let withUnfiled = ExportScope.selected(journalIDs: [a], includeUnfiled: true)
        XCTAssertTrue(withUnfiled.includes(bucket: a))
        XCTAssertFalse(withUnfiled.includes(bucket: b))
        XCTAssertTrue(withUnfiled.includes(bucket: nil))
    }

    // MARK: ExportInventory.bucket (ruling 3)

    func testBucketResolvesUnknownAndNilJournalsToUnfiled() {
        let a = ULID.make(), orphan = ULID.make()
        XCTAssertEqual(ExportInventory.bucket(journalID: a, known: [a]), a)
        XCTAssertNil(ExportInventory.bucket(journalID: orphan, known: [a]))
        XCTAssertNil(ExportInventory.bucket(journalID: nil, known: [a]))
    }

    // MARK: ExportInventory.read

    func testInventoryCountsPerJournalAndUnfiledInRegistryOrder() throws {
        let alpha = Journal(id: ULID.make(), name: "Alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let beta = Journal(id: ULID.make(), name: "Beta", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        try writeJournals([alpha, beta])
        try writeCapture(ULID.make(), journalID: alpha.id)
        try writeCapture(ULID.make(), journalID: alpha.id)
        try writeCapture(ULID.make(), journalID: beta.id)
        try writeCapture(ULID.make(), journalID: nil)              // unfiled: nil
        try writeCapture(ULID.make(), journalID: ULID.make())      // unfiled: orphan journal
        try writeCaptureWithoutSidecar(ULID.make())                // unfiled: no sidecar
        try writeCaptureWithGarbageSidecar(ULID.make())            // unfiled: unreadable

        let inventory = try ExportInventory.read(containerRoot: containerRoot)

        XCTAssertEqual(inventory.journals, [
            ExportInventory.JournalRow(id: alpha.id, name: "Alpha", entryCount: 2),
            ExportInventory.JournalRow(id: beta.id, name: "Beta", entryCount: 1),
        ])
        XCTAssertEqual(inventory.unfiledCount, 4)
        XCTAssertEqual(inventory.totalEntries, 7)

        XCTAssertEqual(inventory.entryCount(for: .all), 7)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [alpha.id], includeUnfiled: false)), 2)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [beta.id], includeUnfiled: true)), 5)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [], includeUnfiled: false)), 0)
    }

    func testInventoryWithNoJournalsFileHasNoRowsAndEverythingUnfiled() throws {
        try writeCapture(ULID.make(), journalID: ULID.make())
        try writeCaptureWithoutSidecar(ULID.make())

        let inventory = try ExportInventory.read(containerRoot: containerRoot)

        XCTAssertEqual(inventory.journals, [])
        XCTAssertEqual(inventory.unfiledCount, 2)
        XCTAssertEqual(inventory.totalEntries, 2)
    }

    func testInventoryOnAMissingContainerRootThrows() {
        let missing = containerRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try ExportInventory.read(containerRoot: missing))
    }
}
