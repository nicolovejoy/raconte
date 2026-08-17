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

    /// M4 T1: a fixed, millisecond-safe clock by default (not real `Date()`) — the sync
    /// stamps `update` now writes go through the same millisecond-precision ISO8601
    /// round trip every other Date field on this type does, and a sub-millisecond real
    /// timestamp does not survive that round trip byte-for-byte. Tests that need to see
    /// the clock *advance* between two writes pass their own `now:` (frozen-clock trap —
    /// see the standing house rule).
    private static let defaultNow = Date(timeIntervalSince1970: 1_650_000_000)

    private func store(now: @escaping @Sendable () -> Date = { EntryMetadataStoreTests.defaultNow })
    -> EntryMetadataStore {
        EntryMetadataStore(capturesRoot: capturesRoot, now: now)
    }

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
        try EntryMetadataStore.write(metadata, url: sidecarURL)
        let readBack = try await s.read(captureID: captureID)
        XCTAssertEqual(readBack, metadata)
        let freshStore = try await EntryMetadataStore(capturesRoot: capturesRoot)
            .read(captureID: captureID)
        XCTAssertEqual(freshStore, metadata)
    }

    func testUpdateChangesOneFieldAndPreservesTheRest() async throws {
        let s = store()
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1",
                                                    originalDate: PartialDate(year: 1970, month: 1, day: 1)),
                                     url: sidecarURL)
        let (updated, _) = try await s.update(captureID: captureID) {
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
        let (updated, _) = try await store().update(captureID: captureID) { $0.journalID = "J1" }
        XCTAssertEqual(updated.journalID, "J1")
        // M4 T1: `update` now stamps the field it actually changed.
        XCTAssertEqual(updated.modified, ["journalID": EntryMetadataStoreTests.defaultNow])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: captureMissing (#25 step 3)

    /// RED. `update`'s read-modify-write creates intermediate directories today (via
    /// `write`'s `createDirectory`), so an edit against a capture that has been staged
    /// away can resurrect it. The guard refuses instead.
    func testUpdateOnAMissingCaptureDirectoryThrowsRatherThanCreatingIt() async throws {
        try FileManager.default.removeItem(at: captureDirectory)
        do {
            _ = try await store().update(captureID: captureID) { $0.journalID = "J1" }
            XCTFail("expected captureMissing")
        } catch {
            guard case .captureMissing = (error as? EntryMetadataError) else {
                return XCTFail("expected EntryMetadataError.captureMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    /// GUARD. The capture directory exists but `entry.json` does not — the normal
    /// first-write path, since every capture starts without a sidecar. **Mutation:**
    /// make the guard require `entry.json`'s existence rather than the directory's ->
    /// must fail, because getting this wrong breaks journal filing on the capture path.
    func testUpdateStillWritesWhenTheDirectoryExistsWithNoSidecar() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        let (updated, _) = try await store().update(captureID: captureID) { $0.journalID = "J1" }
        XCTAssertEqual(updated.journalID, "J1")
        // M4 T1: `update` now stamps the field it actually changed.
        XCTAssertEqual(updated.modified, ["journalID": EntryMetadataStoreTests.defaultNow])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: The default is a semantic, not a value

    func testNilOriginalDateIsNotMaterializedOnDisk() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)
        let text = String(decoding: try Data(contentsOf: sidecarURL), as: UTF8.self)
        XCTAssertEqual(text, #"{"journalID":"J1"}"#)
        XCTAssertFalse(text.contains("originalDate"))
        XCTAssertFalse(text.contains("trashedAt"))
    }

    /// M4 T1: this is also the `modified` byte-pin — an untouched entry (including a
    /// nil `modified`) still encodes as exactly `{}`, load-bearing for carry-over and
    /// for `journals.json`-style byte-identity.
    func testDefaultsEncodeToAnEmptyObject() throws {
        XCTAssertEqual(String(decoding: try EntryMetadataStore.encode(.defaults), as: UTF8.self), "{}")
    }

    // MARK: setOriginalDate (disallow-future-backdates)
    //
    // Fixed "now" of June 15, 2026 — away from any year boundary, per the house rule
    // that near-epoch/year-boundary backdate fixtures have broken CI under UTC before.

    private var referenceCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    private var referenceNow: Date {
        referenceCalendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }

    func testSetOriginalDateAcceptsToday() {
        var metadata = EntryMetadata.defaults
        let today = PartialDate(year: 2026, month: 6, day: 15)
        XCTAssertTrue(metadata.setOriginalDate(today, now: referenceNow, calendar: referenceCalendar))
        XCTAssertEqual(metadata.originalDate, today)
    }

    func testSetOriginalDateRejectsTomorrow() {
        var metadata = EntryMetadata.defaults
        let tomorrow = PartialDate(year: 2026, month: 6, day: 16)
        XCTAssertFalse(metadata.setOriginalDate(tomorrow, now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(metadata.originalDate)
    }

    func testSetOriginalDateRejectsNextMonth() {
        var metadata = EntryMetadata.defaults
        let nextMonth = PartialDate(year: 2026, month: 7)
        XCTAssertFalse(metadata.setOriginalDate(nextMonth, now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(metadata.originalDate)
    }

    func testSetOriginalDateRejectsNextYear() {
        var metadata = EntryMetadata.defaults
        let nextYear = PartialDate(year: 2027)
        XCTAssertFalse(metadata.setOriginalDate(nextYear, now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(metadata.originalDate)
    }

    func testSetOriginalDateAcceptsCurrentYearAndMonth() {
        var metadata = EntryMetadata.defaults
        XCTAssertTrue(metadata.setOriginalDate(PartialDate(year: 2026), now: referenceNow, calendar: referenceCalendar))
        XCTAssertTrue(metadata.setOriginalDate(PartialDate(year: 2026, month: 6), now: referenceNow, calendar: referenceCalendar))
    }

    /// A rejection leaves the previous value alone — it does not clamp to `now`, which
    /// would silently misrepresent input the owner never entered.
    func testSetOriginalDateRejectionDoesNotClampOrClear() {
        var metadata = EntryMetadata(originalDate: PartialDate(year: 1987, month: 6, day: 2))
        XCTAssertFalse(metadata.setOriginalDate(PartialDate(year: 2027), now: referenceNow, calendar: referenceCalendar))
        XCTAssertEqual(metadata.originalDate, PartialDate(year: 1987, month: 6, day: 2))
    }

    func testSetOriginalDateNilAlwaysClears() {
        var metadata = EntryMetadata(originalDate: PartialDate(year: 1987))
        XCTAssertTrue(metadata.setOriginalDate(nil, now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(metadata.originalDate)
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

    // MARK: multiVoice (T6 §14 step 4)
    //
    // Additive and lenient, like `detectedDate`: every sidecar already on both devices
    // predates the field, and a capture-time voice attribute is not worth taking the
    // journal, backdate and trash state down with it. Encoded only when true, so an
    // all-defaults sidecar stays literally `{}`.

    func testMultiVoiceAbsentDecodesFalse() throws {
        XCTAssertFalse(try EntryMetadataStore.decode(Data("{}".utf8)).multiVoice)
        XCTAssertFalse(try EntryMetadataStore.decode(Data(#"{"journalID":"J1"}"#.utf8)).multiVoice)
    }

    func testMultiVoiceTrueRoundTrips() async throws {
        let metadata = EntryMetadata(journalID: "J1", multiVoice: true)
        let s = store()
        try EntryMetadataStore.write(metadata, url: sidecarURL)
        let readBack = try await s.read(captureID: captureID)
        XCTAssertTrue(readBack.multiVoice)
        XCTAssertEqual(readBack, metadata)
        XCTAssertTrue(String(decoding: try Data(contentsOf: sidecarURL), as: UTF8.self)
            .contains("multiVoice"))
    }

    func testMultiVoiceFalseIsOmittedFromTheSidecar() throws {
        XCTAssertEqual(String(decoding: try EntryMetadataStore.encode(.defaults), as: UTF8.self),
                       "{}")
        let text = String(decoding: try EntryMetadataStore.encode(EntryMetadata(journalID: "J1")),
                          as: UTF8.self)
        XCTAssertFalse(text.contains("multiVoice"))
    }

    func testMultiVoiceGarbageDecodesFalse() throws {
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"journalID":"J1","multiVoice":"yes"}"#.utf8))
        XCTAssertFalse(decoded.multiVoice)
        XCTAssertEqual(decoded.journalID, "J1")
    }

    // MARK: Precision (M3 issue #14 part 1)

    func testPrecisionRoundTrips() async throws {
        let metadata = EntryMetadata(originalDate: PartialDate(year: 1986, month: 11))
        let s = store()
        try EntryMetadataStore.write(metadata, url: sidecarURL)
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
        try EntryMetadataStore.write(EntryMetadata(journalID: "first"), url: sidecarURL)
        try EntryMetadataStore.write(EntryMetadata(journalID: "second"), url: sidecarURL)
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

    // MARK: T7 §7 — update diffs and appends to the audit log (steps 7.2, 7.4, 7.5)

    /// 7.2 (part 1): `update` diffs before/after and appends exactly one record per
    /// changed field, with the field's on-disk string encoding on both sides.
    func testBackdateEditThroughUpdateAppendsExactlyOneRecordWithTheOnDiskEncodings() async throws {
        try EntryMetadataStore.write(
            EntryMetadata(originalDate: PartialDate(year: 1998, month: 3)), url: sidecarURL)

        _ = try await store().update(captureID: captureID) {
            $0.setOriginalDate(PartialDate(year: 1998, month: 3, day: 4))
        }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records.count, 1)
        let record = try XCTUnwrap(log.records.first)
        XCTAssertEqual(record.field, "originalDate")
        XCTAssertEqual(record.from, "1998-03")
        XCTAssertEqual(record.to, "1998-03-04")
        XCTAssertEqual(record.cause, .userEdit)
    }

    /// 7.2 (part 2): the counterpart to the test above — a fixture where the mutation
    /// changes nothing writes nothing. Non-degenerate against the test above: that one
    /// proves a real change DOES append, so "always writes nothing" cannot pass both.
    func testUpdateThatChangesNothingAppendsNothing() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)

        _ = try await store().update(captureID: captureID) { $0.journalID = "J1" }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records, [])
    }

    /// Review finding (Important 2): `EntryLogRecord.diff` has six near-identical
    /// branches, one per `EntryMetadata` field; only `journalID`/`originalDate` were
    /// exercised above. One row per field, each in its own capture directory so no case
    /// can see another's log. Mutation-checked below (transposing a field name).
    func testEveryFieldChangeAppendsARecordWithTheRightNameAndEncodings() async throws {
        struct Case {
            let field: String
            let seed: EntryMetadata
            let mutate: @Sendable (inout EntryMetadata) -> Void
            let from: String?
            let to: String?
        }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [Case] = [
            Case(field: "journalID", seed: EntryMetadata(journalID: "J1"),
                 mutate: { $0.journalID = "J2" }, from: "J1", to: "J2"),
            Case(field: "originalDate", seed: EntryMetadata(originalDate: PartialDate(year: 1998, month: 3)),
                 mutate: { $0.originalDate = PartialDate(year: 1998, month: 3, day: 4) },
                 from: "1998-03", to: "1998-03-04"),
            Case(field: "trashedAt", seed: EntryMetadata(),
                 mutate: { $0.trashedAt = stamp }, from: nil,
                 to: CaptureCoding.iso8601Formatter().string(from: stamp)),
            Case(field: "detectedDate", seed: EntryMetadata(),
                 mutate: { $0.detectedDate = PartialDate(year: 1999) }, from: nil, to: "1999"),
            Case(field: "detectionRan", seed: EntryMetadata(),
                 mutate: { $0.detectionRan = true }, from: "false", to: "true"),
            Case(field: "multiVoice", seed: EntryMetadata(),
                 mutate: { $0.multiVoice = true }, from: "false", to: "true"),
        ]

        for testCase in cases {
            let id = "\(captureID)-\(testCase.field)"
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try EntryMetadataStore.write(testCase.seed,
                                         url: SegmentLayout.entryMetadataURL(captureDirectory: dir))

            _ = try await store().update(captureID: id) { testCase.mutate(&$0) }

            let log = EntryLogReader.load(captureDirectory: dir)
            XCTAssertEqual(log.records.count, 1, "\(testCase.field): expected exactly one record")
            let record = try XCTUnwrap(log.records.first, testCase.field)
            XCTAssertEqual(record.field, testCase.field, "\(testCase.field): field name")
            XCTAssertEqual(record.from, testCase.from, "\(testCase.field): from")
            XCTAssertEqual(record.to, testCase.to, "\(testCase.field): to")
        }
    }

    /// Review finding (Important 2): no test asserted a multi-field mutation appends
    /// multiple records in `EntryMetadata`'s declaration order. The mutate closure sets
    /// `multiVoice` before `journalID` — the OPPOSITE of declaration order — so this is
    /// non-degenerate against a differ that emitted records in mutation order instead.
    func testTwoFieldMutationAppendsRecordsInDeclarationOrderNotMutationOrder() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)

        _ = try await store().update(captureID: captureID) {
            $0.multiVoice = true
            $0.journalID = "J2"
        }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records.map(\.field), ["journalID", "multiVoice"])
    }

    /// 7.4: the log file is pre-created and made unwritable so `EntryLogWriter.append`'s
    /// `open()` fails with EACCES, while `entry.json` — a different file in the same
    /// directory — stays writable. `update` must still succeed and the sidecar must
    /// still carry the edit; only the log write is lost.
    func testFailingAppendDoesNotFailTheMetadataWrite() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)
        let logURL = SegmentLayout.entryLogURL(captureDirectory: captureDirectory)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                        ofItemAtPath: logURL.path) }
        guard !FileManager.default.isWritableFile(atPath: logURL.path) else {
            throw XCTSkip("running with privileges that bypass permission checks")
        }

        let (updated, _) = try await store().update(captureID: captureID) { $0.journalID = "J2" }
        XCTAssertEqual(updated.journalID, "J2")
        let persisted = try await store().read(captureID: captureID)
        XCTAssertEqual(persisted.journalID, "J2")
    }

    /// 7.5: the capture directory is made unwritable so the sidecar's `AtomicFile.replace`
    /// cannot create its `.part` file — `update` must throw before the mutation ever
    /// takes effect, and no log record may exist afterward.
    ///
    /// The log file is pre-created (normal permissions) so this genuinely isolates
    /// ordering rather than accidentally testing "both operations fail for the same
    /// reason": appending to an ALREADY-EXISTING file needs only the file's own write
    /// permission, not the directory's — POSIX only gates directory *entry* creation
    /// (a new `.part`, a new `entry-log.jsonl`) behind directory write permission. So an
    /// append-before-write bug would still succeed here even though the sidecar write
    /// fails, and this test would catch it.
    func testAppendNeverRunsWhenTheSidecarWriteFails() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)
        // Pre-created with normal permissions, BEFORE the directory is locked down:
        // appending to an already-existing file needs only the file's own write
        // permission plus directory *search*, not directory *write* — so an
        // append-before-write bug is still observable below even though the sidecar
        // write is denied.
        let logURL = SegmentLayout.entryLogURL(captureDirectory: captureDirectory)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        // Throwaway scratch file, created here (before the lockdown) so it doesn't
        // contaminate the real assertion below — used only to confirm the isolation
        // actually holds on this filesystem.
        let scratchURL = captureDirectory.appendingPathComponent("probe.tmp")
        FileManager.default.createFile(atPath: scratchURL.path, contents: Data())

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: captureDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                        ofItemAtPath: captureDirectory.path) }
        guard !FileManager.default.isWritableFile(atPath: captureDirectory.path) else {
            throw XCTSkip("running with privileges that bypass permission checks")
        }
        // Appending to a pre-existing, normally-permissioned file must succeed even
        // with the directory locked down, or this test proves nothing about ordering.
        let scratchFD = open(scratchURL.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(scratchFD, 0, "fixture assumption failed: appending to an " +
            "existing file needs directory write too on this filesystem")
        if scratchFD >= 0 { close(scratchFD) }

        do {
            _ = try await store().update(captureID: captureID) { $0.journalID = "J2" }
            XCTFail("expected the sidecar write to fail")
        } catch {
            // expected — AtomicFile.replace could not create its .part file
        }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records, [], "append must never run when the sidecar write did not land")
    }

    // MARK: 7.8 — cause: .rejected (§7.1 nit)

    /// A future backdate is refused by `EntryMetadata.setOriginalDate` — nothing for
    /// `update`'s diff to see, since the value never changes — but the attempt itself is
    /// logged directly, with `cause: .rejected`. The sidecar is untouched.
    func testRejectedFutureBackdateIsLoggedWithCauseRejected() async throws {
        try EntryMetadataStore.write(EntryMetadata(originalDate: PartialDate(year: 1998, month: 6)),
                                     url: sidecarURL)

        let accepted = try await store().setOriginalDate(
            PartialDate(year: 2027), captureID: captureID, now: referenceNow, calendar: referenceCalendar)
        XCTAssertFalse(accepted)

        let persisted = try await store().read(captureID: captureID)
        XCTAssertEqual(persisted.originalDate, PartialDate(year: 1998, month: 6),
                       "a rejected attempt must not reach the sidecar")

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records.count, 1)
        let record = try XCTUnwrap(log.records.first)
        XCTAssertEqual(record.field, "originalDate")
        XCTAssertEqual(record.from, "1998-06")
        XCTAssertEqual(record.to, "2027")
        XCTAssertEqual(record.cause, .rejected)
    }

    /// The counterpart: an accepted backdate through the same entry point still goes
    /// through `update`'s generic diff, cause `.userEdit`, non-degenerate against the
    /// rejected case above (both use `setOriginalDate`; only the date differs).
    func testAcceptedBackdateThroughSetOriginalDateLogsUserEdit() async throws {
        try EntryMetadataStore.write(EntryMetadata.defaults, url: sidecarURL)

        let accepted = try await store().setOriginalDate(
            PartialDate(year: 2026, month: 6, day: 15), captureID: captureID,
            now: referenceNow, calendar: referenceCalendar)
        XCTAssertTrue(accepted)

        let persisted = try await store().read(captureID: captureID)
        XCTAssertEqual(persisted.originalDate, PartialDate(year: 2026, month: 6, day: 15))

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records.first?.cause, .userEdit)
    }

    // MARK: Review finding (Important 1) — the answer must come from the model, never a guess

    /// `update`'s generic `T` is the mutate closure's own return value, handed back
    /// verbatim — not re-derived from the before/after diff, not re-derived from the
    /// closure's argument, nothing state-based that could coincidentally agree with the
    /// closure's real answer on today's inputs and silently drift later. A contrived
    /// string (not something guessable from `EntryMetadata`'s state) makes that concrete.
    func testUpdateReturnsTheMutateClosuresOwnResultVerbatim() async throws {
        try EntryMetadataStore.write(EntryMetadata.defaults, url: sidecarURL)

        let (metadata, result) = try await store().update(captureID: captureID) { md -> String in
            md.journalID = "J9"
            return "closure-returned-this-exact-string"
        }

        XCTAssertEqual(metadata.journalID, "J9")
        XCTAssertEqual(result, "closure-returned-this-exact-string")
    }

    /// Review finding (Important 1): `setOriginalDate`'s `accepted` answer must always
    /// agree with what actually landed in the sidecar — never predicted ahead of the
    /// model, never a hardcoded literal disconnected from what `EntryMetadata
    /// .setOriginalDate` really decided. Runs both the accepted and rejected cases (each
    /// in its own capture directory, so neither result can bleed into the other) and
    /// checks the invariant directly against re-read disk state rather than against a
    /// second, independently-computed expectation.
    func testSetOriginalDatesAcceptedAnswerAlwaysMatchesWhatLandedInTheSidecar() async throws {
        struct Case { let name: String; let candidate: PartialDate }
        let cases: [Case] = [
            Case(name: "accepted", candidate: PartialDate(year: 2026, month: 6, day: 15)),
            Case(name: "rejected", candidate: PartialDate(year: 2027)),
        ]

        for testCase in cases {
            let id = "\(captureID)-\(testCase.name)"
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = SegmentLayout.entryMetadataURL(captureDirectory: dir)
            try EntryMetadataStore.write(EntryMetadata.defaults, url: url)

            let accepted = try await store().setOriginalDate(
                testCase.candidate, captureID: id, now: referenceNow, calendar: referenceCalendar)
            let persisted = try EntryMetadataStore.read(url: url)

            XCTAssertEqual(accepted, persisted.originalDate == testCase.candidate,
                           "\(testCase.name): the store's answer must match whether the " +
                           "sidecar actually holds the attempted date, not a guess made ahead of it")
        }
    }

    // MARK: M4 T1 — sync stamps (`modified`)

    /// Advances on every call — the frozen-clock trap (memory:
    /// frozen-clock-two-mints-coin-flip-order applies to any two writes compared for
    /// ordering, not just ULID mints): two `update` calls sharing one frozen clock could
    /// stamp two DIFFERENT fields with the identical instant, which would make the
    /// "second update leaves the first field's stamp untouched" assertion below pass
    /// vacuously even if `update` re-stamped every field on every call.
    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(1)
            return value
        }
    }

    /// The cardinality requirement: `update` stamps ONLY the field(s) the mutation
    /// actually changed. A second `update` that changes a DIFFERENT field must leave the
    /// first field's stamp exactly as it was — this is the per-field last-writer-wins
    /// substrate later M4 tasks build a merge rule on, so a stamp moving for a field
    /// nobody touched would silently break that merge rule.
    func testUpdateStampsOnlyTheChangedFieldAndLeavesOtherStampsUntouched() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_650_000_000))
        let s = store(now: { clock.next() })
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J1", originalDate: PartialDate(year: 1998, month: 3)),
            url: sidecarURL)

        let (afterFirst, _) = try await s.update(captureID: captureID) {
            $0.setOriginalDate(PartialDate(year: 1998, month: 3, day: 4))
        }
        let originalDateStamp = try XCTUnwrap(afterFirst.modified?["originalDate"])
        XCTAssertNil(afterFirst.modified?["journalID"], "journalID never changed — no stamp for it")

        let (afterSecond, _) = try await s.update(captureID: captureID) { $0.journalID = "J2" }
        XCTAssertEqual(afterSecond.modified?["originalDate"], originalDateStamp,
                       "a later update to journalID must not touch originalDate's stamp")
        let journalIDStamp = try XCTUnwrap(afterSecond.modified?["journalID"])
        XCTAssertGreaterThan(journalIDStamp, originalDateStamp,
                             "sanity: the clock genuinely advanced between the two updates")

        // And the stamp actually reached disk, not just the in-memory return value.
        let persisted = try await s.read(captureID: captureID)
        XCTAssertEqual(persisted.modified, afterSecond.modified)
    }

    /// Counterpart to the test above, mirroring `testUpdateThatChangesNothingAppendsNothing`:
    /// a mutation whose before/after are equal stamps nothing at all, not an empty dict.
    func testUpdateThatChangesNothingStampsNothing() async throws {
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"), url: sidecarURL)
        let (updated, _) = try await store().update(captureID: captureID) { $0.journalID = "J1" }
        XCTAssertNil(updated.modified)
    }

    func testModifiedMapRoundTripsThroughDisk() throws {
        let stamp = Date(timeIntervalSince1970: 1_650_000_000.5)
        let metadata = EntryMetadata(journalID: "J1", modified: ["journalID": stamp])
        try EntryMetadataStore.write(metadata, url: sidecarURL)
        let readBack = try EntryMetadataStore.read(url: sidecarURL)
        XCTAssertEqual(readBack, metadata)
        XCTAssertTrue(String(decoding: try Data(contentsOf: sidecarURL), as: UTF8.self)
            .contains("modified"))
    }

    /// Additive and lenient, same shape as `testMultiVoiceGarbageDecodesFalse`: a garbage
    /// `modified` value costs only the sync stamps, never the rest of the sidecar.
    func testGarbageModifiedMapDecodesNilWithoutLosingOtherFields() throws {
        let decoded = try EntryMetadataStore.decode(
            Data(#"{"journalID":"J1","modified":"oops"}"#.utf8))
        XCTAssertNil(decoded.modified)
        XCTAssertEqual(decoded.journalID, "J1")
    }

    /// A minimal stand-in for "a build that predates `modified`" — its `CodingKeys`
    /// (implicit, from having only this one property) has no `modified` case at all.
    private struct PreM4EntryMetadataShape: Decodable {
        var journalID: String?
    }

    /// Forward-compat pin (M4 T1): a record a NEWER build wrote (carrying `modified`)
    /// must still decode cleanly on a build that has never heard of the field — the
    /// ordinary "unknown keys are ignored" JSON behavior, pinned explicitly so a future
    /// change to `EntryMetadata`'s decoder can't quietly turn `modified` into a required
    /// key without a test noticing.
    func testEntryMetadataWithModifiedDecodesInAnOldShapedDecoderIgnoringIt() throws {
        let json = Data(#"{"journalID":"J1","modified":{"journalID":"2024-01-01T00:00:00.000Z"}}"#.utf8)
        let decoded = try CaptureCoding.decoder().decode(PreM4EntryMetadataShape.self, from: json)
        XCTAssertEqual(decoded.journalID, "J1")
    }
}
