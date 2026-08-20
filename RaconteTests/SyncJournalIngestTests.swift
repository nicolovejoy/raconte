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

    // MARK: span — merge (for #70)

    private func span(_ startYear: Int, _ endYear: Int? = nil) -> JournalSpan {
        try! JournalSpan(start: PartialDate(year: startYear),
                         end: endYear.map { PartialDate(year: $0) })
    }

    /// Mirrors `testARemoteNewerNameAndALocalNewerVoiceLabelsBothSurvive`'s shape, for the
    /// field #70 exists to wire through: a newer-stamped remote span replaces the local one.
    func testRemoteNewerSpanWins() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            span: span(1990), modified: ["span": stamp(10)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   span: span(1998, 2001), modified: ["span": stamp(20)],
                                   deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.span, span(1998, 2001), "remote's span stamp is newer")
        XCTAssertEqual(merged.modified?["span"], stamp(20))
    }

    /// The other direction: a newer local span survives an older remote one.
    func testLocalNewerSpanSurvivesAnOlderRemote() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            span: span(1990), modified: ["span": stamp(30)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   span: span(1998, 2001), modified: ["span": stamp(20)],
                                   deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.span, span(1990), "local's span stamp is newer")
        XCTAssertEqual(merged.modified?["span"], stamp(30))
    }

    /// Deletion has to propagate exactly like the cover's: a newer-stamped `nil` span must
    /// beat an older non-nil one, or a span deleted on one device would keep coming back from
    /// every peer that has not yet heard about the deletion.
    func testANewerStampedNilSpanDefeatsAnOlderNonNilSpan() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            span: span(1990), modified: ["span": stamp(10)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   span: nil, modified: ["span": stamp(20)],
                                   deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertNil(merged.span, "the remote's deletion is newer and must win")
        XCTAssertEqual(merged.modified?["span"], stamp(20))
    }

    /// A remote that has never touched span leaves the local value untouched, same as the
    /// unstamped-field rule for every other field.
    func testAFieldTheRemoteNeverStampedSpanIsNotTakenOverALocalEdit() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            span: span(1990), modified: ["span": stamp(10)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   span: nil, modified: [:], deviceID: deviceHigh)

        let merged = JournalMerge.merge(local: local, remote: remote,
                                        localDeviceID: deviceLow, remoteDeviceID: deviceHigh)

        XCTAssertEqual(merged.span, span(1990))
    }

    /// `adopted(remote:)` must carry span through, same as every other field on a
    /// never-before-seen journal.
    func testAnAdoptedRemoteJournalCarriesItsSpan() {
        let remote = RemoteJournal(id: journalID, name: "1987 Journal", createdAt: stamp(0),
                                   span: span(1998, 2001), modified: ["span": stamp(10)],
                                   deviceID: deviceHigh)

        let adopted = JournalMerge.adopted(remote: remote)

        XCTAssertEqual(adopted.span, span(1998, 2001))
        XCTAssertEqual(adopted.modified, ["span": stamp(10)])
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
        XCTAssertEqual(JournalMerge.coverAction(local: localNewer, remote: remote,
                                                localDeviceID: deviceLow, remoteDeviceID: deviceHigh), .leave)

        let localOlder = Journal(id: journalID, name: "J", createdAt: stamp(0),
                                 modified: ["cover": stamp(10)])
        XCTAssertEqual(JournalMerge.coverAction(local: localOlder, remote: remote,
                                                localDeviceID: deviceLow, remoteDeviceID: deviceHigh), .adopt)
    }

    /// A remote with a WINNING cover stamp and no asset is a deletion, not a no-op. Reading
    /// it as "nothing to do" left the receiving device showing a picture the owner had
    /// deleted, while `merge` adopted the remote's newer stamp anyway — so its own cover
    /// could never win a later comparison either.
    func testARemoteWithAWinningCoverStampAndNoAssetIsADeletion() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            modified: ["cover": stamp(10)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["cover": stamp(99)], coverAsset: nil, deviceID: deviceHigh)
        XCTAssertEqual(JournalMerge.coverAction(local: local, remote: remote,
                                                localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .remove)
    }

    /// The other direction: THIS device deleted its cover most recently, so an older remote
    /// cover must not come back.
    func testALosingRemoteCoverStampNeverResurrectsADeletedLocalCover() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0),
                            modified: ["cover": stamp(99)])
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["cover": stamp(10)],
                                   coverAsset: containerRoot.appendingPathComponent("old.jpg"),
                                   deviceID: deviceHigh)
        XCTAssertEqual(JournalMerge.coverAction(local: local, remote: remote,
                                                localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .leave)
    }

    func testAJournalNeitherSideEverGaveACoverLeavesTheCoverAlone() {
        let local = Journal(id: journalID, name: "J", createdAt: stamp(0))
        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0), deviceID: deviceHigh)
        XCTAssertEqual(JournalMerge.coverAction(local: local, remote: remote,
                                                localDeviceID: deviceLow, remoteDeviceID: deviceHigh),
                       .leave)
    }

    // MARK: Hooks — every local mutation path reaches the engine

    func testEveryJournalStoreMutationPathFiresTheSyncHookExactlyOnce() async throws {
        let hooks = RecordingSyncHooks()
        let store = JournalStore(containerRoot: containerRoot, syncHooks: hooks)

        let created = try await store.create(name: "1987 Journal")
        _ = try await store.rename(id: created.id, to: "1987 Journal, renamed")
        _ = try await store.setVoiceLabels(id: created.id, labels: ["bn": "Grandpa"])
        // M4 sync (#70): `setSpan` is a new sync writer on this branch (it came from main,
        // where no sync layer existed) and must fire the hook exactly like its siblings —
        // otherwise a span edit sits stamped-but-unpushed until the next launch's
        // reconciliation scan happens to notice the digest moved.
        _ = try await store.setSpan(id: created.id,
                                    span: try JournalSpan(start: PartialDate(year: 1998), end: nil))

        let seen = await hooks.names
        XCTAssertEqual(seen, [.journal(id: created.id), .journal(id: created.id),
                              .journal(id: created.id), .journal(id: created.id)],
                       "create, rename, setVoiceLabels and setSpan each change the record's content")
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
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceLow)

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
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceLow)

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

    // MARK: Atomicity of the ingest read-merge-write (review Critical 1)

    /// A lost update, demonstrated and then fixed, in one test.
    ///
    /// **First half** reproduces the shape ingest used to have — read the journal, suspend,
    /// merge against what was read, write the whole thing back — and shows a rename landing
    /// in that window being silently reverted. `applySyncMerge` replaces the entire
    /// `Journal`, stamps included, so the newer local stamp is destroyed too and the revert
    /// is what the next push propagates: the edit is gone on both devices.
    ///
    /// **Second half** runs the same interleaving against `applySyncMerge(id:decide:)`. The
    /// rename is fired first and deliberately made to arrive *while the merge is running*:
    /// the `decide` closure holds the store's executor for 200 ms, and because the closure
    /// is synchronous it cannot suspend, so nothing — not the rename, not another ingest —
    /// can slip between the load and the save. The rename therefore applies on top of the
    /// merge instead of being erased by it.
    ///
    /// Blocking inside an actor is exactly what production must never do; here it is the
    /// instrument, and it is what makes this deterministic instead of a race the suite
    /// would flake on.
    func testAnIngestCannotRevertARenameThatLandsWhileItIsMerging() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let (jid, low, high) = (journalID, deviceLow, deviceHigh)
        let seed = Journal(id: jid, name: "Original", createdAt: stamp(0),
                           modified: ["name": stamp(10)])
        _ = try await store.applySyncMerge(id: jid) { _ in
            JournalSyncMerge(journal: seed, coverAction: .leave)
        }
        // A remote that changes nothing this test looks at, so any movement in `name` is
        // the interleaving and not the merge.
        let remote = RemoteJournal(id: jid, name: "Original", createdAt: stamp(0),
                                   modified: ["name": stamp(10)], deviceID: high)

        // --- The old shape: read, suspend, write back a merge computed against the read.
        let read = try await store.journal(id: journalID)
        let staleRead = try XCTUnwrap(read)
        _ = try await store.rename(id: journalID, to: "Renamed during the merge")
        try await store.applySyncMerge(JournalMerge.merge(local: staleRead, remote: remote,
                                                          localDeviceID: deviceLow,
                                                          remoteDeviceID: deviceHigh))
        let afterOldShape = try await store.journal(id: journalID)
        XCTAssertEqual(afterOldShape?.name, "Original",
                       "documents the defect: the rename was silently reverted")

        // --- The fixed shape: one isolated call, with the rename racing it for real.
        let renaming = Task { [store] in
            try await store.rename(id: jid, to: "Renamed during the merge")
        }
        let action = try await store.applySyncMerge(id: jid) { local in
            // Held long enough that the rename above is certainly waiting on this actor.
            // A synchronous closure cannot suspend, so it cannot let go.
            Thread.sleep(forTimeInterval: 0.2)
            return JournalSyncMerge(
                journal: JournalMerge.merge(local: local ?? seed, remote: remote,
                                            localDeviceID: low, remoteDeviceID: high),
                coverAction: .leave)
        }
        _ = try await renaming.value

        let afterFixedShape = try await store.journal(id: journalID)
        XCTAssertEqual(action, .leave)
        XCTAssertEqual(afterFixedShape?.name, "Renamed during the merge",
                       "the rename applied on top of the merge instead of being erased by it")
    }

    /// The same guarantee as a property rather than a single race: ten renames against ten
    /// ingests, all at once. Every ingest's remote `name` stamp loses to every rename's, so
    /// the survivor must be a name a rename actually wrote — never `Original` (a revert)
    /// and never `Remote name` (a stale read winning).
    func testConcurrentIngestsAndRenamesNeverProduceAStateNoWriterWrote() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let (jid, low, high) = (journalID, deviceLow, deviceHigh)
        let seed = Journal(id: jid, name: "Original", createdAt: stamp(0),
                           modified: ["name": stamp(10)])
        _ = try await store.applySyncMerge(id: jid) { _ in
            JournalSyncMerge(journal: seed, coverAction: .leave)
        }
        let remote = RemoteJournal(id: jid, name: "Remote name", createdAt: stamp(0),
                                   modified: ["name": stamp(5)], deviceID: high)

        await withTaskGroup(of: Void.self) { group in
            for round in 0..<10 {
                group.addTask { [store] in
                    _ = try? await store.rename(id: jid, to: "Rename \(round)")
                }
                group.addTask { [store] in
                    _ = try? await store.applySyncMerge(id: jid) { local in
                        JournalSyncMerge(
                            journal: JournalMerge.merge(local: local ?? seed, remote: remote,
                                                        localDeviceID: low, remoteDeviceID: high),
                            coverAction: .leave)
                    }
                }
            }
        }

        let settled = try await store.journal(id: journalID)
        let final = try XCTUnwrap(settled)
        XCTAssertTrue(final.name.hasPrefix("Rename "), "ended on \(final.name)")
    }

    // MARK: Cover deletion propagation (review Critical 2)

    func testACoverDeletedOnTheOtherDeviceIsRemovedHereAndTheStampMovesWithIt() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        try await store.applySyncMerge(Journal(id: journalID, name: "J", createdAt: stamp(0),
                                               modified: ["name": stamp(10), "cover": stamp(20)]))
        try await covers.ingest(imageData: Data("a-real-cover".utf8), journalID: journalID)

        // The other device deleted its cover: newer cover stamp, no asset on the record.
        let deletion = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                     modified: ["name": stamp(10), "cover": stamp(50)],
                                     coverAsset: nil, deviceID: deviceHigh)
        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(deletion, deviceID: deviceHigh))

        let bytes = await covers.read(journalID: journalID)
        let journal = try await store.journal(id: journalID)
        XCTAssertNil(bytes, "the deleted cover must not keep being displayed here")
        XCTAssertEqual(journal?.modified?["cover"], stamp(50),
                       "and the stamp moved with it — the poisoned state is stamp-without-bytes, "
                       + "where this device can never win a cover comparison again")
    }

    /// The reverse direction: a deletion made HERE is not undone by an older remote cover.
    func testAnOlderRemoteCoverDoesNotResurrectACoverDeletedOnThisDevice() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        try await store.applySyncMerge(Journal(id: journalID, name: "J", createdAt: stamp(0),
                                               modified: ["name": stamp(10), "cover": stamp(90)]))
        let stale = containerRoot.appendingPathComponent("stale.jpg")
        try Data("an-old-cover".utf8).write(to: stale)

        let remote = RemoteJournal(id: journalID, name: "J", createdAt: stamp(0),
                                   modified: ["name": stamp(10), "cover": stamp(20)],
                                   deviceID: deviceHigh)
        await exchange(store, covers, deviceID: deviceLow)
            .acceptRemote(remoteRecord(remote, deviceID: deviceHigh, coverFileURL: stale))

        let bytes = await covers.read(journalID: journalID)
        let journal = try await store.journal(id: journalID)
        XCTAssertNil(bytes)
        XCTAssertEqual(journal?.modified?["cover"], stamp(90), "this device's deletion stands")
    }

    // MARK: In-flight build accounting (review Important 1 and 2)

    /// Two builds of the same record before either confirms cannot be told apart by record
    /// name, so neither confirmation may write the ledger. Crediting the confirmation to
    /// the newer digest would ledger content that was never sent, and reconciliation would
    /// then see ledger == disk and never send the second edit.
    func testTwoBuildsBeforeAConfirmLeaveTheLedgerAloneSoReconciliationStillSends() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceLow)
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceLow)

        let firstBuild = await ex.recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        let first = try XCTUnwrap(firstBuild)
        _ = try await store.rename(id: created.id, to: "1987 Journal, renamed")
        let secondBuild = await ex.recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        XCTAssertNotNil(secondBuild)

        // The FIRST build's save confirms. Its content is stale on disk by now.
        await ex.noteSaved(first)

        let ledger = await bookkeeping.ledger()
        let plan = SyncPlanner.reconcile(scan: scanner.scan().artifacts, ledger: ledger)
        XCTAssertEqual(ledger, [:], "an unattributable confirmation must not write the ledger")
        XCTAssertTrue(plan.contains(.journal(id: created.id)),
                      "the renamed journal is still queued to send")
    }

    /// The ledger must describe what was PUSHED, not what is on disk when the confirmation
    /// arrives. Re-reading at confirm time would record the newer content as uploaded, and
    /// the edit would never be sent at all.
    func testTheLedgerRecordsTheContentThatWasBuiltNotWhatIsOnDiskAtConfirmTime() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceLow)
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceLow)

        let build = await ex.recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        let built = try XCTUnwrap(build)
        // The owner edits while that push is in flight.
        _ = try await store.rename(id: created.id, to: "1987 Journal, renamed")
        await ex.noteSaved(built)

        let ledger = await bookkeeping.ledger()
        let plan = SyncPlanner.reconcile(scan: scanner.scan().artifacts, ledger: ledger)
        XCTAssertEqual(ledger.count, 1, "the confirmed build is ledgered")
        XCTAssertTrue(plan.contains(.journal(id: created.id)),
                      "and the newer content is still queued, because the ledger describes "
                      + "what actually went up")
    }

    func testAFailedSaveDiscardsTheBuildSoALaterConfirmCannotBeCreditedToIt() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let created = try await store.create(name: "1987 Journal")
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let ex = SyncRecordExchange(journalStore: store, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceLow)

        let build = await ex.recordToPush(for: .journal(id: created.id), zoneID: zoneID)
        let built = try XCTUnwrap(build)
        await ex.noteSaveFailed(for: .journal(id: created.id))
        await ex.noteSaved(built)

        let ledger = await bookkeeping.ledger()
        XCTAssertEqual(ledger, [:], "a build the server rejected must never reach the ledger")
    }

    // MARK: Ingest failure honesty (review Important 3)

    /// A write that did not happen must not announce that it did — the UI would rescan and
    /// re-render exactly what it already had, hiding the failure rather than surfacing it.
    func testAFailedIngestWriteDoesNotSignalTheLibraryToReload() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        // An unreadable registry: present, undecodable. `JournalStore.load` throws rather
        // than treating it as empty (issue #11's rule), so the ingest cannot write.
        try Data("not json".utf8).write(to: AppContainer.journalsURL(containerRoot: containerRoot))

        let signals = SignalCounter()
        let ex = SyncRecordExchange(
            journalStore: store, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: deviceLow,
            localStoreDidChange: { await signals.increment() })

        let remote = RemoteJournal(id: journalID, name: "Trip to France", createdAt: stamp(0),
                                   modified: ["name": stamp(10)], deviceID: deviceHigh)
        await ex.acceptRemote(remoteRecord(remote, deviceID: deviceHigh))

        let count = await signals.count
        XCTAssertEqual(count, 0, "nothing was written, so nothing should have been announced")
    }

    func testASuccessfulIngestDoesSignalTheLibraryToReload() async throws {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let signals = SignalCounter()
        let ex = SyncRecordExchange(
            journalStore: store, coverStore: covers,
            bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
            deviceID: deviceLow,
            localStoreDidChange: { await signals.increment() })

        let remote = RemoteJournal(id: journalID, name: "Trip to France", createdAt: stamp(0),
                                   modified: ["name": stamp(10)], deviceID: deviceHigh)
        await ex.acceptRemote(remoteRecord(remote, deviceID: deviceHigh))

        let count = await signals.count
        XCTAssertEqual(count, 1, "or the rename sits on disk unseen until the next launch")
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

/// Counts the "something actually landed locally" announcements, so "did a failed write
/// still tell the UI to reload?" is a question with an answer.
actor SignalCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
