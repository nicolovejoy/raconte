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

    func testIndexLivesInItsOwnBackupExcludedDirectoryBesideCaptures() throws {
        let services = SearchServices(containerRoot: containerRoot)
        XCTAssertNotNil(services.index)
        XCTAssertNotNil(services.indexer)
        XCTAssertNil(services.unavailableReason)
        let search = AppContainer.searchRoot(containerRoot: containerRoot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: search.appendingPathComponent("index.sqlite").path))
        XCTAssertTrue(try excluded(search))
        XCTAssertFalse(try excluded(containerRoot), "the archive's own root must stay in backups")
        XCTAssertFalse(try excluded(AppContainer.capturesRoot(containerRoot: containerRoot)))
        // A sibling of captures/, never inside it.
        XCTAssertEqual(search.deletingLastPathComponent().standardizedFileURL.path,
                       containerRoot.standardizedFileURL.path)
    }

    func testAnUnopenableIndexLeavesServicesUnavailableWithoutThrowing() throws {
        // `search` is a regular file, so the index directory cannot be created.
        try Data("x".utf8).write(to: AppContainer.searchRoot(containerRoot: containerRoot))
        let services = SearchServices(containerRoot: containerRoot)
        XCTAssertNil(services.index)
        XCTAssertNil(services.indexer)
        XCTAssertNotNil(services.unavailableReason)
    }
}
