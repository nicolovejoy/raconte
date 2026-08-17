import XCTest
import CloudKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// M4 T5: per-field last-writer-wins for journals, the hooks that feed it, and the ingest
/// path that applies it — design §4 (conflict mechanics) and §6 (ingest).
///
/// The merge itself is pure and takes no CloudKit types at all, so most of this file is
/// value-in/value-out. The exchange tests drive the real `JournalStore`/`JournalCoverStore`
/// on a throwaway container root; nothing here touches CloudKit's servers.
final class SyncJournalIngestTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let journalID = ULID.make()
    /// Deliberately ordered: `deviceLow` < `deviceHigh` lexicographically, which is the
    /// only property the tie-break rule depends on.
    private let deviceLow = "AAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let deviceHigh = "ZZZZZZZZZZZZZZZZZZZZZZZZZZ"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncJournalIngest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    // MARK: LWWResolve — the shared comparison

    func testLWWResolveHasANamedAnswerForEveryCombinationOfStamps() {
        XCTAssertEqual(LWWResolve.winner(localStamp: nil, remoteStamp: nil,
                                         localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .local, "neither side claims to have written it — nothing to move")
        XCTAssertEqual(LWWResolve.winner(localStamp: nil, remoteStamp: stamp(1),
                                         localDeviceID: deviceHigh, remoteDeviceID: deviceLow),
                       .remote, "a dated edit outranks a field that predates stamps entirely")
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: nil,
                                         localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .local)
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: stamp(2),
                                         localDeviceID: deviceHigh, remoteDeviceID: deviceLow),
                       .remote, "newer wins regardless of deviceID")
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(2), remoteStamp: stamp(1),
                                         localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .local)
    }

    /// Both directions, as the brief requires: the rule must be the *same* rule on both
    /// devices, so swapping which machine is "local" has to swap the answer.
    func testEqualStampsResolveToTheLexicographicallyGreaterDeviceIDInBothDirections() {
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: stamp(1),
                                         localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .remote)
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: stamp(1),
                                         localDeviceID: deviceHigh, remoteDeviceID: deviceLow),
                       .local)
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: stamp(1),
                                         localDeviceID: deviceLow, remoteDeviceID: nil),
                       .local, "an absent deviceID cannot be greater than anything")
        XCTAssertEqual(LWWResolve.winner(localStamp: stamp(1), remoteStamp: stamp(1),
                                         localDeviceID: deviceLow, remoteDeviceID: deviceLow),
                       .local, "the same device wrote both — not a conflict")
    }

    // MARK: JournalMerge — per field, not per record

    /// The test the brief's mutation check targets, and the one property that separates a
    /// per-field merge from a whole-record one: two devices, each offline, each changing a
    /// *different* attribute of the same journal. Both edits must survive. Whole-record
    /// LWW keeps one side's pair and reverts the other's silently.
    func testARemoteNewerNameAndALocalNewerVoiceLabelsBothSurvive() {
        let local = Journal(id: journalID, name: "Local name", createdAt: stamp(0),
                            voiceLabels: ["bn": "Local label"],
                            modified: ["name": stamp(10), "voiceLabels": stamp(40)])
        let remote = RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(0),
                                   voiceLabels: ["bn": "Remote label"],
                                   modified: ["name": stamp(30), "voiceLabels": stamp(20)],
                                   deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.name, "Remote name", "remote's name stamp is newer")
        XCTAssertEqual(merged.voiceLabels, ["bn": "Local label"], "local's voiceLabels stamp is newer")
    }

    /// The merged map must take each stamp from the side that WON that field, not the
    /// newer of the two. Keeping the loser's newer-looking stamp would make a third device
    /// reach the opposite conclusion from this one, and the two would disagree forever.
    func testMergedStampsComeFromTheWinningSideOfEachField() {
        let local = Journal(id: journalID, name: "Local name", createdAt: stamp(0),
                            voiceLabels: ["bn": "Local label"],
                            modified: ["name": stamp(10), "voiceLabels": stamp(40)])
        let remote = RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(0),
                                   voiceLabels: ["bn": "Remote label"],
                                   modified: ["name": stamp(30), "voiceLabels": stamp(20)],
                                   deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.modified?["name"], stamp(30))
        XCTAssertEqual(merged.modified?["voiceLabels"], stamp(40))
    }

    func testAFieldTheRemoteNeverStampedIsNotTakenOverALocalEdit() {
        let local = Journal(id: journalID, name: "Local name", createdAt: stamp(0),
                            voiceLabels: ["bn": "Local label"],
                            modified: ["name": stamp(10), "voiceLabels": stamp(10)])
        let remote = RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(0),
                                   voiceLabels: [:], modified: [:], deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.name, "Local name")
        XCTAssertEqual(merged.voiceLabels, ["bn": "Local label"])
    }

    func testMergeNeverRewritesIdentityFields() {
        let local = Journal(id: journalID, name: "Local name", createdAt: stamp(0))
        let remote = RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(9_999),
                                   modified: ["name": stamp(50)], deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.id, journalID)
        XCTAssertEqual(merged.createdAt, stamp(0), "createdAt is immutable, never merged")
        XCTAssertEqual(merged.name, "Remote name")
    }

    /// Carry-forward finding 1: `JournalRegistry.insert` unconditionally overwrites
    /// `modified["name"]` with the local clock. A journal adopted from another device must
    /// keep the ORIGIN's stamps, or this device reads as the most recent writer of a name
    /// it merely received — after which a genuinely newer edit elsewhere can never win.
    func testAnAdoptedRemoteJournalKeepsTheRemoteStampsRatherThanRestamping() {
        let remote = RemoteJournal(id: journalID, name: "1987 Journal", createdAt: stamp(0),
                                   voiceLabels: ["bn": "Grandpa"],
                                   modified: ["name": stamp(10), "voiceLabels": stamp(20)],
                                   deviceID: deviceHigh)

        let adopted = JournalMerge.adopted(remote: remote)

        XCTAssertEqual(adopted.id, journalID)
        XCTAssertEqual(adopted.name, "1987 Journal")
        XCTAssertEqual(adopted.createdAt, stamp(0))
        XCTAssertEqual(adopted.voiceLabels, ["bn": "Grandpa"])
        XCTAssertEqual(adopted.modified, ["name": stamp(10), "voiceLabels": stamp(20)])
    }

    // MARK: Cover LWW

    func testTheRemoteCoverIsAdoptedOnlyWhenItsStampWins() {
        let coverURL = containerRoot.appendingPathComponent("fetched-cover.jpg")
        let localNewer = Journal(id: journalID, name: "J", createdAt: stamp(0),
                                 modified: ["cover": stamp(40)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["cover": stamp(20)],
                                   coverAsset: coverURL, deviceID: deviceHigh)
        XCTAssertFalse(JournalMerge.adoptsRemoteCover(local: localNewer, remote: remote,
                                                      localDeviceID: deviceLow, remoteDeviceID: deviceHigh))

        let localOlder = Journal(id: journalID, name: "J", createdAt: stamp(0),
                                 modified: ["cover": stamp(10)])
        XCTAssertTrue(JournalMerge.adoptsRemoteCover(local: localOlder, remote: remote,
                                                     localDeviceID: deviceLow, remoteDeviceID: deviceHigh))
    }

    func testARemoteWithNoCoverAssetNeverAdoptsOne() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0))
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["cover": stamp(99)], coverAsset: nil, deviceID: deviceHigh)
        XCTAssertFalse(JournalMerge.adoptsRemoteCover(local: local, remote: remote,
                                                      localDeviceID: deviceLow, remoteDeviceID: deviceHigh))
    }

    // MARK: Hooks — every local mutation path reaches the engine

    func testEveryJournalStoreMutationPathFiresTheSyncHookExactlyOnce() async throws {
        let hooks = RecordingSyncHooks()
        let store = JournalStore(containerRoot: containerRoot, syncHooks: hooks)

        let created = try await store.create(name: "1987 Journal")
        _ = try await store.rename(id: created.id, to: "1987 Journal, renamed")
        _ = try await store.setVoiceLabels(id: created.id, labels: ["bn": "Grandpa"])

        let seen = await hooks.names
        XCTAssertEqual(seen, [.journal(id: created.id), .journal(id: created.id), .journal(id: created.id)],
                       "create, rename and setVoiceLabels each change the record's content")
    }

    /// Carry-forward finding 2: `modified["cover"]` was declared in T1 and stamped by
    /// nothing, so cover LWW could never resolve. The stamp has to be written through
    /// `JournalStore` (single writer for `journals.json`) rather than by the cover store.
    func testWritingACoverStampsModifiedCoverAndFiresTheHook() async throws {
        let hooks = RecordingSyncHooks()
        let store = JournalStore(containerRoot: containerRoot, syncHooks: hooks)
        let created = try await store.create(name: "1987 Journal")
        await hooks.reset()

        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        try await covers.write(imageData: Self.makePNG(), journalID: created.id)

        let stamped = try await store.journal(id: created.id)
        XCTAssertNotNil(stamped?.modified?["cover"], "without this stamp cover LWW has no input at all")
        XCTAssertNil(stamped?.modified?["voiceLabels"], "only the cover's own stamp moves")
        let seen = await hooks.names
        XCTAssertEqual(seen, [.journal(id: created.id)],
                       "a new cover changes the journal record's digest, so it must be pushed")
    }

    /// Removing a cover is an edit too — it has to beat the other device's older "here is
    /// a cover", which means it needs its own newer stamp.
    func testDeletingACoverAlsoStampsModifiedCoverAndFiresTheHook() async throws {
        let clock = AdvancingClock(start: stamp(0))
        let store = JournalStore(containerRoot: containerRoot, now: clock.next)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        try await covers.write(imageData: Self.makePNG(), journalID: created.id)
        let afterWrite = try await store.journal(id: created.id)

        let hooks = RecordingSyncHooks()
        await store.attach(syncHooks: hooks)
        await covers.delete(journalID: created.id)

        let afterDelete = try await store.journal(id: created.id)
        let remaining = await covers.read(journalID: created.id)
        XCTAssertNil(remaining)
        XCTAssertGreaterThan(try XCTUnwrap(afterDelete?.modified?["cover"]),
                             try XCTUnwrap(afterWrite?.modified?["cover"]))
        let seen = await hooks.names
        XCTAssertEqual(seen, [.journal(id: created.id)])
    }

    // MARK: Ingest through the exchange

    private func exchange(_ store: JournalStore, _ covers: JournalCoverStore,
                          deviceID: String) -> SyncRecordExchange {
        SyncRecordExchange(journalStore: store, coverStore: covers,
                           bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
                           scanner: SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceID),
                           deviceID: deviceID)
    }

    private func remoteRecord(_ remote: RemoteJournal, deviceID: String,
                              coverFileURL: URL? = nil) -> CKRecord {
        SyncRecordBuilders.journalRecord(
            journal: Journal(id: remote.id, name: remote.name, createdAt: remote.createdAt,
                             voiceLabels: remote.voiceLabels,
                             modified: remote.modified.isEmpty ? nil : remote.modified),
            coverFileURL: coverFileURL, deviceID: deviceID, zoneID: zoneID)
    }

    func testAnUnknownRemoteJournalIsInsertedWithItsRemoteStampsIntact() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let remote = RemoteJournal(id: journalID, name: "Trip to France", createdAt: stamp(0),
                                   voiceLabels: ["bn": "Grandpa"],
                                   modified: ["name": stamp(10), "voiceLabels": stamp(20)],
                                   deviceID: deviceHigh)

        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(remote, deviceID: deviceHigh))

        let landed = try await store.journal(id: journalID)
        XCTAssertEqual(landed?.name, "Trip to France")
        XCTAssertEqual(landed?.voiceLabels, ["bn": "Grandpa"])
        XCTAssertEqual(landed?.modified, ["name": stamp(10), "voiceLabels": stamp(20)],
                       "raw insert would have restamped name with the local clock")
    }

    func testIngestOfAKnownJournalMergesPerFieldOnDisk() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        try await store.applySyncMerge(
            Journal(id: journalID, name: "Local name", createdAt: stamp(0),
                    voiceLabels: ["bn": "Local label"],
                    modified: ["name": stamp(10), "voiceLabels": stamp(40)]))

        let remote = RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(0),
                                   voiceLabels: ["bn": "Remote label"],
                                   modified: ["name": stamp(30), "voiceLabels": stamp(20)],
                                   deviceID: deviceHigh)
        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(remote, deviceID: deviceHigh))

        let merged = try await store.journal(id: journalID)
        XCTAssertEqual(merged?.name, "Remote name")
        XCTAssertEqual(merged?.voiceLabels, ["bn": "Local label"])
    }

    func testIngestLeavesAJournalTheRemoteNeverMentionedCompletelyUntouched() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "Local only")
        // Read back from disk, not the value `create` returned: `journals.json` stores
        // stamps at millisecond resolution, so the in-memory `Date` and the persisted one
        // are genuinely different values. Comparing against the in-memory one would fail
        // for a reason that has nothing to do with ingest.
        let before = try await store.journal(id: created.id)
        let remote = RemoteJournal(id: journalID, name: "From the other device", createdAt: stamp(0),
                                   modified: ["name": stamp(10)], deviceID: deviceHigh)

        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(remote, deviceID: deviceHigh))

        let after = try await store.journal(id: created.id)
        let count = try await store.list().count
        XCTAssertEqual(after, before, "field for field the same journal, stamps included")
        XCTAssertEqual(count, 2)
    }

    /// The no-echo rule. A sync-caused save that announced itself as a local change would
    /// re-upload what was just downloaded; combined with the deviceID tie-break, two
    /// devices can sit in that loop indefinitely, each one's echo answering the other's.
    func testIngestFiresNoSyncHookAtAll() async throws {
        let hooks = RecordingSyncHooks()
        let store = JournalStore(containerRoot: containerRoot, syncHooks: hooks)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let coverURL = containerRoot.appendingPathComponent("fetched.jpg")
        try Data("fetched-cover-bytes".utf8).write(to: coverURL)

        let remote = RemoteJournal(id: journalID, name: "Trip to France", createdAt: stamp(0),
                                   modified: ["name": stamp(10), "cover": stamp(20)],
                                   deviceID: deviceHigh)
        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(remote, deviceID: deviceHigh, coverFileURL: coverURL))

        let written = try await store.journal(id: journalID)
        XCTAssertNotNil(written, "the ingest really did write")
        let seen = await hooks.names
        XCTAssertEqual(seen, [], "ingest must never look like a local edit")
    }

    func testAWinningRemoteCoverIsWrittenVerbatimAndALosingOneIsNot() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let coverURL = containerRoot.appendingPathComponent("fetched.jpg")
        let fetchedBytes = Data("fetched-cover-bytes".utf8)
        try fetchedBytes.write(to: coverURL)

        // Local has no cover at all and no cover stamp — the remote's stamp wins.
        try await store.applySyncMerge(Journal(id: journalID, name: "J", createdAt: stamp(0),
                                               modified: ["name": stamp(10)]))
        let winning = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                    modified: ["name": stamp(10), "cover": stamp(20)],
                                    deviceID: deviceHigh)
        let ex = exchange(store, covers, deviceID: deviceLow)
        await ex.acceptRemote(remoteRecord(winning, deviceID: deviceHigh, coverFileURL: coverURL))

        let landed = await covers.read(journalID: journalID)
        XCTAssertEqual(landed, fetchedBytes,
                       "written verbatim — re-encoding would leave the two devices holding "
                       + "different bytes for the same picture, and both would keep pushing")

        // Now a fetch whose cover stamp is older than what just landed: bytes must not move.
        let stale = containerRoot.appendingPathComponent("stale.jpg")
        try Data("stale-cover-bytes".utf8).write(to: stale)
        let losing = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["name": stamp(10), "cover": stamp(5)],
                                   deviceID: deviceHigh)
        await ex.acceptRemote(remoteRecord(losing, deviceID: deviceHigh, coverFileURL: stale))

        let unchanged = await covers.read(journalID: journalID)
        XCTAssertEqual(unchanged, fetchedBytes)
    }

    // MARK: Push

    func testRecordToPushCarriesTheStoresCurrentJournalAndItsCover() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        try await covers.write(imageData: Self.makePNG(), journalID: created.id)

        let built = await exchange(store, covers, deviceID: deviceLow)
            .recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        let record = try XCTUnwrap(built)

        XCTAssertEqual(record["name"] as? String, "1987 Journal")
        XCTAssertEqual(record["deviceID"] as? String, deviceLow)
        XCTAssertEqual((record["cover"] as? CKAsset)?.fileURL, covers.url(journalID: created.id))
    }

    func testRecordToPushIsNilForAJournalThatIsNotInTheRegistry() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let record = await exchange(store, covers, deviceID: deviceLow)
            .recordToPush(for: .journal(id: journalID), zoneID: zoneID)
        XCTAssertNil(record)
    }

    /// The ledger digest has to be computed with the *same* formula the reconciliation
    /// scan uses, or the next launch re-enqueues a record that is already on the server —
    /// forever. Asserted end-to-end rather than by comparing two hash calls.
    func testASavedRecordLeavesTheLedgerSatisfyingTheReconciliationScan() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceLow)
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers, bookkeeping: bookkeeping,
                                    scanner: scanner, deviceID: deviceLow)

        let built = await ex.recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        let record = try XCTUnwrap(built)
        await ex.noteSaved(record)

        let ledger = await bookkeeping.ledger()
        let plan = SyncPlanner.reconcile(scan: scanner.scan().artifacts, ledger: ledger)
        let archived = await bookkeeping.systemFields(for: "j.\(created.id)")
        XCTAssertFalse(plan.contains(.journal(id: created.id)),
                       "a record that landed must not be re-enqueued on the next launch")
        XCTAssertNotNil(archived,
                        "system fields archived, so the next push carries the server's change tag")
    }

    /// The fail-safe direction: with no record of what was built, the ledger is left alone
    /// so the reconciliation scan re-enqueues. One redundant upload, never a lost edit.
    func testASaveConfirmationForARecordThisDeviceNeverBuiltDoesNotWriteTheLedger() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers, bookkeeping: bookkeeping,
                                    scanner: SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceLow),
                                    deviceID: deviceLow)

        let stray = SyncRecordBuilders.journalRecord(journal: created, coverFileURL: nil,
                                                     deviceID: deviceLow, zoneID: zoneID)
        await ex.noteSaved(stray)

        let ledger = await bookkeeping.ledger()
        XCTAssertEqual(ledger, [:])
    }

    // MARK: Push conflict

    /// The push half of design §4: the server answers a save with "the server copy moved",
    /// and the same merge that handles a fetched change resolves it. The merged CONTENT is
    /// not assembled in the conflict handler — the resave rebuilds it from the now-merged
    /// store, so there is exactly one path from local state to a pushed record.
    func testAPushConflictMergesTheServerCopyAndAsksForTheRecordToBeResaved() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        // This device changed voiceLabels most recently; the other device changed the name
        // most recently. Both must survive the conflict.
        try await store.applySyncMerge(
            Journal(id: journalID, name: "Local name", createdAt: stamp(0),
                    voiceLabels: ["bn": "Local label"],
                    modified: ["name": stamp(10), "voiceLabels": stamp(40)]))
        let ex = exchange(store, covers, deviceID: deviceLow)

        let serverCopy = remoteRecord(
            RemoteJournal(id: journalID, name: "Remote name", createdAt: stamp(0),
                          voiceLabels: ["bn": "Remote label"],
                          modified: ["name": stamp(30), "voiceLabels": stamp(20)],
                          deviceID: deviceHigh),
            deviceID: deviceHigh)

        let toResave = await ex.resolvePushConflicts([serverCopy])
        XCTAssertEqual(toResave, [.journal(id: journalID)])

        let rebuilt = await ex.recordToPush(for: .journal(id: journalID), zoneID: zoneID)
        let resave = try XCTUnwrap(rebuilt)
        XCTAssertEqual(resave["name"] as? String, "Remote name")
        XCTAssertEqual(resave["voiceLabels"] as? String, #"{"bn":"Local label"}"#)
        XCTAssertEqual(resave["deviceID"] as? String, deviceLow,
                       "the resave is this device's push, whoever won each field")
    }

    func testAConflictOverARecordNameThatDoesNotParseIsIgnored() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let garbage = CKRecord(recordType: "Journal",
                               recordID: CKRecord.ID(recordName: "not-a-record-name", zoneID: zoneID))
        let toResave = await exchange(store, covers, deviceID: deviceLow).resolvePushConflicts([garbage])
        XCTAssertEqual(toResave, [])
    }

    // MARK: Fixtures

    /// A real, ImageIO-decodable image — `JournalCoverStore.write` re-encodes, so arbitrary
    /// bytes would throw `.invalidImage`. `ingest` takes bytes verbatim and needs none of
    /// this.
    static func makePNG(width: Int = 8, height: Int = 8) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }
}

/// Records what the stores announce, so "did this write echo back as a local change?" is a
/// question with an answer instead of an argument.
actor RecordingSyncHooks: SyncHooks {
    private(set) var names: [SyncRecordName] = []

    func noteLocalChange(_ name: SyncRecordName) async {
        names.append(name)
    }

    func reset() {
        names = []
    }
}

/// A clock that moves on every read. `JournalStore`'s stamps are compared, and two writes
/// against a frozen clock produce equal stamps that no ordering assertion can distinguish
/// (memory: frozen-clock-two-mints-coin-flip-order).
final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval = 1) {
        self.current = start
        self.step = step
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(step)
            return current
        }
    }
}
