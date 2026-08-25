import XCTest
@testable import Raconte

/// M4 T2: `sync/` is a disposable cache beside `captures/` — CKSyncEngine's opaque
/// state, per-record system fields, and a local upload-dedupe ledger. The governing rule
/// under test throughout: absent and unreadable both collapse to nil/empty, never a
/// throw, because nothing here is ground truth (see `SyncBookkeepingStore`'s doc
/// comment) — unlike `JournalStore`/`EntryMetadataStore`, which throw on unreadable to
/// avoid resurrecting real content behind a parse failure.
final class SyncBookkeepingTests: XCTestCase {

    private var containerRoot: URL!
    private var syncRoot: URL!

    override func setUpWithError() throws {
        // Resolve symlinks on the fixture root — this laptop's /var vs /private/var
        // symlink shape has burned this repo before (see BuildStampTests).
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncBookkeeping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        syncRoot = AppContainer.syncRoot(containerRoot: containerRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func store() -> SyncBookkeepingStore {
        SyncBookkeepingStore(root: syncRoot)
    }

    // MARK: Path math (AppContainer)

    func testSyncRootSitsBesideCapturesNotInsideIt() {
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        XCTAssertEqual(syncRoot, containerRoot.appendingPathComponent("sync", isDirectory: true))
        XCTAssertFalse(syncRoot.path.hasPrefix(capturesRoot.path),
                       "a stray file under captures/ would be walked by DirectorySnapshot.gather")
    }

    // MARK: Path math (SyncBookkeepingStore)

    func testEngineStateURLLayout() {
        XCTAssertEqual(SyncBookkeepingStore.engineStateURL(root: syncRoot),
                       syncRoot.appendingPathComponent("engine-state.bin"))
    }

    func testSystemFieldsURLLayoutForDottedRecordName() {
        let recordName = "a.01ARZ3NDEKTSV4RRFFQ69G5FAV.0"
        XCTAssertEqual(SyncBookkeepingStore.systemFieldsURL(root: syncRoot, recordName: recordName),
                       syncRoot.appendingPathComponent("system-fields", isDirectory: true)
                           .appendingPathComponent("\(recordName).bin"))
    }

    func testLedgerURLLayout() {
        XCTAssertEqual(SyncBookkeepingStore.ledgerURL(root: syncRoot),
                       syncRoot.appendingPathComponent("ledger.json"))
    }

    // MARK: Engine state

    func testEngineStateAbsentIsNil() async {
        let absent = await store().engineState()
        XCTAssertNil(absent)
    }

    func testEngineStateRoundTripsThroughDisk() async throws {
        let s = store()
        let blob = Data([0x01, 0x02, 0xFF, 0x00, 0x7A])
        try await s.saveEngineState(blob)
        let read = await s.engineState()
        XCTAssertEqual(read, blob)

        // A fresh store over the same root reads the same bytes back.
        let reread = await SyncBookkeepingStore(root: syncRoot).engineState()
        XCTAssertEqual(reread, blob)
    }

    func testEngineStateSecondSaveOverwritesTheFirst() async throws {
        let s = store()
        try await s.saveEngineState(Data([0x01]))
        try await s.saveEngineState(Data([0x02, 0x03]))
        let read = await s.engineState()
        XCTAssertEqual(read, Data([0x02, 0x03]))
    }

    func testEngineStateWhenPathIsUnreadableIsNilNotThrow() async throws {
        // A directory where the file should be: exists on disk but can't be read as
        // Data — the "unreadable" half of "absent and unreadable both collapse to nil",
        // distinct from the plain-absent case above.
        let url = SyncBookkeepingStore.engineStateURL(root: syncRoot)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let read = await store().engineState()
        XCTAssertNil(read)
    }

    func testSaveEngineStateLeavesNoStrayPartFile() async throws {
        let s = store()
        try await s.saveEngineState(Data([0x01]))
        let url = SyncBookkeepingStore.engineStateURL(root: syncRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SegmentLayout.partURL(for: url).path))
    }

    // MARK: System fields

    func testSystemFieldsAbsentIsNil() async {
        let missing = await store().systemFields(for: "a.01ARZ3NDEKTSV4RRFFQ69G5FAV.0")
        XCTAssertNil(missing)
    }

    func testSystemFieldsRoundTripsForDottedRecordName() async throws {
        let s = store()
        let recordName = "a.01ARZ3NDEKTSV4RRFFQ69G5FAV.0"
        let blob = Data("system-fields-blob".utf8)

        try await s.saveSystemFields(blob, for: recordName)
        let read = await s.systemFields(for: recordName)
        XCTAssertEqual(read, blob)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SyncBookkeepingStore.systemFieldsURL(root: syncRoot, recordName: recordName).path))
    }

    func testSystemFieldsRoundTripsForMergeRecordNameShape() async throws {
        // T3's merge-record shape: two dotted ULIDs, still one filename component.
        let recordName = "m.01ARZ3NDEKTSV4RRFFQ69G5FAV.01BRZ3NDEKTSV4RRFFQ69G5FAW"
        let s = store()
        let blob = Data("merge-blob".utf8)
        try await s.saveSystemFields(blob, for: recordName)
        let read = await s.systemFields(for: recordName)
        XCTAssertEqual(read, blob)
    }

    func testSystemFieldsForOneRecordDoesNotAffectAnother() async throws {
        let s = store()
        try await s.saveSystemFields(Data("one".utf8), for: "a.RECORDONE.0")
        try await s.saveSystemFields(Data("two".utf8), for: "a.RECORDTWO.0")
        let one = await s.systemFields(for: "a.RECORDONE.0")
        let two = await s.systemFields(for: "a.RECORDTWO.0")
        XCTAssertEqual(one, Data("one".utf8))
        XCTAssertEqual(two, Data("two".utf8))
    }

    func testDeleteSystemFieldsRemovesTheFile() async throws {
        let s = store()
        let recordName = "a.RECORDONE.0"
        try await s.saveSystemFields(Data("bytes".utf8), for: recordName)
        try await s.deleteSystemFields(for: recordName)
        let read = await s.systemFields(for: recordName)
        XCTAssertNil(read)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SyncBookkeepingStore.systemFieldsURL(root: syncRoot, recordName: recordName).path))
    }

    func testDeleteSystemFieldsForAbsentRecordIsNotAnError() async throws {
        try await store().deleteSystemFields(for: "never-saved.0")
    }

    // MARK: Upload ledger

    func testLedgerEmptyInitially() async {
        let ledger = await store().ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testRecordUploadThenLedgerContainsTheDigest() async throws {
        let s = store()
        let digest = UploadedDigest(sha256: "abc123", bytes: 42)
        try await s.recordUpload(digest, for: "a.RECORDONE.0")
        let ledger = await s.ledger()
        XCTAssertEqual(ledger["a.RECORDONE.0"], digest)
    }

    func testRecordUploadForASecondRecordDoesNotClobberTheFirst() async throws {
        let s = store()
        try await s.recordUpload(UploadedDigest(sha256: "aaa", bytes: 1), for: "a.RECORDONE.0")
        try await s.recordUpload(UploadedDigest(sha256: "bbb", bytes: 2), for: "a.RECORDTWO.0")
        let ledger = await s.ledger()
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger["a.RECORDONE.0"], UploadedDigest(sha256: "aaa", bytes: 1))
        XCTAssertEqual(ledger["a.RECORDTWO.0"], UploadedDigest(sha256: "bbb", bytes: 2))
    }

    func testRecordUploadOverwritesAnExistingDigestForTheSameRecord() async throws {
        let s = store()
        try await s.recordUpload(UploadedDigest(sha256: "old", bytes: 1), for: "a.RECORDONE.0")
        try await s.recordUpload(UploadedDigest(sha256: "new", bytes: 2), for: "a.RECORDONE.0")
        let ledger = await s.ledger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger["a.RECORDONE.0"], UploadedDigest(sha256: "new", bytes: 2))
    }

    func testClearUploadRemovesTheEntryFromTheLedger() async throws {
        let s = store()
        try await s.recordUpload(UploadedDigest(sha256: "abc", bytes: 3), for: "a.RECORDONE.0")
        try await s.clearUpload(for: "a.RECORDONE.0")
        let ledger = await s.ledger()
        XCTAssertNil(ledger["a.RECORDONE.0"])
        XCTAssertTrue(ledger.isEmpty)
    }

    func testClearUploadForAnUnknownRecordIsNotAnError() async throws {
        try await store().clearUpload(for: "never-recorded.0")
    }

    func testLedgerPersistsAcrossFreshStoreInstances() async throws {
        try await store().recordUpload(UploadedDigest(sha256: "abc", bytes: 3), for: "a.RECORDONE.0")
        let reread = await SyncBookkeepingStore(root: syncRoot).ledger()
        XCTAssertEqual(reread["a.RECORDONE.0"], UploadedDigest(sha256: "abc", bytes: 3))
    }

    func testLedgerGarbageBytesReturnsEmptyNotThrow() async throws {
        // The three-outcome collapse applies to the ledger's decode failure too, not
        // just a missing file — feed it bytes that are on-disk but not valid JSON.
        let url = SyncBookkeepingStore.ledgerURL(root: syncRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let ledger = await store().ledger()
        XCTAssertTrue(ledger.isEmpty)
    }

    // MARK: Wipe

    func testWipeRemovesEngineStateSystemFieldsAndLedger() async throws {
        let s = store()
        try await s.saveEngineState(Data([0x01]))
        try await s.saveSystemFields(Data("bytes".utf8), for: "a.RECORDONE.0")
        try await s.recordUpload(UploadedDigest(sha256: "abc", bytes: 3), for: "a.RECORDONE.0")

        try await s.wipe()

        let engineState = await s.engineState()
        let fields = await s.systemFields(for: "a.RECORDONE.0")
        let ledger = await s.ledger()
        XCTAssertNil(engineState)
        XCTAssertNil(fields)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncRoot.path))
    }

    func testWipeOnANeverCreatedSyncDirectoryIsNotAnError() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncRoot.path))
        try await store().wipe()
    }

    func testWipeThenFreshWritesWorkAgain() async throws {
        let s = store()
        try await s.saveEngineState(Data([0x01]))
        try await s.wipe()
        try await s.saveEngineState(Data([0x02]))
        let read = await s.engineState()
        XCTAssertEqual(read, Data([0x02]))
    }

    // MARK: #90 environment tag

    func testEnvironmentTagRoundTrips() async throws {
        let s = store()
        let initial = await s.environmentTag()
        XCTAssertNil(initial)
        try await s.saveEnvironmentTag(.development)
        let read = await s.environmentTag()
        XCTAssertEqual(read, .development)
    }

    func testUnreadableTagIsNil() async throws {
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        try Data([0xff, 0xfe]).write(to: SyncBookkeepingStore.environmentTagURL(root: syncRoot))
        let read = await store().environmentTag()
        XCTAssertNil(read)
    }

    func testWipeRemovesTag() async throws {
        let s = store()
        try await s.saveEnvironmentTag(.production)
        try await s.wipe()
        let read = await s.environmentTag()
        XCTAssertNil(read)
    }

    func testHasBookkeepingTracksRootExistence() async throws {
        let s = store()
        let before = await s.hasBookkeeping()
        XCTAssertFalse(before)
        try await s.recordUpload(UploadedDigest(sha256: "aa", bytes: 1), for: "e.X")
        let after = await s.hasBookkeeping()
        XCTAssertTrue(after)
    }
}
