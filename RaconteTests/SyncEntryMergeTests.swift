import XCTest
import CloudKit
@testable import Raconte

/// M4 T8: per-field last-writer-wins for entries, both directions (inbound ingest into an
/// already-local capture, and the push-conflict resave), plus the `.sync` entry-log audit
/// cause.
///
/// `EntryFieldMerge` is pure and shares `LWWResolve` with `JournalMerge` (T5) — see
/// `SyncJournalIngestTests.testLWWResolveHasANamedAnswerForEveryCombinationOfStamps`/
/// `testEqualStampsResolveToTheLexicographicallyGreaterDeviceIDInBothDirections` for the
/// comparison's own exhaustive coverage; this file does not re-derive those rules, only
/// proves `EntryFieldMerge` wires them through correctly for entry fields, plus the two
/// fields (`detectedDate`/`detectionRan`) that are NOT ordinary LWW at all.
final class SyncEntryMergeTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    /// Deliberately ordered: `deviceLow` < `deviceHigh` lexicographically — the only
    /// property the tie-break rule depends on. Same literals `SyncJournalIngestTests` uses.
    private let deviceLow = "AAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let deviceHigh = "ZZZZZZZZZZZZZZZZZZZZZZZZZZ"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncEntryMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private func remote(journalID: String? = nil, originalDate: PartialDate? = nil,
                        trashedAt: Date? = nil, multiVoice: Bool = false,
                        detectedDate: PartialDate? = nil, detectionRan: Bool? = nil,
                        modified: [String: Date] = [:], deviceID: String? = nil) -> RemoteEntryFields {
        RemoteEntryFields(captureID: captureID, capturedAt: stamp(0), journalID: journalID,
                          originalDate: originalDate, trashedAt: trashedAt, multiVoice: multiVoice,
                          detectedDate: detectedDate, detectionRan: detectionRan,
                          modified: modified, deviceID: deviceID)
    }

    // MARK: Mirror field-count tripwire — pins the entry sync/merge surface (ruled task,
    // Task 8 deferred minor, owner-ruled MUST-FIX 2026-08-22)

    /// Mirrors `SyncJournalRoundTripTests.testJournalFieldCountMatchesTheSyncFixture`'s
    /// pattern exactly: without this, a future field added to `EntryMetadata` would
    /// compile, pass the whole suite, and silently never sync — nothing forces it into
    /// `SyncRecordBuilders.entryRecord`, `RemoteEntryFields.init(record:)`, or
    /// `EntryFieldMerge.merge`'s field list. (`EntryLogTests
    /// .testEntryMetadataFieldCountIsPinnedSoNewFieldsGetLogged` pins the same type for a
    /// different surface — the audit-log differ — and does not cover this one.)
    func testEntryMetadataFieldCountIsPinnedSoTheSyncMergeSurfaceCatchesNewFields() {
        XCTAssertEqual(
            Mirror(reflecting: EntryMetadata.defaults).children.count, 7,
            "EntryMetadata gained or lost a field. Bump this count, then wire the field " +
            "through SyncRecordBuilders.entryRecord (the push side), " +
            "RemoteEntryFields.init(record:) (the decode side), and EntryFieldMerge.merge's " +
            "field list, and confirm SyncTreeScanner.entryDigest still captures it, before " +
            "this pin is honest again."
        )
    }

    /// Same defect class as above, for the wire-format twin: a field added to
    /// `RemoteEntryFields` (either straight off the record, or the `EntryMetadata` fields
    /// it carries) would compile and pass the whole suite while never actually merging.
    func testRemoteEntryFieldsFieldCountIsPinnedSoTheSyncMergeSurfaceCatchesNewFields() {
        let fields = RemoteEntryFields(captureID: captureID, capturedAt: stamp(0))
        XCTAssertEqual(
            Mirror(reflecting: fields).children.count, 10,
            "RemoteEntryFields gained or lost a field. Bump this count, then wire the field " +
            "through SyncRecordBuilders.entryRecord (the push side), " +
            "RemoteEntryFields.init(record:) (the decode side), and EntryFieldMerge.merge's " +
            "field list, and confirm SyncTreeScanner.entryDigest still captures it, before " +
            "this pin is honest again."
        )
    }

    // MARK: EntryFieldMerge — per field, not per record

    /// The owner's ruling, verbatim (brief): remote sets `originalDate` newer, local sets
    /// `journalID` newer → merged carries BOTH winners. The one property that separates a
    /// per-field merge from a whole-record one — whole-record LWW would keep one side's
    /// pair and silently revert the other's.
    func testARemoteNewerOriginalDateAndALocalNewerJournalIDBothSurvive() throws {
        let local = EntryMetadata(journalID: "Local-J", originalDate: PartialDate(year: 1990),
                                  modified: ["journalID": stamp(40), "originalDate": stamp(10)])
        let remoteFields = remote(journalID: "Remote-J", originalDate: PartialDate(year: 1998),
                                  modified: ["journalID": stamp(20), "originalDate": stamp(30)],
                                  deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.journalID, "Local-J", "local's journalID stamp is newer")
        XCTAssertEqual(merged.originalDate, PartialDate(year: 1998), "remote's originalDate stamp is newer")
    }

    /// The merged map takes each stamp from the side that WON that field, not the newer of
    /// the two — same reasoning `JournalMerge`'s twin test states: keeping the loser's
    /// newer-looking stamp would make a third device reach the opposite conclusion.
    func testMergedStampsComeFromTheWinningSideOfEachField() {
        let local = EntryMetadata(journalID: "Local-J", originalDate: PartialDate(year: 1990),
                                  modified: ["journalID": stamp(40), "originalDate": stamp(10)])
        let remoteFields = remote(journalID: "Remote-J", originalDate: PartialDate(year: 1998),
                                  modified: ["journalID": stamp(20), "originalDate": stamp(30)],
                                  deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.modified?["journalID"], stamp(40))
        XCTAssertEqual(merged.modified?["originalDate"], stamp(30))
    }

    /// A field the remote has never stamped must not be taken over a local edit — an
    /// unstamped field predates M4's stamps entirely (or the remote genuinely never
    /// touched it), and either way it must lose to a stamped local edit.
    func testAFieldTheRemoteNeverStampedIsNotTakenOverALocalEdit() {
        let local = EntryMetadata(journalID: "Local-J", modified: ["journalID": stamp(10)])
        let remoteFields = remote(journalID: "Remote-J", modified: [:], deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.journalID, "Local-J")
    }

    // MARK: trashedAt — LWW both directions (brief-required)

    func testTrashedAtRemoteNewerTrashWins() {
        let local = EntryMetadata(trashedAt: nil, modified: [:])
        let remoteFields = remote(trashedAt: stamp(50), modified: ["trashedAt": stamp(50)],
                                  deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.trashedAt, stamp(50), "a newer remote trash must apply")
    }

    /// The other direction: a newer LOCAL restore (a newer-stamped `nil`) must not be
    /// reverted by an older remote trash — same "newer stamped nil defeats an older
    /// non-nil" rule `JournalMerge`'s span/cover tests pin.
    func testTrashedAtLocalNewerRestoreSurvivesAnOlderRemoteTrash() {
        let local = EntryMetadata(trashedAt: nil, modified: ["trashedAt": stamp(99)])
        let remoteFields = remote(trashedAt: stamp(10), modified: ["trashedAt": stamp(10)],
                                  deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertNil(merged.trashedAt, "local's later restore must not be reverted by an older remote trash")
        XCTAssertEqual(merged.modified?["trashedAt"], stamp(99))
    }

    // MARK: multiVoice — ordinary LWW, one direction is enough alongside the two above

    func testMultiVoiceRemoteNewerWins() {
        let local = EntryMetadata(multiVoice: false, modified: ["multiVoice": stamp(5)])
        let remoteFields = remote(multiVoice: true, modified: ["multiVoice": stamp(15)], deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertTrue(merged.multiVoice)
    }

    // MARK: detectedDate / detectionRan — write-once latch, NOT ordinary LWW (brief-required)

    /// The brief's exact wording: once `detectionRan` is true anywhere, it never merges
    /// back to false regardless of stamps. Deliberately adversarial: the remote's
    /// `detectionRan: false` carries a stamp NEWER than local's — which would win under
    /// ordinary per-field LWW — proving the merge rule does not consult stamps for this
    /// field at all.
    func testDetectionRanLatchOnceTrueLocallyNeverMergesBackToFalseRegardlessOfStamps() {
        let local = EntryMetadata(detectedDate: PartialDate(year: 1998), detectionRan: true,
                                  modified: ["detectionRan": stamp(10), "detectedDate": stamp(10)])
        let remoteFields = remote(detectedDate: nil, detectionRan: false,
                                  modified: ["detectionRan": stamp(999)], deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertTrue(merged.detectionRan,
                      "the latch must not revert to false no matter how the stamps compare")
        XCTAssertEqual(merged.detectedDate, PartialDate(year: 1998), "local's own detected date must survive")
    }

    /// The adoption direction: local has never run detection, remote has — the pair
    /// (`detectionRan` + `detectedDate`) donates together, since they are set together
    /// (`EntryMetadata.detectionRan`'s own doc comment) and never independently.
    func testDetectionRanLatchAdoptsFromRemoteWhenLocalHasNotRun() {
        let local = EntryMetadata()
        let remoteFields = remote(detectedDate: PartialDate(year: 2001), detectionRan: true,
                                  modified: ["detectionRan": stamp(5), "detectedDate": stamp(5)],
                                  deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertTrue(merged.detectionRan)
        XCTAssertEqual(merged.detectedDate, PartialDate(year: 2001))
        XCTAssertEqual(merged.modified?["detectionRan"], stamp(5))
        XCTAssertEqual(merged.modified?["detectedDate"], stamp(5))
    }

    /// A remote that has also never run detection changes nothing — both sides false, no
    /// donation should happen, `modified` stays empty for these two fields.
    func testDetectionRanLatchNeitherSideHasRunLeavesNothingSet() {
        let local = EntryMetadata()
        let remoteFields = remote(detectedDate: nil, detectionRan: false, modified: [:], deviceID: deviceHigh)

        let merged = EntryFieldMerge.merge(local: local, remote: remoteFields,
                                           localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertFalse(merged.detectionRan)
        XCTAssertNil(merged.detectedDate)
        XCTAssertNil(merged.modified)
    }

    // MARK: Tie-break wiring (mutation-check target — brief-required)

    /// `EntryFieldMerge` must pass `localDeviceID`/`remoteDeviceID` through to the shared
    /// `LWWResolve` comparison in the right slots, not swapped or hardcoded — proven by
    /// running the SAME equal-stamp scenario in both directions and requiring the winner
    /// to flip with it.
    ///
    /// Mutation check (run by hand, per the brief): temporarily flipping
    /// `LWWResolve.winner`'s tie-break comparison from `remoteDeviceID > localDeviceID` to
    /// `remoteDeviceID < localDeviceID` makes BOTH assertions below fail (each flips to the
    /// opposite winner) — evidence recorded in the task report, not left as a permanent
    /// second copy of this test.
    func testEqualStampsOnAFieldResolveToTheDeviceIDTieBreakInBothDirections() {
        let tieStamp = stamp(1)

        let localA = EntryMetadata(journalID: "Local", modified: ["journalID": tieStamp])
        let remoteA = remote(journalID: "Remote", modified: ["journalID": tieStamp], deviceID: deviceHigh)
        let mergedA = EntryFieldMerge.merge(local: localA, remote: remoteA,
                                            localDeviceID: deviceLow, remoteDeviceID: deviceHigh)
        XCTAssertEqual(mergedA.journalID, "Remote", "deviceHigh > deviceLow — remote wins the tie")

        let localB = EntryMetadata(journalID: "Local", modified: ["journalID": tieStamp])
        let remoteB = remote(journalID: "Remote", modified: ["journalID": tieStamp], deviceID: deviceLow)
        let mergedB = EntryFieldMerge.merge(local: localB, remote: remoteB,
                                            localDeviceID: deviceHigh, remoteDeviceID: deviceLow)
        XCTAssertEqual(mergedB.journalID, "Local", "deviceHigh > deviceLow — local wins this direction's tie")
    }

    // MARK: RemoteEntryFields — deviceID decode (wire round trip)

    private var entryRecordID: CKRecord.ID {
        SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
    }

    func testRemoteEntryFieldsDecodesDeviceIDFromTheRecord() {
        let record = SyncRecordBuilders.entryRecord(captureID: captureID, metadata: .defaults,
                                                     manifestJSON: Data("{}".utf8), capturedAt: stamp(0),
                                                     deviceID: deviceHigh, zoneID: zoneID)

        let fields = RemoteEntryFields(record: record)

        XCTAssertEqual(fields?.deviceID, deviceHigh)
    }

    /// A record built by an older device predates the field entirely — absence must
    /// decode to `nil`, not crash the whole record's decode.
    func testRemoteEntryFieldsToleratesAnAbsentDeviceID() {
        let record = CKRecord(recordType: SyncRecordType.entry, recordID: entryRecordID)
        record[SyncEntryField.capturedAt] = stamp(0)

        let fields = RemoteEntryFields(record: record)

        XCTAssertNotNil(fields, "a missing deviceID must not fail the whole decode")
        XCTAssertNil(fields?.deviceID)
    }

    // MARK: EntryMetadataStore.applySyncMerge — the no-echo, no-restamp write

    private func store(capturesRoot: URL, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_650_000_000) },
                       syncHooks: (any SyncHooks)? = nil) -> EntryMetadataStore {
        EntryMetadataStore(capturesRoot: capturesRoot, now: now, syncHooks: syncHooks)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    @discardableResult
    private func seedLocalEntry(_ metadata: EntryMetadata) throws -> URL {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        try EntryMetadataStore.write(metadata, url: url)
        return url
    }

    /// The load-bearing property (controller ruling): the store's OWN clock must never
    /// touch a merged stamp. `decide`'s returned `modified` map carries stamps that
    /// disagree with the store's injected `now()` on every field — if `applySyncMerge`
    /// re-stamped like `update` does, every one of these assertions would instead read the
    /// store's fixed clock value.
    func testApplySyncMergeWritesTheDecideClosuresStampsVerbatimWithoutRestamping() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "Local-J"))
        let storeClock = Date(timeIntervalSince1970: 1_650_000_000)
        let s = store(capturesRoot: capturesRoot, now: { storeClock })
        let mergeStamp = stamp(30)

        let mergedResult = try await s.applySyncMerge(captureID: captureID) { local in
            var merged = local
            merged.journalID = "Remote-J"
            merged.modified = ["journalID": mergeStamp]
            return merged
        }

        XCTAssertEqual(mergedResult.journalID, "Remote-J")
        XCTAssertEqual(mergedResult.modified, ["journalID": stamp(30)],
                       "the decide closure's own stamp must survive verbatim")
        XCTAssertNotEqual(mergedResult.modified?["journalID"], storeClock,
                          "sanity: the store's clock and the merge's stamp are deliberately different values")

        let persisted = try await s.read(captureID: captureID)
        XCTAssertEqual(persisted.modified, ["journalID": stamp(30)],
                       "the on-disk stamp must be the merge's, not the store's clock")
    }

    /// Entries carry their OWN audit log (T7 §7) — unlike `JournalStore.applySyncMerge`,
    /// a sync-caused entry merge still appends `.sync`-cause rows.
    func testApplySyncMergeAppendsSyncCauseRowsToTheEntryLog() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "Local-J", originalDate: PartialDate(year: 1990)))
        let s = store(capturesRoot: capturesRoot)

        _ = try await s.applySyncMerge(captureID: captureID) { local in
            var merged = local
            merged.originalDate = PartialDate(year: 1998)
            return merged
        }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records.count, 1)
        let record = try XCTUnwrap(log.records.first)
        XCTAssertEqual(record.field, "originalDate")
        XCTAssertEqual(record.from, "1990")
        XCTAssertEqual(record.to, "1998")
        XCTAssertEqual(record.cause, .sync)
    }

    /// A merge that changes nothing appends nothing — mirrors `update`'s own no-op rule.
    func testApplySyncMergeThatChangesNothingAppendsNothingToTheLog() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "J1"))
        let s = store(capturesRoot: capturesRoot)

        _ = try await s.applySyncMerge(captureID: captureID) { $0 }

        let log = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(log.records, [])
    }

    /// The no-echo rule (design §6, same reasoning as `JournalStore.applySyncMerge`): a
    /// sync-caused write must never announce itself as a local edit, or two devices
    /// trading the same entry's field would bounce it back and forth via the deviceID
    /// tie-break.
    func testApplySyncMergeFiresNoSyncHookAtAll() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "Local-J"))
        let hooks = RecordingSyncHooks()
        let s = store(capturesRoot: capturesRoot, syncHooks: hooks)

        _ = try await s.applySyncMerge(captureID: captureID) { local in
            var merged = local
            merged.journalID = "Remote-J"
            return merged
        }

        let names = await hooks.names
        XCTAssertEqual(names, [], "an inbound merge must never announce itself as a local change")
    }

    /// Same guard `update` has (#25/T6 §4.6): a merge write must never recreate a capture
    /// directory a staged removal has already moved away.
    func testApplySyncMergeThrowsCaptureMissingRatherThanCreatingTheDirectory() async throws {
        let s = store(capturesRoot: capturesRoot)
        do {
            _ = try await s.applySyncMerge(captureID: captureID) { $0 }
            XCTFail("expected captureMissing")
        } catch {
            guard case .captureMissing = (error as? EntryMetadataError) else {
                return XCTFail("expected EntryMetadataError.captureMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    // MARK: Orchestrator wiring — inbound merge for an already-local capture (item 4)

    private func exchange(entryMetadataStore: EntryMetadataStore? = nil,
                          localStoreDidChange: (@Sendable () async -> Void)? = nil) -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: deviceLow, containerRoot: containerRoot,
            entryMetadataStore: entryMetadataStore,
            localStoreDidChange: localStoreDidChange)
    }

    private func entryRecord(metadata: EntryMetadata, manifestJSON: Data, at when: Date,
                             deviceID: String) -> CKRecord {
        SyncRecordBuilders.entryRecord(captureID: captureID, metadata: metadata,
                                       manifestJSON: manifestJSON, capturedAt: when,
                                       deviceID: deviceID, zoneID: zoneID)
    }

    /// THE headline pin (brief item 4): an inbound Entry record for a capture that already
    /// exists locally merges field-by-field into the sidecar, rather than being dropped
    /// (the T7-era behavior this task replaces) or renamed over.
    func testAnInboundEntryRecordForAnAlreadyLocalCaptureMergesFieldByField() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "Local-J", originalDate: PartialDate(year: 1990),
                                         modified: ["journalID": stamp(40), "originalDate": stamp(10)]))
        let entryStore = store(capturesRoot: capturesRoot)
        let signals = SignalCounter()
        let ex = exchange(entryMetadataStore: entryStore, localStoreDidChange: { await signals.increment() })

        let remoteMetadata = EntryMetadata(journalID: "Remote-J", originalDate: PartialDate(year: 1998),
                                           modified: ["journalID": stamp(20), "originalDate": stamp(30)])
        await ex.acceptRemote(entryRecord(metadata: remoteMetadata,
                                          manifestJSON: Data("{}".utf8), at: stamp(0), deviceID: deviceHigh))

        let merged = try await entryStore.read(captureID: captureID)
        XCTAssertEqual(merged.journalID, "Local-J", "local's journalID stamp is newer")
        XCTAssertEqual(merged.originalDate, PartialDate(year: 1998), "remote's originalDate stamp is newer")

        let signalCount = await signals.count
        XCTAssertEqual(signalCount, 1, "the library must be told to reload once the merge lands")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID).path),
                       "no rename ever happens for an existing capture — staging must still be cleaned up")
    }

    /// With no `entryMetadataStore` wired (mirrors every other T7/T8 nil-degrade), the
    /// merge is skipped rather than crashing — matching `SyncEntryIngestTests
    /// .testIngestWithCaptureAlreadyExistingLocallyNeverRenamesOverIt`'s existing pin,
    /// which this task must not break: an existing local sidecar is untouched when no
    /// store is wired to merge into it.
    func testWithNoEntryMetadataStoreWiredTheExistingSidecarIsLeftUntouched() async throws {
        let sentinel = try seedLocalEntry(EntryMetadata(journalID: "Local-J"))
        let before = try Data(contentsOf: sentinel)
        let ex = exchange()   // no entryMetadataStore

        await ex.acceptRemote(entryRecord(metadata: EntryMetadata(journalID: "Remote-J"),
                                          manifestJSON: Data("{}".utf8), at: stamp(0), deviceID: deviceHigh))

        XCTAssertEqual(try Data(contentsOf: sentinel), before)
    }

    /// A local sidecar that cannot be read at all (damaged, not merely absent) must not
    /// take the merge down with it — the same `.unreadable`-costs-only-itself discipline
    /// `EntryMetadataStore` follows everywhere else. Left byte-for-byte untouched.
    func testAnUnreadableLocalSidecarLeavesTheMergeSkippedAndTheFileUntouched() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        let garbage = Data("not valid entry.json at all".utf8)
        try garbage.write(to: url)
        let entryStore = store(capturesRoot: capturesRoot)
        let ex = exchange(entryMetadataStore: entryStore)

        await ex.acceptRemote(entryRecord(metadata: EntryMetadata(journalID: "Remote-J"),
                                          manifestJSON: Data("{}".utf8), at: stamp(0), deviceID: deviceHigh))

        XCTAssertEqual(try Data(contentsOf: url), garbage, "a damaged local sidecar must be left exactly as it was")
    }

    // MARK: Push-conflict path mirrors the inbound path (brief item 5)

    /// `resolvePushConflicts` routes every record through `acceptRemote` — the SAME
    /// mechanism T5 relies on for journals — so an Entry server record for an already-local
    /// capture merges exactly like a normally-fetched change, with no separate code path.
    func testPushConflictForAnEntryRoutesThroughTheSameMerge() async throws {
        try seedLocalEntry(EntryMetadata(journalID: "Local-J", modified: ["journalID": stamp(10)]))
        let entryStore = store(capturesRoot: capturesRoot)
        let ex = exchange(entryMetadataStore: entryStore)

        let serverCopy = entryRecord(
            metadata: EntryMetadata(journalID: "Remote-J", modified: ["journalID": stamp(50)]),
            manifestJSON: Data("{}".utf8), at: stamp(0), deviceID: deviceHigh)

        let resolution = await ex.resolvePushConflicts([serverCopy])

        XCTAssertEqual(resolution.resend, [.entry(captureID: captureID)])
        let merged = try await entryStore.read(captureID: captureID)
        XCTAssertEqual(merged.journalID, "Remote-J", "the server's newer-stamped copy must win the merge")
    }
}
