import XCTest
@testable import Raconte

final class SearchIndexTests: XCTestCase {
    private var url: URL!
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private func matchTexts(_ hit: SearchHit?) -> [String] {
        guard let hit else { return [] }
        return hit.snippet.matches.map { String(hit.snippet.text[$0]) }
    }

    func testUpsertThenSearchByPrefixAndFoldedDiacritic() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "les pianos étaient là")
        try await index.upsert(captureID: "B", fingerprint: "1", body: "the new strings arrived")
        let hits = try await index.search(SearchQuery(text: "etai"))
        XCTAssertEqual(hits.map(\.captureID), ["A"])
        XCTAssertEqual(matchTexts(hits.first), ["étaient"])
    }

    func testUpsertReplacesNotDuplicates() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "B", fingerprint: "9", body: "gamma")
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        try await index.upsert(captureID: "A", fingerprint: "2", body: "beta")
        let alpha = try await index.search(SearchQuery(text: "alpha"))
        let beta = try await index.search(SearchQuery(text: "beta"))
        let gamma = try await index.search(SearchQuery(text: "gamma"))
        let prints = try await index.fingerprints()
        XCTAssertTrue(alpha.isEmpty)
        XCTAssertEqual(beta.map(\.captureID), ["A"])
        XCTAssertEqual(gamma.map(\.captureID), ["B"])
        XCTAssertEqual(prints, ["A": "2", "B": "9"])
    }

    func testRemoveDropsBothTables() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        try await index.upsert(captureID: "B", fingerprint: "9", body: "gamma")
        // An unknown id ahead of "A" must not stop the loop.
        try await index.remove(captureIDs: ["missing", "A"])
        let gone = try await index.search(SearchQuery(text: "alpha"))
        let kept = try await index.search(SearchQuery(text: "gamma"))
        let prints = try await index.fingerprints()
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(kept.map(\.captureID), ["B"])
        XCTAssertEqual(prints, ["B": "9"])
    }

    func testEmptyQueryReturnsNothingWithoutError() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        let hits = try await index.search(SearchQuery(text: "  "))
        XCTAssertTrue(hits.isEmpty)
    }

    func testCorruptFileIsRecreated() async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: url)
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        let hits = try await index.search(SearchQuery(text: "alpha"))
        XCTAssertEqual(hits.count, 1)
    }

    func testReopenKeepsTheRows() async throws {
        do { let i = try SearchIndex(databaseURL: url); try await i.upsert(captureID: "A", fingerprint: "1", body: "alpha") }
        let again = try SearchIndex(databaseURL: url)
        let prints = try await again.fingerprints()
        XCTAssertEqual(prints, ["A": "1"])
    }

    // The tokenizer splits at an apostrophe, so the stem of an elided word is findable.
    // Task 11's highlighter must apply the same rule.
    func testElidedWordIsFoundByItsStem() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "l'école d'été")
        let hits = try await index.search(SearchQuery(text: "ecole"))
        XCTAssertEqual(hits.map(\.captureID), ["A"])
        XCTAssertEqual(matchTexts(hits.first), ["école"])
    }

    // SearchQuery keeps accents and lowercases; the tokenizer folds at MATCH time. The
    // unaccented row is what pins the fold: without it an accent-keeping tokenizer passes.
    func testAccentedCapitalisedQueryFindsTheSameRow() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "l'école d'été")
        try await index.upsert(captureID: "B", fingerprint: "1", body: "une ecole")
        let hits = try await index.search(SearchQuery(text: "École"))
        XCTAssertEqual(Set(hits.map(\.captureID)), ["A", "B"])
        XCTAssertEqual(matchTexts(hits.first { $0.captureID == "A" }), ["école"])
        XCTAssertEqual(matchTexts(hits.first { $0.captureID == "B" }), ["ecole"])
    }

    // A second plaintext copy of every transcript stays out of backups.
    func testIndexDirectoryIsExcludedFromBackup() throws {
        _ = try SearchIndex(databaseURL: url)
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
