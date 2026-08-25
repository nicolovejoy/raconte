import XCTest
@testable import Raconte

/// Task 1 (image capture design, "Open risks" #1): `holdsIrreplaceableArtifacts` must
/// treat an `images/` directory holding a real sidecar exactly like `final/` or
/// `transcript/` — otherwise the recovery/library-scan machinery can delete a real,
/// un-losable photo. These tests drive the real `DirectorySnapshot.gather` filesystem
/// walk over on-disk fixtures, never a mocked `imagesPresent` flag, so a broken or
/// never-wired gather step would fail them.
final class DirectorySnapshotImagesPresentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirSnapImagesTests-\(UUID().uuidString)/captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let r = root?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: r) }
    }

    @discardableResult
    private func makeCapture(id: String) -> URL {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func gather(id: String) -> CaptureSnapshot {
        DirectorySnapshot.gather(capturesRoot: root, captureID: id)
    }

    /// Baseline (must not regress): a capture with no manifest, no audio, no
    /// transcript, no images holds nothing irreplaceable.
    func testHoldsIrreplaceableArtifactsFalseForCompletelyEmptyCapture() {
        makeCapture(id: "cap-empty")
        let snap = gather(id: "cap-empty")
        XCTAssertFalse(snap.imagesPresent)
        XCTAssertFalse(snap.holdsIrreplaceableArtifacts)
    }

    /// The adversarial case this task exists for: an image sidecar and NOTHING else
    /// (no audio, no transcript) must still flip `holdsIrreplaceableArtifacts`. The
    /// fixture is a real `images/` directory with one sidecar file on disk.
    func testHoldsIrreplaceableArtifactsTrueForImageSidecarAloneWithNoAudioOrTranscript() throws {
        let dir = makeCapture(id: "cap-image-only")
        let imagesDir = SegmentLayout.imagesDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let sidecarURL = SegmentLayout.imageSidecarURL(captureDirectory: dir, imageID: "img-1")
        try Data("{}".utf8).write(to: sidecarURL)

        let snap = gather(id: "cap-image-only")
        XCTAssertTrue(snap.imagesPresent)
        XCTAssertFalse(snap.finalM4APresent)
        XCTAssertFalse(snap.finalM4APartPresent)
        XCTAssertFalse(snap.transcriptPresent)
        XCTAssertTrue(snap.holdsIrreplaceableArtifacts)
    }

    /// The abandoned-blank-entry case: an `images/` directory that exists but is
    /// empty (created, nothing ever written into it) must NOT flip `imagesPresent` —
    /// matching `transcriptPresent`'s "existence + non-empty" contract, not bare
    /// directory existence.
    func testEmptyImagesDirectoryDoesNotFlipImagesPresent() throws {
        let dir = makeCapture(id: "cap-empty-images-dir")
        let imagesDir = SegmentLayout.imagesDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let snap = gather(id: "cap-empty-images-dir")
        XCTAssertFalse(snap.imagesPresent)
        XCTAssertFalse(snap.holdsIrreplaceableArtifacts)
    }
}
