import GRDB
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

    // The same three texts through the real pipeline: whatever FTS5 emits around a combining
    // mark, no marker reaches the snippet and the match is the matched token.
    func testSnippetsOfTextWithCombiningMarksCarryNoMarkers() async throws {
        let index = try SearchIndex(databaseURL: url)
        let rows: [(id: String, body: String, query: String)] = [
            ("keycap", "step 1\u{FE0F}\u{20E3} done", "1"),
            ("devanagari", "\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947} \u{926}\u{941}\u{928}\u{93F}\u{92F}\u{93E}",
             "\u{928}\u{92E}\u{938}"),
            ("arabic", "\u{643}\u{64E}\u{62A}\u{64E}\u{628}\u{64E} \u{627}\u{644}\u{648}\u{644}\u{62F}", "\u{643}"),
        ]
        for row in rows {
            try await index.upsert(captureID: row.id, fingerprint: "1", body: row.body)
        }
        for row in rows {
            let hits = try await index.search(SearchQuery(text: row.query))
            XCTAssertEqual(hits.map(\.captureID), [row.id])
            let snippet = try XCTUnwrap(hits.first?.snippet, row.id)
            // Short bodies: the snippet is the whole body, so nothing may be lost or added.
            XCTAssertEqual(Array(snippet.text.unicodeScalars), Array(row.body.unicodeScalars), row.id)
            XCTAssertEqual(snippet.matches.map { Array(snippet.text[$0].unicodeScalars) },
                           [Array(row.query.unicodeScalars)], row.id)
        }
    }

    // An index never flags a directory it was merely handed: that is how an archive root came
    // to be excluded from backup. `SearchServices` marks `search/` by name
    // (`SearchServicesTests.testIndexLivesInItsOwnBackupExcludedDirectoryBesideCaptures`).
    func testOpeningAnIndexLeavesItsDirectoryInBackups() throws {
        _ = try SearchIndex(databaseURL: url)
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertFalse(values.isExcludedFromBackup ?? false)
    }

    // MARK: Damage found after a successful open

    private static let populatedCount = 60

    /// Builds an index whose three tables each span several pages, then closes it.
    private func makePopulatedIndex(at databaseURL: URL) async throws {
        let index = try SearchIndex(databaseURL: databaseURL)
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        for i in 0..<Self.populatedCount {
            try await index.upsert(captureID: "E\(i)", fingerprint: "f\(i)", body: "entry\(i) \(filler)")
        }
    }

    /// How to damage a page of the closed database file, from outside SQLite.
    private enum PageDamage {
        /// The whole page becomes 0xFF: `quick_check` fails with SQLITE_CORRUPT.
        case overwritten
        /// One header byte (the fragmented-free-bytes count) is off by one. Every row on the
        /// page still reads; `quick_check` REPORTS the page and returns normally.
        case headerByteOffByOne
    }

    /// Damages the LAST leaf page of `table`, found by walking the b-tree's right-most
    /// pointers from its root. No open-time read reaches that page (they stop at the first
    /// row), so only a check of the whole file can find the damage.
    private func damageLastLeafPage(of table: String, in databaseURL: URL, _ damage: PageDamage) throws {
        let (rootPage, pageSize) = try DatabaseQueue(path: databaseURL.path).read { db in
            (try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = ?", arguments: [table]),
             try Int.fetchOne(db, sql: "PRAGMA page_size"))
        }
        let root = try XCTUnwrap(rootPage, "no table named \(table)")
        let size = try XCTUnwrap(pageSize)
        let handle = try FileHandle(forUpdating: databaseURL)
        defer { try? handle.close() }
        // SQLite file format: byte 0 of a table b-tree page is 0x05 (interior) or 0x0D
        // (leaf); an interior page keeps its right-most child's page number, big-endian,
        // in bytes 8..<12; byte 7 counts the page's fragmented free bytes.
        var page = root
        var header = Data()
        for _ in 0..<8 {
            try handle.seek(toOffset: UInt64((page - 1) * size))
            header = try XCTUnwrap(try handle.read(upToCount: 12))
            guard header.count == 12, header[0] == 0x05 else { break }
            page = header[8..<12].reduce(0) { $0 << 8 | Int($1) }
        }
        XCTAssertNotEqual(page, root, "fixture sanity: \(table) must span more than one page")
        XCTAssertEqual(header.first, 0x0D, "fixture sanity: the walk must end on a table leaf page")
        guard header.count == 12 else { return }
        let offset = UInt64((page - 1) * size)
        switch damage {
        case .overwritten:
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(repeating: 0xFF, count: size))
        case .headerByteOffByOne:
            try handle.seek(toOffset: offset + 7)
            try handle.write(contentsOf: Data([header[7] == 0 ? 1 : header[7] - 1]))
        }
        try handle.synchronize()
    }

    /// Reopens a damaged index and requires it to have been recreated: nothing remembered,
    /// and fit to index and search again.
    private func assertReopenedIndexWasRecreated(_ databaseURL: URL,
                                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let repaired = try SearchIndex(databaseURL: databaseURL)
        let prints = try await repaired.fingerprints()
        XCTAssertEqual(prints.count, 0, "a damaged index must be recreated, so every entry is indexed again",
                       file: file, line: line)
        try await repaired.upsert(captureID: "N", fingerprint: "1", body: "alpha after the repair")
        let hits = try await repaired.search(SearchQuery(text: "alpha"))
        XCTAssertEqual(hits.map(\.captureID), ["N"], file: file, line: line)
    }

    private func assertADamagedPageIsRepaired(table: String, _ damage: PageDamage,
                                              file: StaticString = #filePath, line: UInt = #line) async throws {
        try await makePopulatedIndex(at: url)
        // Control: the open check keeps a healthy index.
        let healthy = try await SearchIndex(databaseURL: url).fingerprints()
        XCTAssertEqual(healthy.count, Self.populatedCount, file: file, line: line)
        try damageLastLeafPage(of: table, in: url, damage)
        try await assertReopenedIndexWasRecreated(url, file: file, line: line)
    }

    // The table that holds the bodies. Before the open check a search that reached the page
    // threw SQLITE_CORRUPT, and no relaunch repaired it.
    func testADamagedBodyPageIsRepairedAtOpen() async throws {
        try await assertADamagedPageIsRepaired(table: "entry_text_content", .overwritten)
    }

    // The full-text index itself, where the damage was silent.
    func testADamagedFullTextIndexPageIsRepairedAtOpen() async throws {
        try await assertADamagedPageIsRepaired(table: "entry_text_data", .overwritten)
    }

    // Damage the check reports rather than throws on: the answer is not "ok", and that alone
    // must recreate the index.
    func testDamageTheCheckOnlyReportsIsRepairedAtOpen() async throws {
        try await assertADamagedPageIsRepaired(table: "entry_text_content", .headerByteOffByOne)
    }

    // The file is sound and the schema is not: only a read of the table itself can tell.
    func testAMissingFullTextTableIsRepairedAtOpen() async throws {
        try await makePopulatedIndex(at: url)
        try await DatabaseQueue(path: url.path).write { try $0.execute(sql: "DROP TABLE entry_text") }
        try await assertReopenedIndexWasRecreated(url)
    }

    func testAMissingStateTableIsRepairedAtOpen() async throws {
        try await makePopulatedIndex(at: url)
        try await DatabaseQueue(path: url.path).write { try $0.execute(sql: "DROP TABLE entry_index_state") }
        try await assertReopenedIndexWasRecreated(url)
    }

    // MARK: Deleted text does not linger in the file

    /// Lowercase ASCII, so the stored body and the folded index term are the same bytes.
    private static let marker = "zqxjkvmarker"

    /// About 20 KB carrying the marker twelve times: long enough to spill onto overflow
    /// pages, which the connection's default leaves untouched when it frees them.
    private var markedBody: String {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        return (0..<12).map { _ in "\(Self.marker) \(filler)" }.joined()
    }

    /// Occurrences of the marker in the raw bytes of every file in the index's directory.
    private func markerOccurrencesOnDisk() throws -> Int {
        let needle = Data(Self.marker.utf8)
        var count = 0
        let directory = url.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            var from = data.startIndex
            while let hit = data.range(of: needle, in: from..<data.endIndex) {
                count += 1
                from = hit.upperBound
            }
        }
        return count
    }

    // "Delete Now" removes the capture's files; the index must not be where its words survive.
    func testRemovedTextDoesNotLingerInTheFile() async throws {
        do {
            let index = try SearchIndex(databaseURL: url)
            try await index.upsert(captureID: "A", fingerprint: "1", body: markedBody)
            try await index.upsert(captureID: "B", fingerprint: "1", body: "unrelated words stay")
        }
        XCTAssertGreaterThanOrEqual(try markerOccurrencesOnDisk(), 13,
                                    "fixture sanity: twelve in the body and the index term")
        do {
            let index = try SearchIndex(databaseURL: url)
            try await index.remove(captureIDs: ["A"])
            let kept = try await index.search(SearchQuery(text: "unrelated"))
            XCTAssertEqual(kept.map(\.captureID), ["B"])
        }
        XCTAssertEqual(try markerOccurrencesOnDisk(), 0)
    }

    // An edit replaces the row: the words the owner removed go too. The second row is the
    // control: it must survive, or an index that was simply recreated would pass too.
    func testReplacedTextDoesNotLingerInTheFile() async throws {
        do {
            let index = try SearchIndex(databaseURL: url)
            try await index.upsert(captureID: "A", fingerprint: "1", body: markedBody)
            try await index.upsert(captureID: "B", fingerprint: "1", body: "unrelated words stay")
        }
        XCTAssertGreaterThanOrEqual(try markerOccurrencesOnDisk(), 13,
                                    "fixture sanity: twelve in the body and the index term")
        do {
            let index = try SearchIndex(databaseURL: url)
            try await index.upsert(captureID: "A", fingerprint: "2", body: "the entry after the edit")
            let hits = try await index.search(SearchQuery(text: "edit"))
            XCTAssertEqual(hits.map(\.captureID), ["A"])
            let kept = try await index.search(SearchQuery(text: "unrelated"))
            XCTAssertEqual(kept.map(\.captureID), ["B"])
        }
        XCTAssertEqual(try markerOccurrencesOnDisk(), 0)
    }
}
