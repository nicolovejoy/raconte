#if DEBUG
import XCTest
@testable import Raconte

/// Pure core of the Debug-screen build-info row (see `BuildStamp.swift`):
/// picking which on-disk file's mtime represents "the build" given a Debug
/// build's thin main-executable stub, formatting that timestamp per the
/// UTC-at-rest/Pacific-on-display convention, and formatting a Mach-O
/// LC_UUID short identity. The dyld image walk and bundle enumeration are
/// I/O and are exercised only indirectly (see
/// `testLoadedImageUUIDFindsARealLoadedMachOImage`), never asserted against
/// hardcoded values.
final class BuildStampTests: XCTestCase {
    // MARK: representativeFile

    func testRepresentativeFilePicksNewestModificationDate() {
        let older = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Frameworks/Raconte.debug.dylib"),
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        let chosen = BuildStamp.representativeFile(among: [older, newer])
        XCTAssertEqual(chosen, newer)
    }

    func testRepresentativeFilePicksNewestRegardlessOfInputOrder() {
        let older = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newer = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Frameworks/Raconte.debug.dylib"),
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        // Reversed order from the sibling test — a min-picking bug could
        // still return `newer` here by coincidence if it only failed on
        // ordering, so this pins the *value* comparison, not just order.
        let chosen = BuildStamp.representativeFile(among: [newer, older])
        XCTAssertEqual(chosen, newer)
    }

    func testRepresentativeFileNilForEmptyCandidates() {
        XCTAssertNil(BuildStamp.representativeFile(among: []))
    }

    // MARK: isBuildEvidence (I1 fix — pinned both ways)

    func testIsBuildEvidenceTrueForADebugDylib() {
        XCTAssertTrue(BuildStamp.isBuildEvidence(fileName: "Raconte.debug.dylib"))
    }

    func testIsBuildEvidenceFalseForThePreviewDylib() {
        // Xcode Previews' `__preview.dylib` can be newer than the real build
        // and would poison `representativeFile`'s max if it were counted.
        XCTAssertFalse(BuildStamp.isBuildEvidence(fileName: "__preview.dylib"))
    }

    func testIsBuildEvidenceFalseForTheMainExecutableName() {
        // The main executable is supplied separately via `executableURL`,
        // never discovered through this suffix predicate.
        XCTAssertFalse(BuildStamp.isBuildEvidence(fileName: "Raconte"))
    }

    // MARK: candidates(inDirectory:executableURL:) — real fixture tree

    func testCandidatesFindsExecutableAndDebugDylibButExcludesPreviewDylib() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildStampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executableURL = root.appendingPathComponent("Raconte")
        let macOSDir = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let dylibURL = macOSDir.appendingPathComponent("Raconte.debug.dylib")
        let previewURL = macOSDir.appendingPathComponent("__preview.dylib")

        try Data("exe".utf8).write(to: executableURL)
        try Data("dylib".utf8).write(to: dylibURL)
        try Data("preview".utf8).write(to: previewURL)

        let executableDate = Date(timeIntervalSince1970: 500)
        let dylibDate = Date(timeIntervalSince1970: 1_000)
        let latest = Date(timeIntervalSince1970: 3_000)
        try FileManager.default.setAttributes([.modificationDate: executableDate], ofItemAtPath: executableURL.path)
        try FileManager.default.setAttributes([.modificationDate: dylibDate], ofItemAtPath: dylibURL.path)
        // The preview dylib is the NEWEST file on disk. If it were treated
        // as build evidence, `representativeFile` would pick it — the exact
        // poisoning the reviewer's finding named.
        try FileManager.default.setAttributes([.modificationDate: latest], ofItemAtPath: previewURL.path)

        let candidates = BuildStamp.candidates(inDirectory: root, executableURL: executableURL)
        let urls = Set(candidates.map(\.url))

        XCTAssertTrue(urls.contains(executableURL))
        XCTAssertTrue(urls.contains(dylibURL))
        XCTAssertFalse(urls.contains(previewURL), "preview dylib must never count as build evidence")

