import XCTest
import GRDB
@testable import Raconte

/// The system SQLite must carry FTS5 with the unicode61 tokenizer's `remove_diacritics 2`
/// — verified on macOS 27 (3.54.0) at design time; this pins it on every runner.
final class SearchDependencyTests: XCTestCase {
    func testFTS5WithDiacriticFoldingIsAvailable() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(virtualTable: "t", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO t(body) VALUES (?)", arguments: ["les pianos étaient là"])
        }
        let hit = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT highlight(t, 0, '[', ']') FROM t WHERE t MATCH ?",
                                arguments: [FTS5Pattern(matchingAllPrefixesIn: "etaient")])
        }
        XCTAssertEqual(hit, "les pianos [étaient] là")
    }
}
