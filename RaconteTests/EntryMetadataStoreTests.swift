import XCTest
@testable import Raconte

/// M3 T1: `entry.json` — absent means defaults, damaged means an error, writes are
/// atomic, and the decoder is lenient in the one direction that matters.
final class EntryMetadataStoreTests: XCTestCase {

    private var capturesRoot: URL!
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteEntryMeta-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var sidecarURL: URL {
        SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
    }

    private func store() -> EntryMetadataStore { EntryMetadataStore(capturesRoot: capturesRoot) }

    @discardableResult
    private func writeRaw(_ json: String) throws -> URL {
        try Data(json.utf8).write(to: sidecarURL)
        return sidecarURL
    }

    // MARK: Absent vs. corrupt

    func testAbsentSidecarReadsAsDefaultsNotAnError() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        let metadata = try await store().read(captureID: captureID)
        XCTAssertEqual(metadata, .defaults)
        XCTAssertNil(metadata.journalID)
        XCTAssertNil(metadata.originalDate)
        XCTAssertNil(metadata.trashedAt)
        XCTAssertTrue(metadata.isDefault)
        XCTAssertFalse(metadata.isTrashed)
    }

    func testEmptyObjectIsDefaults() throws {
        XCTAssertEqual(try EntryMetadataStore.decode(Data("{}".utf8)), .defaults)
    }

    func testUnparseableSidecarThrows() async throws {
        try writeRaw("{ not json")
        do {
            _ = try await store().read(captureID: captureID)
            XCTFail("expected unreadable")
        } catch {
            guard case .unreadable = (error as? EntryMetadataError) else {
                return XCTFail("expected EntryMetadataError.unreadable, got \(error)")
            }
        }
    }

    /// The subtle half of absent-vs-corrupt: a key present with the wrong type is damage,
    /// not an older file. Answering "not trashed" for a tombstone we failed to parse
    /// would un-delete the entry once T5 ships.
    func testWrongTypedFieldThrowsRatherThanFallingBackToDefaults() throws {
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"journalID":5}"#.utf8)))
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"trashedAt":"not-a-date"}"#.utf8)))
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"originalDate":17}"#.utf8)))
    }

    /// An unreadable file is not an absent one. `fileReadNoSuchFile` is the *only* error
    /// that means "nothing here" — a permissions failure must not read as defaults.
    func testUnreadableFileIsNotTreatedAsAbsent() throws {
        try writeRaw("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecarURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: sidecarURL.path) }
        // Running as root (some CI images) makes the file readable regardless; skip then.
        guard !FileManager.default.isReadableFile(atPath: sidecarURL.path) else {
            throw XCTSkip("running with privileges that ignore file permissions")
        }
        XCTAssertThrowsError(try EntryMetadataStore.read(url: sidecarURL)) {
            guard case .unreadable = ($0 as? EntryMetadataError) else {
                return XCTFail("expected unreadable, got \($0)")
            }
        }
    }

    // MARK: Round trip

    func testEveryFieldSurvivesTheRoundTrip() async throws {
        let metadata = EntryMetadata(journalID: "JOURNAL1",
                                     originalDate: Date(timeIntervalSince1970: 533_433_600.125),
                                     trashedAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        let s = store()
        try await s.write(metadata, captureID: captureID)
        let readBack = try await s.read(captureID: captureID)
        XCTAssertEqual(readBack, metadata)
        let freshStore = try await EntryMetadataStore(capturesRoot: capturesRoot)
            .read(captureID: captureID)
        XCTAssertEqual(freshStore, metadata)
    }

    func testUpdateChangesOneFieldAndPreservesTheRest() async throws {
        let s = store()
        try await s.write(EntryMetadata(journalID: "J1",
                                        originalDate: Date(timeIntervalSince1970: 100)),
                          captureID: captureID)
        let updated = try await s.update(captureID: captureID) {
            $0.trashedAt = Date(timeIntervalSince1970: 200)
        }
        XCTAssertEqual(updated.journalID, "J1")
        XCTAssertEqual(updated.originalDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(updated.trashedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(updated.isTrashed)
        let persisted = try await s.read(captureID: captureID)
        XCTAssertEqual(persisted, updated)
    }

    func testUpdateOnAnAbsentSidecarStartsFromDefaults() async throws {
        let updated = try await store().update(captureID: captureID) { $0.journalID = "J1" }
        XCTAssertEqual(updated, EntryMetadata(journalID: "J1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: The default is a semantic, not a value

    func testNilOriginalDateIsNotMaterializedOnDisk() async throws {
        try await store().write(EntryMetadata(journalID: "J1"), captureID: captureID)
        let text = String(decoding: try Data(contentsOf: sidecarURL), as: UTF8.self)
        XCTAssertEqual(text, #"{"journalID":"J1"}"#)
        XCTAssertFalse(text.contains("originalDate"))
        XCTAssertFalse(text.contains("trashedAt"))
    }

    func testDefaultsEncodeToAnEmptyObject() throws {
        XCTAssertEqual(String(decoding: try EntryMetadataStore.encode(.defaults), as: UTF8.self), "{}")
    }

    func testEffectiveDatePrefersTheBackdateAndOtherwiseTheCapture() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let backdated = Date(timeIntervalSince1970: 533_433_600)
        XCTAssertEqual(EntryMetadata().effectiveDate(capturedAt: captured), captured)
        XCTAssertEqual(EntryMetadata(originalDate: backdated).effectiveDate(capturedAt: captured),
                       backdated)
    }

    // MARK: Decoder rule (§11)

    /// Additive fields are lenient in both directions: a file written before a field
    /// existed still reads, and a file from a newer build with extra keys still reads.
    func testDecoderIsLenientAboutMissingAndUnknownKeys() throws {
        let older = try EntryMetadataStore.decode(Data(#"{"journalID":"J1"}"#.utf8))
        XCTAssertEqual(older, EntryMetadata(journalID: "J1"))

        let newer = try EntryMetadataStore.decode(
            Data(#"{"journalID":"J1","favourite":true,"tags":["a"]}"#.utf8))
        XCTAssertEqual(newer, EntryMetadata(journalID: "J1"))
    }

    /// Regression pin for the hazard itself: synthesis ignores property defaults, so a
    /// synthesized decoder would reject `{}` outright. If someone deletes the hand-written
    /// `init(from:)`, this fails.
    func testSynthesizedDecoderWouldHaveRejectedTheAllDefaultsFile() throws {
        XCTAssertNoThrow(try EntryMetadataStore.decode(Data("{}".utf8)))
    }

    // MARK: Atomic write

    func testWriteIsAtomicAndLeavesNoPartFile() async throws {
        let s = store()
        try await s.write(EntryMetadata(journalID: "first"), captureID: captureID)
        try await s.write(EntryMetadata(journalID: "second"), captureID: captureID)
        let latest = try await s.read(captureID: captureID)
        XCTAssertEqual(latest.journalID, "second")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.partURL(for: sidecarURL).path))
    }

    /// A kill between the `.part` write and the rename leaves the previous sidecar whole.
    func testCrashBeforeRenameLeavesThePreviousSidecarIntact() throws {
        struct Boom: Error {}
        try EntryMetadataStore.write(EntryMetadata(journalID: "first"), url: sidecarURL)
        XCTAssertThrowsError(try AtomicFile.replace(
            at: sidecarURL,
            writing: try EntryMetadataStore.encode(EntryMetadata(journalID: "second")),
            beforeRename: { throw Boom() }))
        XCTAssertEqual(try EntryMetadataStore.read(url: sidecarURL).journalID, "first")
    }

    func testSidecarSitsBesideTheManifestInsideTheCaptureDirectory() {
        XCTAssertEqual(sidecarURL, captureDirectory.appendingPathComponent("entry.json"))
        XCTAssertEqual(sidecarURL.deletingLastPathComponent().standardizedFileURL,
                       SegmentLayout.manifestURL(captureDirectory: captureDirectory)
                           .deletingLastPathComponent().standardizedFileURL)
    }
}

/// M3 T1: the current-journal preference.
final class CurrentJournalTests: XCTestCase {

    private func journal(_ id: String, _ name: String = "J") -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSelectionPersistsAndResolvesAgainstTheRegistry() {
        let prefs = InMemoryJournalPreferenceStore()
        let registry = JournalRegistry(journals: [journal("A"), journal("B", "Trip")])

        let current = CurrentJournal(store: prefs)
        XCTAssertNil(current.storedID)
        XCTAssertNil(current.resolve(in: registry))

        current.select(journal("B", "Trip"))
        // A separate instance over the same storage — this is a persisted preference.
        XCTAssertEqual(CurrentJournal(store: prefs).resolve(in: registry)?.name, "Trip")
        XCTAssertEqual(CurrentJournal(store: prefs).storedID, "B")
    }

    func testDanglingIDResolvesToNilWithoutErasingTheStoredValue() {
        let prefs = InMemoryJournalPreferenceStore()
        let current = CurrentJournal(store: prefs)
        current.select("GONE")
        XCTAssertNil(current.resolve(in: JournalRegistry(journals: [journal("A")])))
        XCTAssertEqual(current.storedID, "GONE", "kept — the journal may arrive via sync")
        XCTAssertEqual(current.resolve(in: JournalRegistry(journals: [journal("GONE", "Back")]))?.name,
                       "Back")
    }

    func testSelectingNilClearsTheStoredValue() {
        let prefs = InMemoryJournalPreferenceStore()
        let current = CurrentJournal(store: prefs)
        current.select("A")
        current.select(nil)
        XCTAssertNil(current.storedID)
    }

    func testEmptyStoredValueIsTreatedAsUnset() {
        let prefs = InMemoryJournalPreferenceStore(values: [CurrentJournal.defaultsKey: ""])
        XCTAssertNil(CurrentJournal(store: prefs).storedID)
    }

    func testRealUserDefaultsBackingRoundTrips() throws {
        let suiteName = "RaconteCurrentJournalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let current = CurrentJournal(store: UserDefaultsJournalPreferenceStore(defaults: defaults))
        current.select("A")
        XCTAssertEqual(defaults.string(forKey: CurrentJournal.defaultsKey), "A")
        XCTAssertEqual(current.storedID, "A")
        current.select(nil)
        XCTAssertNil(defaults.string(forKey: CurrentJournal.defaultsKey))
    }
}

/// The ULID minter moved out of `CaptureCoordinator`; its behaviour must not have.
final class ULIDTests: XCTestCase {
    func testShapeAndSortability() {
        let early = ULID.make(now: Date(timeIntervalSince1970: 1_000))
        let late = ULID.make(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(early.count, 26)
        XCTAssertTrue(ULID.isWellFormed(early))
        XCTAssertTrue(early < late, "time-prefixed IDs sort chronologically")
        XCTAssertNotEqual(ULID.make(), ULID.make())
    }

    func testCaptureCoordinatorStillMintsTheSameThing() {
        let now = Date(timeIntervalSince1970: 1_234_567.891)
        let head = { (id: String) in String(id.prefix(10)) }
        XCTAssertEqual(head(CaptureCoordinator.makeULID(now: now)), head(ULID.make(now: now)))
        XCTAssertEqual(FinishedRecording.timestamp(fromULID: ULID.make(now: now))
                        .map { ($0.timeIntervalSince1970 * 1000).rounded() },
                       (now.timeIntervalSince1970 * 1000).rounded())
    }

    func testMalformedIDsAreRejected() {
        XCTAssertFalse(ULID.isWellFormed("short"))
        XCTAssertFalse(ULID.isWellFormed("UUUUUUUUUU0000000000000000"))   // U not in Crockford
        XCTAssertFalse(ULID.isWellFormed(String(repeating: "0", count: 27)))
    }
}
