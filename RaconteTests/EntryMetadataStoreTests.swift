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
                                     originalDate: PartialDate(year: 1986, month: 11, day: 6),
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
                                        originalDate: PartialDate(year: 1970, month: 1, day: 1)),
                          captureID: captureID)
        let updated = try await s.update(captureID: captureID) {
            $0.trashedAt = Date(timeIntervalSince1970: 200)
        }
        XCTAssertEqual(updated.journalID, "J1")
        XCTAssertEqual(updated.originalDate, PartialDate(year: 1970, month: 1, day: 1))
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
        let backdated = PartialDate(year: 1986, month: 11, day: 6)
        XCTAssertEqual(EntryMetadata().effectiveDate(capturedAt: captured), captured)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(EntryMetadata(originalDate: backdated).effectiveDate(capturedAt: captured, calendar: calendar),
                       backdated.anchorDate(calendar: calendar))
    }

    /// The one anchor rule (`PartialDate.anchorDate`): year precision collapses to Jan 1,
    /// year+month to the 1st, at noon. Anchored on a date squarely mid-month so the
    /// calendar math is unambiguous.
    func testEffectiveDateNormalizesToPrecision() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let captured = Date(timeIntervalSince1970: 1_700_000_000)

        let dayEntry = EntryMetadata(originalDate: PartialDate(year: 1987, month: 6, day: 15))
        let dayExpected = calendar.date(from: DateComponents(year: 1987, month: 6, day: 15, hour: 12))!
        XCTAssertEqual(dayEntry.effectiveDate(capturedAt: captured, calendar: calendar), dayExpected)

        let monthEntry = EntryMetadata(originalDate: PartialDate(year: 1987, month: 6))
        let monthStart = calendar.date(from: DateComponents(year: 1987, month: 6, day: 1, hour: 12))!
        XCTAssertEqual(monthEntry.effectiveDate(capturedAt: captured, calendar: calendar), monthStart)

        let yearEntry = EntryMetadata(originalDate: PartialDate(year: 1987))
        let yearStart = calendar.date(from: DateComponents(year: 1987, month: 1, day: 1, hour: 12))!
        XCTAssertEqual(yearEntry.effectiveDate(capturedAt: captured, calendar: calendar), yearStart)
    }

    func testFormattedRendersByPrecision() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        XCTAssertEqual(PartialDate(year: 1998).formatted(calendar: calendar), "1998")
        XCTAssertEqual(PartialDate(year: 1998, month: 3).formatted(calendar: calendar), "March 1998")
        // `.day` defers to the platform's standard date formatting — pinned only to the
        // components it must contain, not to an exact locale-dependent string.
        let dayText = PartialDate(year: 1998, month: 3, day: 4).formatted(calendar: calendar)
        XCTAssertTrue(dayText.contains("1998"))
        XCTAssertTrue(dayText.contains("4") || dayText.contains("04"))
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

    // MARK: Precision (M3 issue #14 part 1)

    func testPrecisionRoundTrips() async throws {
        let metadata = EntryMetadata(originalDate: PartialDate(year: 1986, month: 11))
        let s = store()
        try await s.write(metadata, captureID: captureID)
        let readBack = try await s.read(captureID: captureID)
        XCTAssertEqual(readBack, metadata)
        XCTAssertEqual(readBack.originalDate?.precision, .yearMonth)
    }

    // MARK: Old-format decode compatibility (M3 issue #14 part 2)

    /// An older sidecar with a legacy ISO8601 `originalDate` and no `precision` key must
    /// decode as `.day` — the only precision that field ever had before #14 part 1.
    func testOldFormatMissingPrecisionDecodesAsDay() throws {
        let legacyString = "1986-11-06T00:00:00.000Z"
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"journalID":"J1","originalDate":"\#(legacyString)"}"#.utf8))
        // Truncated in the *local* calendar — same conversion the legacy `.day`-precision
        // sidecar always implied, and the same rule `init(from:precision:calendar:)` uses
        // everywhere else. Computed rather than hardcoded so this test doesn't depend on
        // the machine's timezone offset from UTC.
        let legacyInstant = CaptureCoding.iso8601Formatter().date(from: legacyString)!
        let expected = PartialDate(from: legacyInstant, precision: .day, calendar: .gregorianCurrent)
        XCTAssertEqual(decoded.originalDate, expected)
        XCTAssertEqual(decoded.effectivePrecision, .day)
    }

    /// An older sidecar with both the legacy ISO8601 `originalDate` and a `precision` key
    /// decodes to the equivalent `PartialDate`, truncated to that precision.
    func testOldFormatWithExplicitPrecisionDecodesToEquivalentPartialDate() throws {
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"journalID":"J1","originalDate":"1986-11-06T12:00:00.000Z","precision":"yearMonth"}"#.utf8))
        XCTAssertEqual(decoded.originalDate, PartialDate(year: 1986, month: 11))
    }

    /// Reading an old-format sidecar and re-encoding it upgrades it in place: the new
    /// string form, no `precision` key, no separate migration pass.
    func testOldFormatUpgradesToNewStringFormOnReencode() throws {
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"originalDate":"1986-11-06T00:00:00.000Z","precision":"year"}"#.utf8))
        let reencoded = String(decoding: try EntryMetadataStore.encode(decoded), as: UTF8.self)
        XCTAssertEqual(reencoded, #"{"originalDate":"1986"}"#)
    }

    /// A garbage `originalDate` string — neither a partial-date grammar nor a legacy
    /// ISO8601 instant — is damage, not an older file: the identity-like field throws
    /// rather than silently becoming "not backdated".
    func testGarbageOriginalDateStringThrows() throws {
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"originalDate":"not-a-date"}"#.utf8)))
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"originalDate":"1998-3"}"#.utf8)))
        XCTAssertThrowsError(try EntryMetadataStore.decode(Data(#"{"originalDate":"1998-02-30"}"#.utf8)))
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
