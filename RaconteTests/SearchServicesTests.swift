import XCTest
@testable import Raconte

/// #194 Task 6: where the index lives, and what happens when it cannot open.
final class SearchServicesTests: XCTestCase {

    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchServices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: AppContainer.capturesRoot(containerRoot: containerRoot),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func excluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    func testIndexLivesInItsOwnDirectoryBesideCaptures() throws {
        let services = SearchServices(containerRoot: containerRoot)
        XCTAssertNotNil(services.index)
        XCTAssertNotNil(services.indexer)
        XCTAssertNil(services.unavailableReason)
        let search = AppContainer.searchRoot(containerRoot: containerRoot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: search.appendingPathComponent("index.sqlite").path))
        // A sibling of captures/, never inside it.
        XCTAssertEqual(search.deletingLastPathComponent().standardizedFileURL.path,
                       containerRoot.standardizedFileURL.path)
    }

    /// `search/` is kept out of backups, and nothing else is: the flag goes on that directory
    /// by name. Skips where the flag cannot be set or read back at all (CI runners); the
    /// "not excluded" half is only evidence where the flag works, so it stays in this test.
    func testOnlyTheSearchDirectoryIsExcludedFromBackup() throws {
        try BackupExclusionProbe.skipUnlessTheFlagCanBeMeasured(under: FileManager.default.temporaryDirectory)
        let services = SearchServices(containerRoot: containerRoot)
        XCTAssertNotNil(services.index)
        XCTAssertTrue(try excluded(AppContainer.searchRoot(containerRoot: containerRoot)))
        XCTAssertFalse(try excluded(containerRoot), "the archive's own root must stay in backups")
        XCTAssertFalse(try excluded(AppContainer.capturesRoot(containerRoot: containerRoot)))
    }

    func testAnUnopenableIndexLeavesServicesUnavailableWithoutThrowing() throws {
        // `search` is a regular file, so the index directory cannot be created.
        try Data("x".utf8).write(to: AppContainer.searchRoot(containerRoot: containerRoot))
        let services = SearchServices(containerRoot: containerRoot)
        XCTAssertNil(services.index)
        XCTAssertNil(services.indexer)
        XCTAssertNotNil(services.unavailableReason)
    }

    // MARK: The unit-test gate

    func testSearchIsOnForAPlainLaunch() {
        XCTAssertTrue(SearchServices.isEnabled(environment: [:]))
        XCTAssertTrue(SearchServices.isEnabled(environment: ["HOME": "/Users/someone", "TMPDIR": "/tmp"]))
    }

    func testSearchIsOffWhenTheAppIsHostedByXCTest() {
        XCTAssertFalse(SearchServices.isEnabled(
            environment: ["XCTestConfigurationFilePath": "/tmp/Raconte.xctestconfiguration"]))
        // Xcode can hand the host the key with an empty value: the key is what counts.
        XCTAssertFalse(SearchServices.isEnabled(environment: ["XCTestConfigurationFilePath": ""]))
    }

    /// UI tests launch the app as its own process, keyed to a throwaway container, with no
    /// XCTest configuration: they keep the real wiring.
    func testSearchStaysOnUnderTheUITestHarness() {
        XCTAssertTrue(SearchServices.isEnabled(environment: ["RACONTE_UITEST_ID": UUID().uuidString]))
    }

    /// `#Preview { ContentView(services: AppServices()) }` builds the same composition root; on
    /// a Mac destination that is the sandboxed app over the real container, running whatever
    /// the working tree holds. Detected the way the sync gate detects it.
    func testSearchIsOffUnderAnXcodePreview() {
        XCTAssertFalse(SearchServices.isEnabled(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
    }

    /// The gate, asserted from inside the environment it exists for. This suite's host is the
    /// real app over the owner's real Mac container; `AppServices` reads this same answer.
    func testThisTestHostKeepsSearchOff() {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertNotNil(environment["XCTestConfigurationFilePath"],
                        "this test is only meaningful while it runs under XCTest")
        XCTAssertFalse(SearchServices.isEnabled(environment: environment))
    }
}
