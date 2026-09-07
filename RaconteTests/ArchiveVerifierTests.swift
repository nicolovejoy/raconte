import XCTest
@testable import Raconte

/// T12: `ArchiveVerifier.verify(packageURL:)` proves a package `ArchiveExporter` (T11)
/// wrote back against its own manifest and its own `revisions/` files — never the
/// source container, which may not even exist anymore by the time someone reads a
/// package back off a USB stick.
///
/// Fixture helpers copied from `ArchiveExporterTests` (do not import across test
/// files) — the same two-capture archive: one with audio and two revisions, one with
/// no final audio and a garbage `entry.json`. Every test here builds a fresh package
/// with the real exporter, then mutates the PACKAGE (never the source container)
/// before calling `verify`.
final class ArchiveVerifierTests: XCTestCase {

    private var containerRoot: URL!
    private var destinationRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)
    private let fixedNow = Date(timeIntervalSince1970: 1_788_737_400) // 2026-09-06T23:30:00Z

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        containerRoot = base.appendingPathComponent("RaconteArchiveVerifier-container-\(UUID().uuidString)",
                                                     isDirectory: true)
        destinationRoot = base.appendingPathComponent("RaconteArchiveVerifier-dest-\(UUID().uuidString)",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
        try? FileManager.default.removeItem(at: destinationRoot)
    }

    // MARK: Fixture helpers (shape copied from ArchiveExporterTests)

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

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    // MARK: The fixture — one capture with audio + two revisions, one without audio
    // and a garbage sidecar. Simpler than `ArchiveExporterTests`' fixture (no markers/
    // live log/images/covers): the verifier's job doesn't depend on any of those, and
    // the tests below only need file presence, checksum, transcript, and count checks.

    private struct Fixture {
        var idAudio: String
        var idNoAudio: String
        var revision0: TranscriptRevision
        var revision1: TranscriptRevision
    }

    @discardableResult
    private func buildFixture() throws -> Fixture {
        let idAudio = ULID.make()
        let idNoAudio = ULID.make()
        let journal = Journal(id: ULID.make(), name: "1987 Journal",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_002))

        // Revision0 ("first") is the OLDER, non-tip revision; revision1 ("second") is
        // current (no human tip ⇒ current is the latest by (createdAt, id)). Deleting
        // revision0's file must not change `current`'s text — that is exactly what
        // isolates `.missingFile` from `.transcriptMismatch` in the tests below.
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

        try writeManifest(idNoAudio, verifiedAt: nil)
        try writeGarbageEntryMetadata(id: idNoAudio)

        try writeJournals([journal])

        return Fixture(idAudio: idAudio, idNoAudio: idNoAudio, revision0: revision0, revision1: revision1)
    }

    private func exportPackage() async throws -> (packageURL: URL, fixture: Fixture) {
        let fixture = try buildFixture()
        let fixedNow = self.fixedNow
        let exporter = ArchiveExporter(containerRoot: containerRoot, appVersion: "9.9", build: "test-build",
                                       now: { fixedNow })
        let report = try await exporter.export(into: destinationRoot)
        return (report.packageURL, fixture)
    }

    private func readManifest(at packageURL: URL) throws -> ExportManifest {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("raconte-export.json"))
        return try CaptureCoding.decoder().decode(ExportManifest.self, from: data)
    }

    // MARK: (1) clean package verifies ok, checkedFiles == manifest.files.count

    func testCleanPackageVerifiesOK() async throws {
        let (packageURL, _) = try await exportPackage()
        let manifest = try readManifest(at: packageURL)

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.checkedFiles, manifest.files.count)
    }

    // MARK: (2) a flipped byte in audio.m4a is the ONLY problem, and it's a checksumMismatch

    func testFlippedByteInAudioProducesOnlyAChecksumMismatch() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let relativePath = "entries/\(fixture.idAudio)/audio.m4a"
        let url = packageURL.appendingPathComponent(relativePath)
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xFF
        try bytes.write(to: url)

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertEqual(report.problems, [.checksumMismatch(relativePath)])
    }

    // MARK: (3) deleting the OLDER (non-tip) revision file is the ONLY problem, a missingFile

    func testDeletedNonTipRevisionFileProducesOnlyAMissingFile() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let relativePath = "entries/\(fixture.idAudio)/revisions/canonical-0.json"
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent(relativePath))

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertEqual(report.problems, [.missingFile(relativePath)])
    }

    // MARK: (4) an untracked extra file is the ONLY problem, an unlistedFile

    func testAddedExtraFileProducesOnlyAnUnlistedFile() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let relativePath = "entries/\(fixture.idAudio)/extra.txt"
        try Data("surprise".utf8).write(to: packageURL.appendingPathComponent(relativePath))

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertEqual(report.problems, [.unlistedFile(relativePath)])
    }

    // MARK: (5) editing transcript.md's body produces BOTH a checksumMismatch and a
    // transcriptMismatch, files first

    func testEditedTranscriptBodyProducesChecksumMismatchThenTranscriptMismatch() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let relativePath = "entries/\(fixture.idAudio)/transcript.md"
        let url = packageURL.appendingPathComponent(relativePath)
        let original = try String(contentsOf: url, encoding: .utf8)
        try (original + "\ntampered").write(to: url, atomically: true, encoding: .utf8)

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertEqual(report.problems, [
            .checksumMismatch(relativePath),
            .transcriptMismatch(captureID: fixture.idAudio),
        ])
    }

    // MARK: (6) a truncated manifest produces ONLY manifestUnreadable

    func testTruncatedManifestProducesOnlyManifestUnreadable() async throws {
        let (packageURL, _) = try await exportPackage()
        let manifestURL = packageURL.appendingPathComponent("raconte-export.json")
        let original = try Data(contentsOf: manifestURL)
        let truncated = Data(original.prefix(original.count / 2))
        try truncated.write(to: manifestURL)

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        XCTAssertEqual(report.problems.count, 1)
        let problem = try XCTUnwrap(report.problems.first)
        guard case .manifestUnreadable = problem else {
            return XCTFail("expected .manifestUnreadable, got \(problem)")
        }
        XCTAssertEqual(report.checkedFiles, 0)
    }

    // MARK: (7) deleting a whole entry directory produces a missingFile per file it
    // held, plus a countMismatch on "entries"

    func testDeletedEntryDirectoryProducesMissingFilesAndCountMismatch() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let manifest = try readManifest(at: packageURL)
        let prefix = "entries/\(fixture.idNoAudio)/"
        let filesUnderDeletedEntry = manifest.files.keys.filter { $0.hasPrefix(prefix) }.sorted()
        XCTAssertFalse(filesUnderDeletedEntry.isEmpty, "fixture sanity: idNoAudio must own package files")

        try FileManager.default.removeItem(
            at: packageURL.appendingPathComponent("entries/\(fixture.idNoAudio)", isDirectory: true))

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        let expected = filesUnderDeletedEntry.map { Problem.missingFile($0) }
            + [Problem.countMismatch(field: "entries", manifest: manifest.counts.entries,
                                     found: manifest.counts.entries - 1)]
        XCTAssertEqual(report.problems, expected)
    }

    // MARK: (8) Fix wave Finding 1 — a duplicate-id revision file at a HIGHER file
    // number must not override the true current revision, matching
    // `TranscriptRevisionStore.rawLoad`'s C1 rule (the lowest file number claiming an
    // id wins; a later file sharing that id is dropped from the chain).
    //
    // A byte-for-byte copy of an existing revision file can never demonstrate this: the
    // total order is `(createdAt, id)`, so two files sharing both fields are literally
    // indistinguishable to `TranscriptChain.ordered`/`.current` — whichever one "wins"
    // the tie has identical content either way. The actual failure mode the C1 rule
    // guards against is the "hand-corrupted tree" case its own doc comment names: a
    // LATER file reusing an EARLIER revision's id but carrying different (corrupted)
    // content. Old code (no dedupe, and `names.sorted()` — lexicographic, not numeric)
    // decodes that as a second, distinct chain entry that legitimately outraces the
    // real current revision by `createdAt`, producing a false `.transcriptMismatch`
    // against a package the exporter wrote correctly.
    func testDuplicateIDAtHigherFileNumberWithLaterCreatedAtDoesNotOverrideCurrent() async throws {
        let (packageURL, fixture) = try await exportPackage()
        let revisionsDir = packageURL.appendingPathComponent("entries/\(fixture.idAudio)/revisions")

        let corrupted = TranscriptRevision(
            id: fixture.revision1.id, // same id as the TRUE current revision (canonical-1)
            source: .machineLive,
            createdAt: Date(timeIntervalSince1970: 1_700_000_020), // later than revision1's
            spans: [TranscriptSpan(text: "corrupted", anchor: .none)])
        let data = try CaptureCoding.encoder().encode(corrupted)
        try data.write(to: revisionsDir.appendingPathComponent("canonical-3.json"))

        let report = ArchiveVerifier.verify(packageURL: packageURL)

        // The manifest never knew about canonical-3.json, so it's rightly `.unlistedFile`
        // — the point under test is that it is the ONLY problem: no `.transcriptMismatch`.
        XCTAssertEqual(report.problems, [
            .unlistedFile("entries/\(fixture.idAudio)/revisions/canonical-3.json"),
        ])
    }
}

private typealias Problem = ArchiveVerifier.Problem
