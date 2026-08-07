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

    func testRescanPopulatesItemsJournalsAndRecent() async throws {
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

    /// `recent` is capture-time order across *every* journal, not a slice of the filtered
    /// list — the capture screen's "what I just recorded" must not follow the library's
    /// filter or a backdate.
    func testRecentIsCaptureOrderedAcrossAllJournalsAndCappedAtThree() async throws {
        try writeJournals([journal("J1", "1987")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)

        let model = model()
        model.journalScope = .journal("J1")
        await model.rescan()

        XCTAssertEqual(model.items.map(\.captureID), [idA], "the list follows the filter")
        XCTAssertEqual(model.recent.map(\.captureID), [idC, idB, idA],
                       "recent does not")
    }

    func testRecentIsCappedAtThree() async throws {
        for (index, id) in [idA, idB, idC].enumerated() {
            try writeCapture(id, capturedAt: Double(1_000 * (index + 1)))
        }
        try writeCapture("01DDDDDDDDDDDDDDDDDDDDDDDD", capturedAt: 4_000)
        let model = model()
        await model.rescan()
        XCTAssertEqual(model.items.count, 4)
        XCTAssertEqual(model.recent.count, 3)
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
}
