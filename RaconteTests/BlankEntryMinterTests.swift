import XCTest
@testable import Raconte

/// Image capture plan Task 3 (pure half): `BlankEntryMinter.manifest(captureID:
/// createdAt:)` produces a manifest that `FinalizeArtifactPush.isFinalized` reads as
/// `true` once written to disk — an actual round-trip through `CaptureCoding`, since
/// `isFinalized` re-decodes from bytes rather than comparing structs.
final class BlankEntryMinterTests: XCTestCase {

    private var capturesRoot: URL!
    private let captureID = "01BLANKENTRYMINTERTEST0001"

    override func setUpWithError() throws {
        capturesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlankEntryMinter-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    func testManifestShape() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = BlankEntryMinter.manifest(captureID: captureID, createdAt: createdAt)

        XCTAssertEqual(manifest.captureID, captureID)
        XCTAssertEqual(manifest.state, .complete)
        XCTAssertEqual(manifest.final.verifiedAt, createdAt)
        XCTAssertEqual(manifest.final.durationFrames, 0)
    }

    /// The real predicate `FinalizeArtifactPush.push` gates on — a round-trip through
    /// disk + `CaptureCoding`, not a struct comparison, per the brief.
    func testWrittenManifestReadsAsFinalized() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = BlankEntryMinter.manifest(captureID: captureID, createdAt: createdAt)
        let data = try CaptureCoding.encoder().encode(manifest)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: captureDirectory), writing: data)

        XCTAssertTrue(FinalizeArtifactPush.isFinalized(capturesRoot: capturesRoot, captureID: captureID))
    }

    func testCreateWritesManifestAndReturnsCaptureID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlankEntryMinterCreate-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let id = try XCTUnwrap(BlankEntryMinter.create(capturesRoot: root, journalID: nil, captureID: "01CREATEDBLANK000000000001"))
        XCTAssertEqual(id, "01CREATEDBLANK000000000001")
        XCTAssertTrue(FinalizeArtifactPush.isFinalized(capturesRoot: root, captureID: id))
        // No journalID given → no entry.json written.
        let entryURL = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: root, captureID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryURL.path))
    }

    func testCreateWithJournalIDWritesEntryMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlankEntryMinterCreateJ-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let id = try XCTUnwrap(BlankEntryMinter.create(capturesRoot: root, journalID: "j1",
                                                        captureID: "01CREATEDBLANKJ00000000001"))
        let metadata = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(
                captureDirectory: SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)))
        XCTAssertEqual(metadata.journalID, "j1")
    }
}
