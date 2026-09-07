import XCTest
import CryptoKit
@testable import Raconte

/// T11: `ArchiveExporter.export(into:)` writes the package `ArchiveWalker` (T10) lists.
///
/// Fixture helpers copied from `ArchiveWalkerTests`/`SyncTreeScannerTests` (do not
/// import across test files) — a two-capture archive: one with audio, two revisions,
/// own+foreign markers, a live log, an entry log and one image; one with no final audio
/// and a garbage `entry.json`. Plus one journal with a cover.
/// A thread-safe `now()` stub for Fix wave Finding 4's test — needs to hand out a
/// DIFFERENT date on a second call so a bug that calls `now()` twice (directory stamp,
/// then `exportedAt`) is observable as a mismatch, while a `@Sendable` closure capturing
/// mutable state satisfies Swift 6 strict concurrency.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let dates: [Date]

    init(dates: [Date]) { self.dates = dates }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        let date = dates[min(callCount, dates.count - 1)]
        callCount += 1
        return date
    }
}

final class ArchiveExporterTests: XCTestCase {

    private var containerRoot: URL!
    private var destinationRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)
    private let fixedNow = Date(timeIntervalSince1970: 1_788_737_400) // 2026-09-06T23:30:00Z

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        containerRoot = base.appendingPathComponent("RaconteArchiveExporter-container-\(UUID().uuidString)",
                                                     isDirectory: true)
        destinationRoot = base.appendingPathComponent("RaconteArchiveExporter-dest-\(UUID().uuidString)",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
        try? FileManager.default.removeItem(at: destinationRoot)
    }

    // MARK: Fixture helpers (shape copied from ArchiveWalkerTests)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    @discardableResult
    private func writeManifest(_ id: String, verifiedAt: Date?,
                               createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Data {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        var m = Manifest(captureID: id, createdAt: createdAt, state: verifiedAt == nil ? .captured : .complete,
                         stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        m.final = FinalRef(path: "final/recording.m4a", verifiedAt: verifiedAt, durationFrames: 48_000)
        let data = try CaptureCoding.encoder().encode(m)
        try data.write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
        return data
    }

    private func writeEntryMetadata(_ metadata: EntryMetadata, id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try EntryMetadataStore.encode(metadata)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeGarbageEntryMetadata(id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data("not valid entry metadata json".utf8)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    @discardableResult
    private func writeFinalM4A(_ id: String, bytes: Data = Data(repeating: 0xAB, count: 4096)) throws -> Data {
        let dir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
        return bytes
    }

    private func transcriptDir(_ id: String) -> URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDir(id))
    }

    private func writeLiveLog(_ id: String, bytes: Data = Data("live-log-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDir(id)))
    }

    private func writeOwnMarkers(_ id: String, bytes: Data = Data("own-marker-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.markerLogURL(captureDirectory: captureDir(id)))
    }

    private func writeForeignMarkers(_ id: String, foreignDeviceID: String,
                                     bytes: Data = Data("foreign-marker-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: transcriptDir(id), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDir(id),
                                                              deviceID: foreignDeviceID))
    }

    private func revisionFixture(id: String, text: String,
                                 createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TranscriptRevision {
        TranscriptRevision(id: id, source: .machineLive, createdAt: createdAt,
                           spans: [TranscriptSpan(text: text, anchor: .none)])
    }

    @discardableResult
    private func writeCanonicalRevision(_ captureID: String, revisionNumber: Int,
                                        _ revision: TranscriptRevision) throws -> Data {
        try FileManager.default.createDirectory(at: transcriptDir(captureID), withIntermediateDirectories: true)
        let data = try CaptureCoding.encoder().encode(revision)
        try data.write(to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDir(captureID),
                                                                 revision: revisionNumber))
        return data
    }

    private func writeEntryLog(_ captureID: String, bytes: Data = Data("entry-log-bytes".utf8)) throws {
        try FileManager.default.createDirectory(at: captureDir(captureID), withIntermediateDirectories: true)
        try bytes.write(to: SegmentLayout.entryLogURL(captureDirectory: captureDir(captureID)))
    }

    private func writeImage(_ captureID: String, imageID: String) throws {
        let dir = captureDir(captureID)
        try FileManager.default.createDirectory(at: SegmentLayout.imagesDirectory(captureDirectory: dir),
                                                 withIntermediateDirectories: true)
        try Data("image-original-bytes".utf8)
            .write(to: SegmentLayout.imageOriginalURL(captureDirectory: dir, imageID: imageID, ext: "jpg"))
        try Data("{}".utf8)
            .write(to: SegmentLayout.imageSidecarURL(captureDirectory: dir, imageID: imageID))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    private func writeCover(journalID: String, bytes: Data) throws {
        let url = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: journalID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    // MARK: The fixture

    private struct Fixture {
        var idAudio: String
        var idNoAudio: String
        var revision0: TranscriptRevision
        var revision1: TranscriptRevision
        var journal: Journal
    }

    @discardableResult
    private func buildFixture() throws -> Fixture {
        let idAudio = ULID.make()
        let idNoAudio = ULID.make()
        let imageID = ULID.make()
        let foreignDeviceID = ULID.make()
        let journal = Journal(id: ULID.make(), name: "1987 Journal",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_002))

        let revision0 = revisionFixture(id: ULID.make(), text: "first",
                                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let revision1 = revisionFixture(id: ULID.make(), text: "second",
                                        createdAt: Date(timeIntervalSince1970: 1_700_000_010))

        try writeManifest(idAudio, verifiedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try writeFinalM4A(idAudio)
        try writeEntryMetadata(EntryMetadata(journalID: journal.id,
                                            originalDate: try PartialDate(parsing: "1998-03-04")),
                              id: idAudio)
        try writeCanonicalRevision(idAudio, revisionNumber: 0, revision0)
        try writeCanonicalRevision(idAudio, revisionNumber: 1, revision1)
        try writeOwnMarkers(idAudio)
        try writeForeignMarkers(idAudio, foreignDeviceID: foreignDeviceID)
        try writeLiveLog(idAudio)
        try writeEntryLog(idAudio)
        try writeImage(idAudio, imageID: imageID)

        try writeManifest(idNoAudio, verifiedAt: nil)
        try writeGarbageEntryMetadata(id: idNoAudio)

        try writeJournals([journal])
        try writeCover(journalID: journal.id, bytes: Data(repeating: 0x42, count: 8))

        return Fixture(idAudio: idAudio, idNoAudio: idNoAudio,
                       revision0: revision0, revision1: revision1, journal: journal)
    }

    private func exporter() -> ArchiveExporter {
        let fixedNow = self.fixedNow
        return ArchiveExporter(containerRoot: containerRoot, appVersion: "9.9", build: "test-build",
                               now: { fixedNow })
    }

    // MARK: (a) every ExportFile exists in the package with identical bytes

    func testEveryWalkerFileLandsInThePackageWithIdenticalBytes() async throws {
        try buildFixture()
        let listing = try ArchiveWalker.list(containerRoot: containerRoot)

        let report = try await exporter().export(into: destinationRoot)

        for file in listing.files {
            let packagedURL = report.packageURL.appendingPathComponent(file.relativePath)
            let sourceData = try Data(contentsOf: file.source)
            let packagedData = try Data(contentsOf: packagedURL)
            XCTAssertEqual(sourceData, packagedData, "byte mismatch for \(file.relativePath)")
        }
    }

    // MARK: (b) manifest decodes; files has one key per package file except itself;
    // every sha256 equals a locally recomputed CryptoKit digest.

    func testManifestListsEveryPackageFileWithACorrectSha256() async throws {
        try buildFixture()
        let report = try await exporter().export(into: destinationRoot)

        let manifestURL = report.packageURL.appendingPathComponent("raconte-export.json")
        let manifest = try CaptureCoding.decoder().decode(ExportManifest.self,
                                                          from: try Data(contentsOf: manifestURL))

        let allFilesOnDisk = try packageFileRelativePaths(under: report.packageURL)
        let expectedKeys = Set(allFilesOnDisk.filter { $0 != "raconte-export.json" })
        XCTAssertEqual(Set(manifest.files.keys), expectedKeys)

        for (relativePath, digest) in manifest.files {
            let data = try Data(contentsOf: report.packageURL.appendingPathComponent(relativePath))
            let recomputed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest.sha256, recomputed, "sha256 mismatch for \(relativePath)")
            XCTAssertEqual(digest.bytes, data.count)
        }
    }

    private func packageFileRelativePaths(under root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            paths.insert(relative)
        }
        return paths
    }

    // MARK: (c) transcript.md body equals TranscriptChain.plainText(current) for the
    // two-revision capture.

    func testTranscriptMarkdownBodyMatchesCurrentRevisionsPlainText() async throws {
        let fixture = try buildFixture()
        let report = try await exporter().export(into: destinationRoot)

        let transcriptURL = report.packageURL
            .appendingPathComponent("entries/\(fixture.idAudio)/transcript.md")
        let document = try String(contentsOf: transcriptURL, encoding: .utf8)

        let ordered = TranscriptChain.ordered([fixture.revision0, fixture.revision1])
        let expected = TranscriptChain.plainText(TranscriptChain.current(ordered)!)

        XCTAssertEqual(TranscriptMarkdown.body(of: document), expected)
        XCTAssertTrue(document.contains("journalID: \(fixture.journal.id)"))
        XCTAssertTrue(document.contains("originalDate: 1998-03-04"))
    }

    // MARK: (d) counts.entries == 2; hasAudio/sidecarReadable false for the garbage sidecar

    func testCountsAndEntrySummaryReflectTheGarbageSidecarCapture() async throws {
        let fixture = try buildFixture()
        let report = try await exporter().export(into: destinationRoot)

        XCTAssertEqual(report.counts.entries, 2)
        XCTAssertEqual(report.counts.journals, 1)

        let manifestURL = report.packageURL.appendingPathComponent("raconte-export.json")
        let manifest = try CaptureCoding.decoder().decode(ExportManifest.self,
                                                          from: try Data(contentsOf: manifestURL))

        let noAudioSummary = try XCTUnwrap(manifest.entries[fixture.idNoAudio])
        XCTAssertFalse(noAudioSummary.hasAudio)
        XCTAssertFalse(noAudioSummary.sidecarReadable)

        let audioSummary = try XCTUnwrap(manifest.entries[fixture.idAudio])
        XCTAssertTrue(audioSummary.hasAudio)
        XCTAssertTrue(audioSummary.sidecarReadable)
        XCTAssertEqual(audioSummary.revisionCount, 2)
        XCTAssertEqual(audioSummary.journalID, fixture.journal.id)
    }

    // MARK: (e) no .part directory remains

    func testNoPartDirectoryRemainsAfterASuccessfulExport() async throws {
        try buildFixture()
        let report = try await exporter().export(into: destinationRoot)

        let contents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".part") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.packageURL.path))
    }

    // MARK: (f) an unwritable destination throws and leaves nothing behind

    func testUnwritableDestinationThrowsAndLeavesNothingBehind() async throws {
        try buildFixture()
        // A plain FILE where the exporter expects to create directories underneath.
        let fileDestination = destinationRoot.appendingPathComponent("not-a-directory")
        try Data("i am a file, not a directory".utf8).write(to: fileDestination)

        do {
            _ = try await exporter().export(into: fileDestination)
            XCTFail("expected export(into:) to throw")
        } catch {
            // expected
        }

        // Nothing besides the pre-existing plain file exists at that path, and no
        // `.part`/final package sits anywhere under destinationRoot.
        let contents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        XCTAssertEqual(contents, ["not-a-directory"])
    }

    // MARK: (g) the stamp uses the injected clock

    func testPackageDirectoryNameUsesTheInjectedClockAsAUTCStamp() async throws {
        try buildFixture()
        let report = try await exporter().export(into: destinationRoot)

        XCTAssertEqual(report.packageURL.lastPathComponent, "Raconte-export-20260906-233000")
    }

    // MARK: (h) Fix wave Finding 4 — `now()` is hoisted to ONE call, used for both the
    // directory stamp and `manifest.exportedAt`. A stub that returns a DIFFERENT date on
    // its second call catches a regression: two calls would stamp the directory from the
    // FIRST date but the manifest from the SECOND, an inconsistency this asserts against
    // directly (call count) rather than merely hoping the two happen to agree.

    func testDirectoryStampAndManifestExportedAtComeFromTheSameSingleNowCall() async throws {
        try buildFixture()
        let counter = CallCounter(dates: [fixedNow, fixedNow.addingTimeInterval(3600)])
        let exporter = ArchiveExporter(containerRoot: containerRoot, appVersion: "9.9", build: "test-build",
                                       now: { counter.next() })

        let report = try await exporter.export(into: destinationRoot)

        XCTAssertEqual(counter.count, 1, "now() must be called exactly once per export")
        XCTAssertEqual(report.packageURL.lastPathComponent, "Raconte-export-20260906-233000")

        let manifestURL = report.packageURL.appendingPathComponent("raconte-export.json")
        let manifest = try CaptureCoding.decoder().decode(ExportManifest.self,
                                                          from: try Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.exportedAt, fixedNow)
    }

    // MARK: (i) Fix wave Finding 5 — a stale `.part` staging directory left behind by a
    // prior aborted export (a kill mid-write, never cleaned by the exporter's own
    // catch-and-remove since that only runs for a throw IT catches) is cleared before
    // staging fresh, so nothing it held rides along into the finished package.

    func testStalePartDirectoryIsClearedBeforeExport() async throws {
        try buildFixture()
        let stalePart = destinationRoot.appendingPathComponent("Raconte-export-20260906-233000.part",
                                                               isDirectory: true)
        try FileManager.default.createDirectory(at: stalePart, withIntermediateDirectories: true)
        try Data("leftover-from-a-crashed-export".utf8).write(to: stalePart.appendingPathComponent("junk.txt"))

        let report = try await exporter().export(into: destinationRoot)

        let packageContents = try FileManager.default.contentsOfDirectory(atPath: report.packageURL.path)
        XCTAssertFalse(packageContents.contains("junk.txt"))
    }

    // MARK: (j) Fix wave Finding 9 — `ExportRunner.cancelled()` returns to `.idle`
    // regardless of what state it was in, so `AboutView`'s `.fileImporter` routing a
    // `CocoaError.userCancelled` failure there (instead of `fail(_:)`) never leaves the
    // screen showing an "Export failed" row for the owner simply dismissing the picker.

    @MainActor
    func testExportRunnerCancelledReturnsToIdle() {
        let runner = ExportRunner(exporter: exporter())
        runner.fail("simulated failure")
        XCTAssertEqual(runner.state, .failed("simulated failure"))

        runner.cancelled()

        XCTAssertEqual(runner.state, .idle)
    }
}
