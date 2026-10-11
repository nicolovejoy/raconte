import Foundation
import GRDB
import os

/// The FTS5 index: a disposable derivative of the archive (spec §Approach). Only
/// `captureID` and `body` live here — journal, date and trash are filtered in Swift from
/// `LibraryScreenModel.allEntries`, so a metadata edit never stales the index.
actor SearchIndex {
    private let queue: DatabaseQueue
    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    /// The index needs a directory of its own: that directory is marked excluded from backup,
    /// so a file placed directly in a shared folder would exclude everything beside it.
    init(databaseURL: URL) throws {
        var directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The index is a second plaintext copy of every transcript: keep it out of backups.
        // A backup hint must never block opening the index.
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            Self.log.notice("search index: could not exclude from backup: \(error.localizedDescription, privacy: .public)")
        }
        do {
            queue = try Self.open(databaseURL)
        } catch {
            // One recreate: the index is derivative, a rebuild is the whole recovery.
            Self.log.notice("search index unreadable, recreating: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: databaseURL)
            queue = try Self.open(databaseURL)
        }
    }

    private static func open(_ url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        // The migrator's table is the schema version. A schema or tokenizer change is a new
        // migration that drops both tables; the empty fingerprints then rebuild everything.
        migrator.registerMigration("v1") { db in
            try db.create(virtualTable: "entry_text", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("captureID").notIndexed()
                t.column("body")
            }
            // The state table owns the integer id; the FTS row shares it as its rowid, so no
            // statement ever has to scan `entry_text` by its unindexed captureID.
            try db.create(table: "entry_index_state") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captureID", .text).notNull().unique()
                t.column("fingerprint", .text).notNull()
            }
        }
        try migrator.migrate(queue)
        // A corrupt file can open and then fail on first read — probe it now.
        _ = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM entry_index_state") }
        return queue
    }

    func fingerprints() throws -> [String: String] {
        try queue.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT captureID, fingerprint FROM entry_index_state") {
                out[row["captureID"]] = row["fingerprint"]
            }
            return out
        }
    }

    func upsert(captureID: String, fingerprint: String, body: String) throws {
        try queue.write { db in
            let rowID: Int64
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM entry_index_state WHERE captureID = ?",
                                                 arguments: [captureID]) {
                try db.execute(sql: "DELETE FROM entry_text WHERE rowid = ?", arguments: [existing])
                try db.execute(sql: "UPDATE entry_index_state SET fingerprint = ? WHERE id = ?",
                               arguments: [fingerprint, existing])
                rowID = existing
            } else {
                try db.execute(sql: "INSERT INTO entry_index_state(captureID, fingerprint) VALUES (?, ?)",
                               arguments: [captureID, fingerprint])
                rowID = db.lastInsertedRowID
            }
            try db.execute(sql: "INSERT INTO entry_text(rowid, captureID, body) VALUES (?, ?, ?)",
                           arguments: [rowID, captureID, body])
        }
    }

    func remove(captureIDs: [String]) throws {
        guard !captureIDs.isEmpty else { return }
        try queue.write { db in
            for id in captureIDs {
                guard let rowID = try Int64.fetchOne(db, sql: "SELECT id FROM entry_index_state WHERE captureID = ?",
                                                     arguments: [id]) else { continue }
                try db.execute(sql: "DELETE FROM entry_text WHERE rowid = ?", arguments: [rowID])
                try db.execute(sql: "DELETE FROM entry_index_state WHERE id = ?", arguments: [rowID])
            }
        }
    }

    func search(_ query: SearchQuery) throws -> [SearchHit] {
        guard let pattern = query.pattern else { return [] }
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT captureID, snippet(entry_text, 1, ?, ?, '…', 12) AS snippet
                FROM entry_text WHERE entry_text MATCH ?
                """, arguments: [SearchSnippet.openMarker, SearchSnippet.closeMarker, pattern])
            return rows.map { SearchHit(captureID: $0["captureID"], snippet: SearchSnippet.parse($0["snippet"])) }
        }
    }
}

struct SearchHit: Sendable, Equatable {
    var captureID: String
    var snippet: SearchSnippet
}
