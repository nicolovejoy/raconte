import XCTest
@testable import Raconte

/// M3 T4's model layer: what a rescan publishes, what a filter change does to it, and
/// the generation guard that decides which of two overlapping scans wins.
@MainActor
final class LibraryScreenModelTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    /// Real ULIDs — the scan reads its date fallback out of the id.
    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    private let idC = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScreenModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    /// One capture with real frames on disk, captured at `capturedAt`.
    private func writeCapture(_ id: String,
                              capturedAt: Double,
                              journalID: String? = nil,
                              frames: Int = 48_000) throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: frames * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))

        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: capturedAt)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))

        if let journalID {
            try EntryMetadataStore.write(
                EntryMetadata(journalID: journalID),
                url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
        }
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    private func journal(_ id: String, _ name: String) -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: Rescan

    func testRescanPopulatesItemsAndJournals() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000)

        let model = model()
        await model.rescan()

        XCTAssertEqual(Set(model.items.map(\.captureID)), [idA, idB])
        XCTAssertEqual(model.journals.map(\.name), ["1987"])
        XCTAssertFalse(model.journalsUnreadable)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.items.first(where: { $0.captureID == idA })?.journal?.name, "1987")
    }

    // MARK: Filters

    func testSelectingAJournalScopeNarrowsTheList() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000)

        let model = model()
        await model.rescan()
        XCTAssertEqual(model.items.count, 2)

        await model.selectJournalScope(.journal("J1"))
        XCTAssertEqual(model.items.map(\.captureID), [idA])

        await model.selectJournalScope(.unfiled)
        XCTAssertEqual(model.items.map(\.captureID), [idB])

        await model.selectJournalScope(.all)
        XCTAssertEqual(model.items.count, 2)
    }

    // MARK: Journal date ranges (issue #14 part 2)

    /// `dateRange` reads off `allEntries`, not the currently filtered `items` — narrowing
    /// the scope to a different journal must not change another journal's range.
    func testDateRangeIsIndependentOfJournalScope() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trip")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000, journalID: "J1")
        try writeCapture(idC, capturedAt: 3_000, journalID: "J2")

        let model = model()
        await model.selectJournalScope(.journal("J2"))

        let range = try XCTUnwrap(model.dateRange(forJournal: "J1"))
        XCTAssertEqual(range.minDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(range.maxDate, Date(timeIntervalSince1970: 2_000))
    }

    /// #75: the header card read `items.count` (scope-filtered) while the editor counted
    /// `allEntries` — 40 vs 6 for the same journal in the frames before a rescan landed.
    func testEntryCountIsIndependentOfJournalScope() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trip")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000, journalID: "J1")
        try writeCapture(idC, capturedAt: 3_000, journalID: "J2")

        let model = model()
        await model.selectJournalScope(.journal("J2"))
        XCTAssertEqual(model.items.count, 1, "precondition: the scope narrows items")
        XCTAssertEqual(model.entryCount(forJournal: "J1"), 2)
        XCTAssertEqual(model.entryCount(forJournal: "J2"), 1)
        XCTAssertEqual(model.entryCount(forJournal: "nope"), 0)
    }

    func testDateRangeIsNilForAnEmptyOrUnknownJournal() async throws {
        try writeJournals([journal("J1", "1987")])
        let model = model()
        await model.rescan()
        XCTAssertNil(model.dateRange(forJournal: "J1"))
        XCTAssertNil(model.dateRange(forJournal: "does-not-exist"))
    }

    // MARK: Honesty signals

    func testUnreadableRegistryIsPublishedRatherThanReadAsNoJournals() async throws {
        try Data("{ not json".utf8)
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")

        let model = model()
        await model.rescan()

        XCTAssertTrue(model.journalsUnreadable)
        XCTAssertTrue(model.journals.isEmpty)
        XCTAssertEqual(model.items.map(\.captureID), [idA], "entries stay visible")
        XCTAssertTrue(try XCTUnwrap(model.items.first).degradations.contains(.journalUnresolved))
    }

    func testAbsentRegistryIsNotUnreadable() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.rescan()
        XCTAssertFalse(model.journalsUnreadable)
    }

    /// A directory with nothing durable in it is skipped, and the skip reaches the model
    /// rather than dying in the scan result.
    func testSkippedDirectoriesAreCarriedToTheModel() async throws {
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try writeCapture(idB, capturedAt: 2_000)

        let model = model()
        await model.rescan()
        XCTAssertEqual(model.items.map(\.captureID), [idB])
        XCTAssertEqual(model.skipped, [SkippedCapture(captureID: idA, reason: .noDurableContent)])
    }

    func testIsLoadingIsClearedByTheScanThatFinishes() async throws {
        let model = model()
        XCTAssertFalse(model.isLoading)
        await model.rescan()
        XCTAssertFalse(model.isLoading)
    }

    // MARK: Generation guard

    /// Two scans in flight: the one started *last* owns the published state, whichever
    /// finishes first. Without the guard the later-finishing scan wins, so a filter
    /// change can be silently reverted by the previous filter's results.
    func testTheLastStartedScanWinsRegardlessOfWhichFinishesFirst() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)

        let model = model()
        model.journalScope = .journal("J1")
        // A narrow scan, left in flight. Narrow is deliberately the *slow* side: a
        // non-`.all` scope runs a second scan for `recent`, so this one reliably lands
        // after the `.all` scan below and, unguarded, overwrites it.
        let stale = Task { await model.rescan() }
        await Task.yield()   // let it snapshot `.journal("J1")` and suspend

        await model.selectJournalScope(.all)
        await stale.value

        XCTAssertEqual(model.journalScope, .all)
        XCTAssertEqual(Set(model.items.map(\.captureID)), [idA, idB, idC],
                       "a superseded scan published its results over the current filter")
        XCTAssertFalse(model.isLoading)
    }

    // MARK: Transcript (detail screen)

    func testTranscriptReturnsTheConsolidatedTextAndItsDegradations() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        for (text, start, end) in [("wrecked a nice beach", Int64(0), Int64(9_600)),
                                   ("recognize speech", 0, 9_600)] {
            try writer.append(TranscriptRecord(seq: 0, text: text,
                                               captureFrameStart: start, captureFrameEnd: end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()

        let transcript = await model().transcript(for: idA)
        XCTAssertEqual(transcript.state, .present)
        XCTAssertEqual(transcript.text, "recognize speech", "the revision replaces its span")
        XCTAssertFalse(transcript.isTruncated, "no ref on the manifest means unknown, not truncated")
    }

    /// The defect finding 2 named: the row said "may be incomplete" and the detail screen
    /// said nothing, because only the scanner computed truncation. Both read it now.
    func testTruncationIsVisibleToTheDetailScreenAndTheRowAlike() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(seq: 0, text: "one", captureFrameStart: 0,
                                           captureFrameEnd: 4_800,
                                           generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()

        // A ref claiming three records against a one-line log: the tail was lost.
        let url = SegmentLayout.manifestURL(captureDirectory: captureDir(idA))
        var manifest = try CaptureCoding.decoder().decode(Manifest.self, from: Data(contentsOf: url))
        manifest.transcript = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                            committedRecords: 3,
                                            completedAt: Date(timeIntervalSince1970: 5))
        try CaptureCoding.encoder().encode(manifest).write(to: url)

        let model = model()
        await model.rescan()
        let row = try XCTUnwrap(model.items.first)
        let transcript = await model.transcript(for: idA)

        XCTAssertTrue(row.degradations.contains(.transcriptTruncated))
        XCTAssertTrue(transcript.isTruncated, "the detail screen used to miss this entirely")
        XCTAssertEqual(transcript.text, "one", "the surviving text is still real")
        XCTAssertEqual(row.snippet, transcript.snippet)
    }

    func testAbsentAndUnreadableStayDistinctForTheDetailScreen() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let absent = await model().transcript(for: idA)
        XCTAssertEqual(absent.state, .absent)
        XCTAssertNil(absent.text)

        let log = SegmentLayout.liveTranscriptURL(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: log.path) }
        guard !FileManager.default.isReadableFile(atPath: log.path) else {
            throw XCTSkip("running with privileges that ignore file permissions")
        }
        let unreadable = await model().transcript(for: idA)
        XCTAssertEqual(unreadable.state, .unreadable)
        XCTAssertTrue(unreadable.degradations.contains(.transcriptUnreadable))
    }

    // MARK: Row lookup (issue #32)

    /// `item` is journal-scope-independent. The capture screen's recents strip is built
    /// from `allEntries`, so tapping a recent filed in another journal pushes a captureID
    /// the filtered `items` does not contain — a lookup that only searched `items` handed
    /// the navigation destination a nil and pushed a blank page.
    func testItemFindsAnEntryOutsideTheActiveJournalScope() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trip")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000, journalID: "J2")

        let model = model()
        await model.selectJournalScope(.journal("J1"))
        XCTAssertEqual(model.items.map(\.captureID), [idA], "the list still follows the filter")

        XCTAssertEqual(model.item(idB)?.captureID, idB, "the lookup does not")
        XCTAssertEqual(model.item(idB)?.journal?.name, "Trip")
    }

    /// The other two answers the lookup owes: an in-scope row, and a trashed one (which is
    /// in neither `items` nor `allEntries`). `nil` means the capture exists nowhere.
    func testItemFindsInScopeAndTrashedEntriesAndNilsAnUnknownID() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000, journalID: "J1")

        let model = model()
        await model.selectJournalScope(.journal("J1"))
        await model.trashEntry(idB)

        XCTAssertEqual(model.item(idA)?.captureID, idA)
        XCTAssertEqual(model.item(idB)?.captureID, idB)
        XCTAssertNil(model.item(idC))
    }

    // MARK: Edits

    func testMoveEntryRewritesTheSidecarAndTheList() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trip")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")

        let model = model()
        await model.rescan()
        await model.moveEntry(idA, toJournal: "J2")

        XCTAssertEqual(model.item(idA)?.journal?.name, "Trip")
        let persisted = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))
        XCTAssertEqual(persisted.journalID, "J2")
    }

    /// #84 point 2, review fix round: the entry detail screen's journal picker
    /// (`moveEntry`) files an entry into a journal exactly like the live-capture path —
    /// a still-provisional default must promote and push here too, not just when the
    /// entry's `journalID` is set via `CaptureScreenModel.enqueueEntryMetadataWrite`.
    /// [required, mutation-verified]: removing `moveEntry`'s
    /// `promoteProvisionalDefaultAfterEntrySave` call fails this test.
    func testMoveEntryIntoAProvisionalDefaultPromotesAndPushesIt() async throws {
        try writeJournals([journal("J1", "1987"),
                           Journal(id: "J2", name: "Journal", createdAt: Date(timeIntervalSince1970: 0),
                                  provisionalDefault: true)])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")

        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        await model.journalStore.attach(syncHooks: hooks)
        await model.rescan()

        let moved = await model.moveEntry(idA, toJournal: "J2")

        XCTAssertTrue(moved)
        let changes = await hooks.changedNames
        XCTAssertEqual(changes, [.journal(id: "J2")],
                       "filing an entry into a provisional default via the detail screen "
                       + "must promote and push it, or it sits invisible to CloudKit forever")
        let stored = try await model.journalStore.journal(id: "J2")
        XCTAssertEqual(stored?.provisionalDefault, false)
    }

    func testSetBackdateMovesTheEntryInTheSortAndSurvivesClearing() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)

        let model = model()
        await model.rescan()
        XCTAssertEqual(model.items.map(\.captureID), [idB, idA])

        // Well clear of the epoch: a near-epoch instant lands on 1969-12-31 or
        // 1970-01-01 depending on the runner's timezone, and the noon anchor of the
        // latter sorts *after* this fixture's capturedAt values (caught on CI, UTC).
        await model.setBackdate(idB, to: Date(timeIntervalSince1970: -50_000_000))
        XCTAssertEqual(model.items.map(\.captureID), [idA, idB])
        XCTAssertTrue(try XCTUnwrap(model.item(idB)).isBackdated)

        await model.setBackdate(idB, to: nil)
        XCTAssertEqual(model.items.map(\.captureID), [idB, idA])
        XCTAssertFalse(try XCTUnwrap(model.item(idB)).isBackdated)
    }

    /// Precision persists with the backdate and resets when the backdate is cleared —
    /// there is nothing left for it to describe once `originalDate` is nil.
    func testSetBackdateCarriesPrecisionAndClearingResetsIt() async throws {
        try writeCapture(idA, capturedAt: 1_000)

        let model = model()
        await model.rescan()

        await model.setBackdate(idA, to: Date(timeIntervalSince1970: 10), precision: .yearMonth)
        XCTAssertEqual(try XCTUnwrap(model.item(idA)).originalDatePrecision, .yearMonth)

        await model.setBackdate(idA, to: nil)
        let persisted = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))
        XCTAssertNil(persisted.originalDate)
    }

    // MARK: - Journal editing (journal-editing IA, Task 6)

    func testRenameJournalRewritesTheRegistryAndRescans() async throws {
        try writeJournals([journal("J1", "Old Name")])

        let model = model()
        await model.rescan()
        let renamed = await model.renameJournal("J1", to: "New Name")

        XCTAssertTrue(renamed)
        XCTAssertEqual(model.journals.first { $0.id == "J1" }?.name, "New Name")
        let persisted = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertEqual(persisted.first { $0.id == "J1" }?.name, "New Name")
    }

    /// The editor's "deleted underneath us" case (design ruling): renaming an id no
    /// longer in the registry returns `false` rather than silently inserting nothing.
    func testRenameJournalReturnsFalseForAnUnknownID() async throws {
        try writeJournals([journal("J1", "Real")])

        let model = model()
        await model.rescan()
        let renamed = await model.renameJournal("does-not-exist", to: "New Name")

        XCTAssertFalse(renamed)
        XCTAssertEqual(model.journals.first { $0.id == "J1" }?.name, "Real")
    }

    func testSetJournalVoiceLabelsRewritesTheRegistryAndRescans() async throws {
        try writeJournals([journal("J1", "Two Voices")])

        let model = model()
        await model.rescan()
        let saved = await model.setJournalVoiceLabels("J1", labels: [VoiceDisplay.mainVoice: "Grandpa"])

        XCTAssertTrue(saved)
        XCTAssertEqual(model.journals.first { $0.id == "J1" }?.voiceLabels[VoiceDisplay.mainVoice], "Grandpa")
    }

    // MARK: - Journal deletion (#80, v1: empty journals only)

    func testDeleteJournalRemovesAnEmptyJournalAndRescans() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")

        let model = model()
        await model.rescan()
        let deleted = await model.deleteJournal("J2")

        XCTAssertTrue(deleted)
        XCTAssertNil(model.journals.first { $0.id == "J2" })
        let persisted = try await JournalStore(containerRoot: containerRoot).list()
        XCTAssertNil(persisted.first { $0.id == "J2" }, "the delete must have reached disk")
    }

    /// v1 scope (#80 owner ruling 1): a journal with a live entry is refused, full stop
    /// — there is no "move the entries out first" flow yet.
    func testDeleteJournalRefusesWhenTheJournalHasALiveEntry() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Has an entry")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")

        let model = model()
        await model.rescan()
        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.journals.first { $0.id == "J2" }, "the journal must survive")
    }

    /// The orphan-on-restore case (#80 owner ruling 1, the load-bearing guard): a journal
    /// holding only a TRASHED entry is NOT empty. If this journal were deleted anyway,
    /// restoring that entry later would file it into a journal that no longer exists.
    func testDeleteJournalRefusesWhenTheJournalHasOnlyATrashedEntry() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trashed entry only")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")

        let model = model()
        await model.rescan()
        let trashed = await model.trashEntry(idA)
        XCTAssertTrue(trashed, "fixture sanity: the trash write succeeded")
        XCTAssertTrue(model.trashed.contains { $0.captureID == idA },
                     "fixture sanity: the entry is really in the trash list")
        XCTAssertFalse(model.allEntries.contains { $0.captureID == idA },
                      "fixture sanity: a trashed entry is not also a live one")

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "a journal with a trashed entry is not empty")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" }, "the journal must survive")
    }

    func testDeleteJournalReturnsFalseForAnUnknownID() async throws {
        try writeJournals([journal("J1", "Real")])

        let model = model()
        await model.rescan()
        let deleted = await model.deleteJournal("does-not-exist")

        XCTAssertFalse(deleted)
    }

    func testDeleteJournalRefusesTheLastRemainingJournal() async throws {
        try writeJournals([journal("J1", "Only one")])

        let model = model()
        await model.rescan()
        let deleted = await model.deleteJournal("J1")

        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.journals.first { $0.id == "J1" })
    }

    /// Gate finding (Important, task B1 review): `isJournalEmpty` reads the LAST scan,
    /// not disk truth. A destructive caller must rescan before evaluating it, or an entry
    /// that lands after the last scan — a background sync ingest arriving while a
    /// confirmation dialog sits open, most concretely — would read as belonging to an
    /// empty journal and be orphaned by the delete that follows. This is the same shape
    /// as `testDeleteJournalRefusesWhenTheJournalHasOnlyATrashedEntry` above, reached by a
    /// different arrival path: an entry written to disk WITHOUT going through a rescan.
    func testDeleteJournalRescansFirstSoAnEntryThatArrivedAfterTheLastScanStillRefuses() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty as of the last scan")])

        let model = model()
        await model.rescan()
        XCTAssertTrue(model.isJournalEmpty("J2"), "fixture sanity: empty as of this scan")

        // The entry lands on disk WITHOUT a rescan — the model's cached `allEntries`
        // still does not know about it. This is the staleness `deleteJournal` must not
        // trust.
        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")
        XCTAssertFalse(model.allEntries.contains { $0.captureID == idA },
                      "fixture sanity: the cached scan predates this entry")

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "a fresh scan must see the entry that arrived after the last one")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" }, "the journal must survive")
        XCTAssertTrue(model.allEntries.contains { $0.captureID == idA },
                     "deleteJournal's own rescan must have picked up the new entry")
    }

    // MARK: - Freshness: a scan that published nothing must never answer a destructive
    // question (gate finding, Critical 1)

    /// The primitive the whole fix rests on: `rescan()` reports whether THIS call
    /// published. Deterministic — once the second scan has bumped the generation, the
    /// first can never match it again, whatever order they finish in.
    func testRescanReportsWhetherItPublishedOrWasSuperseded() async throws {
        try writeJournals([journal("J1", "1987")])
        let model = model()

        let first = Task { await model.rescan() }
        await Task.yield()          // `first` is now inside its own scan, suspended
        let secondWon = await model.rescan()
        let firstWon = await first.value

        XCTAssertFalse(firstWon, "a superseded scan publishes nothing and must say so")
        XCTAssertTrue(secondWon, "the scan that actually published must say so")
    }

    /// Gate finding, Critical 1, reproduced verbatim before the fix
    /// (`PROBE deleteJournal=true survives=false` — a journal holding a 48,000-frame
    /// capture deleted). A rescan that merely STARTS while `deleteJournal`'s own scan is
    /// in flight supersedes it; the superseded scan publishes nothing and used to return
    /// indistinguishably from one that had, so the emptiness check read pre-scan state.
    func testDeleteJournalRefusesWhenItsOwnRescanWasSupersededByAConcurrentOne() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty as of the last scan")])

        let model = model()
        await model.rescan()
        XCTAssertTrue(model.isJournalEmpty("J2"), "fixture sanity: empty as of this scan")

        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")

        let delete = Task { await model.deleteJournal("J2") }
        await Task.yield()
        let competing = Task { await model.rescan() }
        let deleted = await delete.value
        await competing.value

        XCTAssertFalse(deleted, "a delete whose own scan was superseded must not proceed")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" },
                        "must never orphan a real recording into a deleted journal")
    }

    /// The same hole on the sync-ingest seam — the load-bearing one, since an inbound
    /// deletion for a journal that is empty on the DELETING device is the normal case
    /// (entries do not sync yet), so this check is all that stands between a peer's
    /// delete and 47 local entries.
    func testIsJournalEmptyAfterRescanRefusesWhenItsOwnRescanWasSuperseded() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty as of the last scan")])

        let model = model()
        await model.rescan()
        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")

        let ask = Task { await model.isJournalEmptyAfterRescan("J2") }
        await Task.yield()
        let competing = Task { await model.rescan() }
        let empty = await ask.value
        await competing.value

        XCTAssertFalse(empty, "a superseded scan must never answer a destructive question")
    }

    /// The give-up branch, exercised directly: with no fresh scan obtainable at all, both
    /// destructive paths must REFUSE rather than fall back on whatever is published.
    /// `freshScanAttempts: 0` is the honest way to reach it — a livelock is otherwise only
    /// reachable by timing, and "refuses when it cannot prove freshness" is a structural
    /// claim that should not be pinned by a race.
    func testBothDestructivePathsRefuseWhenNoFreshScanIsObtainable() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Genuinely empty")])
        let model = model()
        await model.rescan()
        XCTAssertTrue(model.isJournalEmpty("J2"), "fixture sanity: this journal really is empty")

        let empty = await model.isJournalEmptyAfterRescan("J2", freshScanAttempts: 0)
        let deleted = await model.deleteJournal("J2", freshScanAttempts: 0)

        XCTAssertFalse(empty, "unproven-fresh must read as not-empty, never as empty")
        XCTAssertFalse(deleted, "a delete that cannot prove freshness must not proceed")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" }, "the journal must survive")
    }

    // MARK: - Emptiness is three answers, not two (gate findings, Important 2 and 3)

    /// An entry whose `entry.json` did not decode scans with `journalID == nil`, so it
    /// protects no journal at all — while the capture itself holds real audio that IS
    /// filed somewhere. "I cannot read which journal this belongs to" must not read as
    /// "it belongs to no journal".
    func testDeleteJournalRefusesWhileAnyEntrysSidecarIsUnreadable() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Looks empty")])
        try writeCapture(idA, capturedAt: 1_000)     // real frames, no sidecar yet
        try Data("{ not json".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        await model.rescan()
        XCTAssertTrue(model.allEntries.contains {
            $0.captureID == idA && $0.degradations.contains(.metadataUnreadable)
        }, "fixture sanity: the entry scanned as metadata-unreadable, with a row of its own")
        XCTAssertNil(model.allEntries.first { $0.captureID == idA }?.journalID,
                     "fixture sanity: and it therefore names no journal — the whole hazard")

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "an unreadable sidecar might name this journal — refuse")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    // MARK: - #81: quarantine an unreadable-sidecar capture, never delete it

    func testUnreadableEntriesListsExactlyTheCapturesWithAnUnreadableSidecar() async throws {
        try writeCapture(idA, capturedAt: 1_000)     // healthy, no sidecar written
        try writeCapture(idB, capturedAt: 2_000)
        try Data("{ not json".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB)))

        let model = model()
        await model.rescan()

        XCTAssertEqual(model.unreadableEntries.map(\.captureID), [idB])
    }

    func testQuarantiningTheUnreadableEntryUnblocksJournalDeletion() async throws {
        // J1 is empty apart from the unreadable capture, which is filed nowhere — the
        // whole #82 hazard this task fixes: an unreadable sidecar blocks EVERY journal,
        // not just whichever one it might belong to.
        try writeJournals([journal("J1", "Looks empty")])
        try writeCapture(idB, capturedAt: 2_000)     // filed nowhere — the whole hazard
        try Data("{ not json".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB)))

        let model = model()
        await model.rescan()
        XCTAssertEqual(model.emptinessVerdict(forJournal: "J1"), .blockedHard,
                       "fixture sanity: the unreadable sidecar blocks every journal")

        try await model.quarantineUnreadable(captureID: idB)

        XCTAssertTrue(model.unreadableEntries.isEmpty)
        XCTAssertNotEqual(model.emptinessVerdict(forJournal: "J1"), .blockedHard)
        let quarantined = AppContainer.quarantineRoot(containerRoot: containerRoot)
        let children = try FileManager.default.contentsOfDirectory(atPath: quarantined.path)
        XCTAssertEqual(children.count, 1)
        let moved = quarantined.appendingPathComponent(children[0], isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.pcmURL(
                segmentsDirectory: SegmentLayout.segmentsDirectory(captureDirectory: moved), index: 0).path),
            "the audio must still exist under quarantine/")
    }

    // MARK: - #82: resolve worthless zero-frame blockers on demand

    /// A capture filed into the journal that has no durable content yet — reachable in
    /// production between `CaptureScreenModel.handlePhase` writing `entry.json` at
    /// `.recording` and the first audio frames reaching disk. The scan skips it (no row),
    /// so the ordinary emptiness test cannot see it.
    ///
    /// Owner ruling 2026-08-22: a mis-tapped, abandoned capture like this one must NOT
    /// block its journal's deletion until the next launch's recovery pass. With the
    /// probe attached and honestly reporting no active capture, `deleteJournal` now runs
    /// the SAME recovery machinery `recoverAtLaunch()` runs — scoped to exactly this one
    /// directory — and the worthless capture is gone, on this call, not at next launch.
    func testDeleteJournalResolvesAnInactiveWorthlessBlockerAndSucceeds() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { nil }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA],
                       "fixture sanity: the scan skipped it as having no durable content")

        let deleted = await model.deleteJournal("J2")

        XCTAssertTrue(deleted, "an inactive worthless blocker must not wait for relaunch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path),
                       "the worthless capture directory was resolved away")
        XCTAssertNil(model.journals.first { $0.id == "J2" })
    }

    /// The probe is the only thing standing between "worthless" and "currently being
    /// recorded into". When it reports THIS exact capture as active, on-demand
    /// resolution must refuse to touch it — the fail-safe half of the same rule.
    func testDeleteJournalRefusesWhenTheOnlyBlockerIsTheActiveCapture() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { self.idA }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA], "fixture sanity")

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "the only blocker is the capture in progress — refuse")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path),
                      "an active capture's directory must never be touched")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    /// Fail-safe default (#82): a probe that was never attached must mean "unknown",
    /// never "safe to resolve". A missing probe (a test, or a future composition root
    /// that forgets to wire it) may never make deletion MORE aggressive than today.
    func testDeleteJournalRefusesWhenTheActiveCaptureProbeIsUnattached() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        // No attachActiveCaptureProbe call — the fail-safe default under test.
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA], "fixture sanity")

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "an unattached probe must refuse, never resolve")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    /// A blocker that gains real content between the fixture's own scan and the
    /// `deleteJournal` call must not be destroyed. In THIS codebase the protection is
    /// even earlier and stronger than the on-demand resolution step itself:
    /// `LibraryScanner`'s "holds something to show" rule and `RecoveryPlanner`'s "keep
    /// or quarantine, don't delete" rule key off the same predicate
    /// (`holdsIrreplaceableArtifacts` / raw frame count — see `DirectorySnapshot
    /// .holdsIrreplaceableArtifacts` and `RecoveryPlanner.decide`), so content written
    /// before `deleteJournal` is called is already caught by ITS OWN leading
    /// `rescanUntilFresh`: the fresh scan reclassifies the capture as a real, filed
    /// entry, `emptinessVerdict` reads `.blockedHard` before ever reaching
    /// `.blockedResolvable`, and `resolveWorthlessBlockers` (the method carrying the
    /// planner call) is never invoked at all for THIS fixture — a mutation of
    /// `resolveWorthlessBlockers` that bypasses the planner entirely does NOT break this
    /// test, because that method never runs here. This test still stands on its own
    /// (real, always-active protection, worth pinning), but it is NOT the test that
    /// discriminates `resolveWorthlessBlockers`'s own planner call — see
    /// `testDeleteJournalRefusesWhenABlockerGainsRealContentDuringOnDemandResolution`
    /// immediately below, which uses `beforeResolutionHook` to land content
    /// deterministically INSIDE that method's own window, and IS mutation-verified
    /// against it. Task report has the full investigation of why a same-process
    /// `Task.yield()` race could not do this reliably.
    func testDeleteJournalRefusesWhenABlockerGainsRealContentBetweenScanAndDelete() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { nil }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA],
                       "fixture sanity: worthless as of this scan")

        // Lands on disk WITHOUT a rescan — a finalize (or a sync ingest) landing while
        // the delete confirmation dialog sits open, same shape as the sibling freshness
        // tests above.
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: captureDir(idA)),
            withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)))

        let deleted = await model.deleteJournal("J2")

        XCTAssertFalse(deleted, "the fresh rescan must see the content that just landed — refuse")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path),
                      "the capture directory must survive")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)).path),
            "and its m4a must survive")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    /// Task review fix (Important 1): a deterministic breakpoint hook, matching this
    /// codebase's own precedent (`TransitionBreakpointController`;
    /// `FakeVoiceMarkingStore.holdWrites`/`isHolding`/`releaseHold()`), lands a
    /// competing m4a write INSIDE `resolveWorthlessBlockers`'s own window — between the
    /// verdict `deleteJournal` computed and the fresh per-capture gather that method is
    /// about to act on — rather than racing via `Task.yield()` counts, which the task
    /// report shows cannot reach this specific window in a single-process cooperative
    /// scheduler. `RecoveryPlanner` sees the bare m4a with no manifest, decides
    /// `.quarantineCaptureDirectory` (issue #8's guard, a no-op on disk — an OWNED
    /// decision per `resolveWorthlessBlockers`'s Important-2 fix), and `deleteJournal`'s
    /// own re-verification after resolution then sees this capture as a real, filed
    /// entry and refuses. Mutation check (evidence in the task report): replace the
    /// gather→plan→apply resolution with a direct `removeItem` → this test fails.
    func testDeleteJournalRefusesWhenABlockerGainsRealContentDuringOnDemandResolution() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { nil }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA],
                       "fixture sanity: worthless as of this scan")

        let park = ResolutionPark()
        model.beforeResolutionHook = { await park.hook() }

        async let deleted = model.deleteJournal("J2")
        while !park.isParked { await Task.yield() }

        // Parked between the verdict and this capture's fresh gather — land a real m4a
        // now, deterministically, in the exact window the mutation check below proves
        // is load-bearing.
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: captureDir(idA)),
            withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)))

        park.release()
        let result = await deleted

        XCTAssertFalse(result, "the planner declined to delete — the journal delete must refuse too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path),
                      "the capture directory must survive")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)).path),
            "and its m4a must survive")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    /// Task review fix (Important 2): a planner decision `resolveWorthlessBlockers` does
    /// NOT own (anything beyond delete/quarantine) must leave the capture directory
    /// byte-untouched and refuse, rather than silently applying a partial mutation with
    /// no session-lifetime way to finish it. Real PCM frames with no manifest is the
    /// shape whose decision is `.normalizeToCaptured` — confirmed as a fixture-sanity
    /// check against the real planner before releasing the park, so this test fails
    /// loudly (not silently) if a future change to `RecoveryPlanner` ever changes that.
    func testDeleteJournalRefusesAndLeavesTheDirectoryUntouchedWhenThePlannerDecidesSomethingOutsideTheOwnedSet() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { nil }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA],
                       "fixture sanity: worthless as of this scan")

        let park = ResolutionPark()
        model.beforeResolutionHook = { await park.hook() }

        async let deleted = model.deleteJournal("J2")
        while !park.isParked { await Task.yield() }

        // Real PCM frames, no manifest — the planner's own decision for this shape is
        // `.normalizeToCaptured`, not delete/quarantine: not something this model owns.
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: segsDir, withIntermediateDirectories: true)
        let pcmURL = SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: 0)
        try Data(count: 48_000 * 4).write(to: pcmURL)  // 1.0s of Float32 mono @ 48kHz

        let expectedAction = RecoveryPlanner.plan(
            for: DirectorySnapshot.gather(capturesRoot: capturesRoot, captureID: idA))
        guard case .normalizeToCaptured = expectedAction else {
            park.release()
            _ = await deleted
            return XCTFail("fixture sanity: expected .normalizeToCaptured, got \(expectedAction)")
        }

        park.release()
        let result = await deleted

        XCTAssertFalse(result, "a planner decision outside delete/quarantine must not be "
                       + "applied — refuse")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pcmURL.path),
                      "the raw segment must be byte-untouched — normalizeToCaptured must NOT "
                      + "have been applied")
        XCTAssertEqual((try? Data(contentsOf: pcmURL))?.count, 48_000 * 4,
                       "byte-untouched means byte-untouched, not just present")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.manifestURL(captureDirectory: captureDir(idA)).path),
            "no manifest should have been written")
        XCTAssertNotNil(model.journals.first { $0.id == "J2" })
    }

    /// The UI-facing signal (`JournalEditorView`'s disabled delete row, via
    /// `hasIndeterminateContent`) must NOT hard-block on a blocker the on-demand
    /// resolution inside `deleteJournal` can clear itself — running destructive recovery
    /// machinery from a state READ would be backwards (the brief's own constraint). Only
    /// when the probe says the blocker IS the active capture does the row stay disabled.
    func testUIFacingIndeterminateContentTreatsAnInactiveWorthlessBlockerAsDeletable() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        model.attachActiveCaptureProbe { nil }
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA], "fixture sanity")

        XCTAssertFalse(model.hasIndeterminateContent(forJournal: "J2"),
                       "an inactive worthless blocker enables the row — resolution happens on tap")

        model.attachActiveCaptureProbe { self.idA }
        XCTAssertTrue(model.hasIndeterminateContent(forJournal: "J2"),
                      "the active capture keeps the row disabled")
    }

    /// Fail-safe default at the VERDICT level, not just `deleteJournal`'s own redundant
    /// re-check inside `resolveWorthlessBlockers`: an unattached probe must read as
    /// `.blockedHard` (row disabled) directly through `emptinessVerdict`, never as
    /// `.blockedResolvable`. Without this specific pin, `deleteJournal`'s own defensive
    /// re-check inside `resolveWorthlessBlockers` was catching an unattached probe on
    /// its own, and a mutation of `emptinessVerdict`'s fail-safe branch alone passed
    /// every other test in this file undetected — this is the test that catches it.
    func testUIFacingIndeterminateContentTreatsAnUnattachedProbeAsHardBlocked() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Armed into, nothing recorded yet")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J2"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        // No attachActiveCaptureProbe call — the fail-safe default under test.
        await model.rescan()
        XCTAssertEqual(model.skipped.map(\.captureID), [idA], "fixture sanity")

        XCTAssertTrue(model.hasIndeterminateContent(forJournal: "J2"),
                      "an unattached probe is unknown, not safe — the row must stay disabled")
        XCTAssertEqual(model.emptinessVerdict(forJournal: "J2"), .blockedHard)
    }

    /// The other side of the same rule, so it is a rule and not a blanket refusal: a
    /// skipped capture filed into a DIFFERENT journal does not block this one, and neither
    /// does one whose sidecar is unreadable (it names no journal AND holds nothing durable
    /// — which is exactly why it was skipped, so there is nothing there to orphan).
    func testASkippedCaptureBlocksOnlyTheJournalItNames() async throws {
        try writeJournals([journal("J1", "Holds the skipped capture"), journal("J2", "Empty")])
        try FileManager.default.createDirectory(at: captureDir(idA), withIntermediateDirectories: true)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J1"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))
        try FileManager.default.createDirectory(at: captureDir(idB), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB)))

        let model = model()
        await model.rescan()
        XCTAssertEqual(Set(model.skipped.map(\.captureID)), [idA, idB], "fixture sanity")

        XCTAssertTrue(model.isJournalEmpty("J2"))
        XCTAssertFalse(model.isJournalEmpty("J1"))
    }

    // MARK: - isJournalEmptyAfterRescan (#80, B2 — the sync-ingest seam)

    /// The exact seam `SyncRecordExchange`'s inbound-deletion guard calls off-MainActor
    /// (R3/B2): rescan-then-check as ONE method, so nothing can land between the two the
    /// way it could if a caller split them across two separate awaits into this actor.
    /// Same freshness shape as `deleteJournal`'s own rescan-first pin above, exercised
    /// through the public seam sync actually uses instead of `deleteJournal` itself.
    func testIsJournalEmptyAfterRescanSeesAnEntryThatArrivedAfterTheLastScan() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty as of the last scan")])

        let model = model()
        await model.rescan()
        XCTAssertTrue(model.isJournalEmpty("J2"), "fixture sanity: empty as of this scan")

        // Lands on disk WITHOUT a rescan, exactly like the sibling pin above.
        try writeCapture(idA, capturedAt: 1_000, journalID: "J2")
        XCTAssertFalse(model.allEntries.contains { $0.captureID == idA },
                      "fixture sanity: the cached scan predates this entry")

        let stillEmpty = await model.isJournalEmptyAfterRescan("J2")

        XCTAssertFalse(stillEmpty, "the method's own rescan must see the entry that just arrived")
        XCTAssertTrue(model.allEntries.contains { $0.captureID == idA },
                     "isJournalEmptyAfterRescan must actually have rescanned, not just read the cache")
    }

    func testIsJournalEmptyAfterRescanIsTrueForAGenuinelyEmptyJournal() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Empty")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")

        let model = model()
        // Deliberately no `rescan()` here — the method must do its own.
        let empty = await model.isJournalEmptyAfterRescan("J2")

        XCTAssertTrue(empty)
    }

    // MARK: - T6c: promoteIfNeeded / transcript(for:) ordering (review finding 3)

    /// `EntryDetailView.refresh()` now reads `transcript(for:)` FIRST, and only
    /// re-reads after a `.promoted` outcome — never awaits promotion before the first
    /// read, so an entry opened during the launch corpus walk isn't blocked behind it.
    /// This pins the same sequence at the model layer: a read before promotion must
    /// already return real (live.jsonl) text, and `promoteIfNeeded` must report
    /// `.promoted` so the caller knows to re-read for the canonical text.
    func testTranscriptReadBeforePromotionAlreadyShowsLiveJSONLTextAndPromotionIsSeparatelyObservable() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)))
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(seq: 0, text: "hello there",
                                           captureFrameStart: 0, captureFrameEnd: 20_000,
                                           generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()

        let model = model()

        // Before promotion: the entry-open read must not block on it, and must already
        // show real text off live.jsonl.
        let before = await model.transcript(for: idA)
        XCTAssertEqual(before.text, "hello there")

        let outcome = await model.promoteIfNeeded(idA)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        // After: a caller that re-reads on `.promoted` sees the canonical text (display-
        // identical here, but this is the seam `EntryDetailView.refresh()` now uses).
        let after = await model.transcript(for: idA)
        XCTAssertEqual(after.text, "hello there")
    }

    // MARK: - T7 prereq #41: closeStaleDraftIfNeeded / transcript(for:) ordering

    /// `EntryDetailView.refresh()` calls `model.recoverStaleDraftBeforeRead(captureID)`
    /// BEFORE its transcript read (:92-98) — a recovered edit must be visible in the
    /// very first read the screen shows, not on the next scan. Pins the same sequence at
    /// the model layer the T6c test above uses, since the View itself isn't
    /// unit-testable.
    func testStaleDraftRecoveredBeforeTranscriptReadShowsTheRecoveredEditImmediately() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        try await model.revisionStore.append(
            TranscriptRevision(id: "01R0000000000000000000000A", source: .machineLive,
                               createdAt: Date(timeIntervalSince1970: 1_000),
                               spans: [TranscriptSpan(text: "original machine text", anchor: .none)]),
            captureID: idA)
        // Ancient lastWriteAt — unambiguously stale under whatever real `Date()` the
        // model call below uses internally, no injected clock required.
        try await model.revisionStore.writeDraft(captureID: idA, text: "recovered edited text",
                                                  now: Date(timeIntervalSince1970: 0))

        // The exact sequence EntryDetailView.refresh() must follow: recover, THEN read.
        await model.recoverStaleDraftBeforeRead(idA)
        let transcript = await model.transcript(for: idA)

        XCTAssertEqual(transcript.text, "recovered edited text",
                       "a stale draft closed before the transcript read must be visible in that read")
    }

    /// Fix round 1, Important 1 (probe-confirmed by review): entry-open used to close
    /// the stale draft BEFORE promoting, so the `.userEdit` the close minted was itself
    /// the canonical file that trips `promoteIfNeeded`'s "any canonical file present"
    /// skip (`TranscriptRevisionStore.swift` promotion skip order, rule 3) — the
    /// `.machineLive` baseline could never enter the chain, permanently, since the skip
    /// is unconditional. `recoverStaleDraftBeforeRead` must promote FIRST.
    func testEntryOpenPromotesBeforeClosingAStaleDraftSoTheMachineBaselineIsNeverBlocked() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)))
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(seq: 0, text: "machine baseline",
                                           captureFrameStart: 0, captureFrameEnd: 20_000,
                                           generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()

        let model = model()
        // A stale draft, with NO canonical revisions on disk yet — the exact fixture
        // the review probed with.
        try await model.revisionStore.writeDraft(captureID: idA, text: "recovered edit",
                                                  now: Date(timeIntervalSince1970: 0))

        await model.recoverStaleDraftBeforeRead(idA)

        let load = TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA))
        let sources = TranscriptChain.ordered(load?.revisions ?? []).map(\.source)
        XCTAssertEqual(sources, [.machineLive, .userEdit],
                       "promotion must mint the machine baseline BEFORE the stale draft is closed on top of it")
    }

    /// Fix round 1, Important 2 (probe-confirmed by review): a draft-free capture — the
    /// overwhelmingly common case — must take the nonisolated `hasDraft` fast path and do
    /// NO store-actor work at all, so entry-open never queues behind an in-flight
    /// launch-time corpus walk holding the revision-store actor (the exact regression the
    /// T6c comment at `EntryDetailView.swift:99-104` already warns about for
    /// `promoteIfNeeded`).
    ///
    /// **Gate B Important 2 — this test used to assert a tautology.** It checked only the
    /// returned Bool, which IS `hasDraft`'s own answer, so it re-asserted its fixture:
    /// moving `promoteIfNeeded` ABOVE the guard (reintroducing exactly the first-paint
    /// regression this exists to prevent) left it green. The observable now is the
    /// promotion's SIDE EFFECT — the fixture is a promotable capture with a `live.jsonl`
    /// and nothing promoted, so any hop onto the store actor here mints the `.machineLive`
    /// baseline and leaves a canonical chain behind. Not hopping is the only way the chain
    /// stays absent. Timing is deliberately NOT the observable: that would be a flake, and
    /// the store call either happened or it didn't.
    func testEntryOpenWithNoDraftDoesNoStoreActorWorkAtAll() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(idA)))
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(seq: 0, text: "machine baseline",
                                           captureFrameStart: 0, captureFrameEnd: 20_000,
                                           generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()
        let model = model()

        // Precondition: promotion WOULD have done something visible had it run — without
        // this the assertion below would hold for a capture with nothing to promote.
        XCTAssertEqual(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA))?
            .revisions.count ?? 0, 0, "precondition: nothing promoted yet")

        let hoppedTheActor = await model.recoverStaleDraftBeforeRead(idA)

        XCTAssertFalse(hoppedTheActor, "a draft-free capture must take the nonisolated fast path")
        XCTAssertEqual(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA))?
            .revisions.count ?? 0, 0,
                       "no store-actor work may run on the draft-free path — a minted revision "
                       + "here means the actor was hopped before the guard")

        // The other half of the same rule: the fast path must not be skipping work the
        // DRAFT path owes. The same capture, once it has a draft, does promote.
        try await model.revisionStore.writeDraft(captureID: idA, text: "an edit",
                                                 now: Date(timeIntervalSince1970: 0))
        let hoppedWithADraft = await model.recoverStaleDraftBeforeRead(idA)

        XCTAssertTrue(hoppedWithADraft)
        XCTAssertEqual(TranscriptRevisionStore.loadChain(captureDirectory: captureDir(idA))?
            .revisions.map(\.source), [.machineLive, .userEdit],
                       "the draft path does pay the actor cost: it promotes, then closes the draft")
    }
}

/// Test-only park/release helper for `LibraryScreenModel.beforeResolutionHook` (#82 task
/// review fix). Same shape as `FakeVoiceMarkingStore.holdWrites`/`isHolding`/
/// `releaseHold()` (`VoiceMarkingModelTests.swift`) and
/// `TransitionBreakpointController.arm`/`gate`/`disarm` (`TransitionBreakpointsTests.swift`)
/// — this codebase's established precedent for deterministically parking a production
/// call mid-flight rather than racing it via `Task.yield()` counts. `isParked` is the
/// observable a test polls with a plain `while !park.isParked { await Task.yield() }`
/// loop (same idiom `VoiceMarkingModelTests` uses for `isHolding`) before acting and
/// calling `release()`.
@MainActor
private final class ResolutionPark {
    private(set) var isParked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hook() async {
        isParked = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        isParked = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