        // And the poisoning check end-to-end: representativeFile must not
        // pick the preview dylib's later mtime.
        let representative = BuildStamp.representativeFile(among: candidates)
        XCTAssertEqual(representative?.url, dylibURL)
    }

    /// The realistic ordering (C1 fix round): on a real build the main
    /// executable stub links ~58ms AFTER the debug dylib, so it is the
    /// mtime max — the inverse of the sibling fixture above. This is
    /// exactly the case that broke identity: `representativeFile` (the
    /// date source) correctly picks the newer executable, but the identity
    /// source must NOT follow it there, or every build's displayed
    /// identity collapses to the stub's constant UUID.
    func testCandidatesWithExecutableNewerThanDylibStillPicksTheDylibForRepresentativeDateSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildStampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executableURL = root.appendingPathComponent("Raconte")
        let macOSDir = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let dylibURL = macOSDir.appendingPathComponent("Raconte.debug.dylib")

        try Data("exe".utf8).write(to: executableURL)
        try Data("dylib".utf8).write(to: dylibURL)

        let dylibDate = Date(timeIntervalSince1970: 1_000)
        let executableDate = Date(timeIntervalSince1970: 1_058) // links ~58ms later
        try FileManager.default.setAttributes([.modificationDate: dylibDate], ofItemAtPath: dylibURL.path)
        try FileManager.default.setAttributes([.modificationDate: executableDate], ofItemAtPath: executableURL.path)

        let candidates = BuildStamp.candidates(inDirectory: root, executableURL: executableURL)

        // Date source: mtime max, unchanged contract — the executable wins.
        let representative = BuildStamp.representativeFile(among: candidates)
        XCTAssertEqual(representative?.url, executableURL)

        // Identity source: must diverge from the date source here — the
        // dylib, never the stub, because the stub's UUID never changes.
        let identity = BuildStamp.identityCandidate(among: candidates)
        XCTAssertEqual(identity?.url, dylibURL)
    }

    // MARK: identityCandidate (C1 fix — pinned against preferring the stub)

    func testIdentityCandidatePrefersTheDylibEvenWhenTheExecutableIsNewer() {
        let newerExecutable = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 9_999)
        )
        let olderDylib = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Frameworks/Raconte.debug.dylib"),
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        // This is the exact defect: preferring `representativeFile` (mtime
        // max) for identity returns the executable here. A correct fix
        // must return the dylib regardless.
        let identity = BuildStamp.identityCandidate(among: [olderDylib, newerExecutable])
        XCTAssertEqual(identity, olderDylib)
    }

    func testIdentityCandidateFallsBackToTheExecutableWhenNoDylibExists() {
        let onlyExecutable = BuildFileStamp(
            url: URL(fileURLWithPath: "/app/Raconte"),
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(BuildStamp.identityCandidate(among: [onlyExecutable]), onlyExecutable)
    }

    func testIdentityCandidateNilForEmptyCandidates() {
        XCTAssertNil(BuildStamp.identityCandidate(among: []))
    }

    // MARK: displayString — date + honest label + timezone

    func testDisplayStringUsesPacificTimeZoneNotUTC() {
        // 2026-08-12 18:41 PT == 2026-08-13 01:41 UTC (PDT, UTC-7).
        var utcComponents = DateComponents()
        utcComponents.year = 2026
        utcComponents.month = 8
        utcComponents.day = 13
        utcComponents.hour = 1
        utcComponents.minute = 41
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let date = utcCalendar.date(from: utcComponents)!

        let display = BuildStamp.displayString(for: date)
        XCTAssertEqual(display, "Binary file date 2026-08-12 18:41 PT")
    }

    func testDisplayStringNeverClaimsToBeTheBuildTime() {
        // C1: mtime is copy time on a `cp`-distributed build, not link
        // time — the label must not say "Built".
        let display = BuildStamp.displayString(for: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(display.contains("Built"))
        XCTAssertTrue(display.hasPrefix("Binary file date "))
        XCTAssertTrue(display.hasSuffix(" PT"))
    }

    // MARK: shortIdentity — pure UUID formatting

    func testShortIdentityIsTheFirstEightHexCharactersOfTheUUID() {
        let uuid = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!
        XCTAssertEqual(BuildStamp.shortIdentity(from: uuid), "A1B2C3D4")
    }

    func testShortIdentityDiffersForDifferentUUIDs() {
        let a = UUID(uuidString: "11111111-0000-0000-0000-000000000000")!
        let b = UUID(uuidString: "22222222-0000-0000-0000-000000000000")!
        XCTAssertNotEqual(BuildStamp.shortIdentity(from: a), BuildStamp.shortIdentity(from: b))
    }

    // MARK: loadedImageUUID — I/O edge, exercised against the real process

    func testLoadedImageUUIDFindsARealLoadedMachOImage() {
        // The test host process itself (this xctest bundle, or the app
        // hosting it) is a real loaded Mach-O image with a real LC_UUID.
        // We don't assert a specific value (that would be a brittle,
        // environment-dependent fixture) — we assert the mechanism finds
        // *some* image and extracts a well-formed UUID from it, which is
        // the honest amount of evidence this I/O edge can offer in a test.
        let bundlePath = Bundle(for: BuildStampTests.self).executablePath
        XCTAssertNotNil(bundlePath, "test bundle must have a resolvable executable path")
        guard let bundlePath else { return }
        let uuid = BuildStamp.loadedImageUUID(forExecutablePath: bundlePath)
        XCTAssertNotNil(uuid, "a real, currently-loaded Mach-O image must yield an LC_UUID")
    }

    func testLoadedImageUUIDReturnsNilForAPathThatIsNotALoadedImage() {
        XCTAssertNil(BuildStamp.loadedImageUUID(forExecutablePath: "/definitely/not/a/loaded/image"))
    }

    /// This is the actual production path, not a proxy: `Bundle.main` in
    /// this macOS unit-test host is `Raconte.app`, and `@testable import
    /// Raconte` means its code-bearing `Raconte.debug.dylib` is loaded into
    /// this very process — under exactly the bundle path
    /// `currentBuildCandidates`/`identityCandidate` would produce. If this
    /// ever returns nil, the production row would silently degrade to
    /// "identity unavailable" on every real launch.
    func testLoadedImageUUIDFindsTheRaconteDebugDylibAtItsBundlePath() {
        let allCandidates = BuildStamp.currentBuildCandidates(bundle: .main)
        guard let dylibCandidate = BuildStamp.identityCandidate(among: allCandidates),
              BuildStamp.isBuildEvidence(fileName: dylibCandidate.url.lastPathComponent)
        else {
            XCTFail("expected a *.debug.dylib candidate in the test host's own bundle")
            return
        }
        let uuid = BuildStamp.loadedImageUUID(forExecutablePath: dylibCandidate.url.path)
        XCTAssertNotNil(uuid, "Raconte.debug.dylib must be a loaded image with a readable LC_UUID")
    }

    // MARK: combinedDisplayString — N1: silence vs "identity unavailable" must differ

    func testCombinedDisplayStringNamesIdentityAsUnavailableWhenNil() {
        let result = BuildStamp.combinedDisplayString(dateString: "Binary file date 2026-08-12 18:41 PT", identity: nil)
        XCTAssertEqual(result, "Binary file date 2026-08-12 18:41 PT · identity unavailable")
    }

    func testCombinedDisplayStringAppendsTheShortIdentityWhenPresent() {
        let uuid = UUID(uuidString: "544D7A8A-0000-0000-0000-000000000000")!
        let result = BuildStamp.combinedDisplayString(dateString: "Binary file date 2026-08-12 18:41 PT", identity: uuid)
        XCTAssertEqual(result, "Binary file date 2026-08-12 18:41 PT · 544D7A8A")
    }

    func testCombinedDisplayStringDateOnlyCaseIsVisiblyDistinctFromAnIdentityCase() {
        // N1 itself: the two branches must not collapse to the same text.
        let dateString = "Binary file date 2026-08-12 18:41 PT"
        let withoutIdentity = BuildStamp.combinedDisplayString(dateString: dateString, identity: nil)
        let withIdentity = BuildStamp.combinedDisplayString(
            dateString: dateString,
            identity: UUID(uuidString: "544D7A8A-0000-0000-0000-000000000000")!
        )
        XCTAssertNotEqual(withoutIdentity, dateString)
        XCTAssertNotEqual(withoutIdentity, withIdentity)
    }
}
#endif
