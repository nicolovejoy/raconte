import Foundation

/// One digest of what was last durably uploaded for a CloudKit record: its content hash
/// and byte count. T3 (upload queue) diffs a record's current bytes against this to
/// decide whether a re-upload is needed at all — the ledger is a local dedupe cache, not
/// a truth source (CloudKit itself is truth for what actually landed on the server).
struct UploadedDigest: Codable, Equatable, Sendable {
    var sha256: String
    var bytes: Int
}

/// Bookkeeping for the M4 sync engine, under `sync/` beside `captures/`
/// (`AppContainer.syncRoot`).
///
/// **This whole directory is a disposable cache, by design** — CKSyncEngine's own opaque
/// state blob (`engine-state.bin`), per-record system fields CloudKit needs echoed back
/// on a write it doesn't fully own (`system-fields/<recordName>.bin`), and a local dedupe
/// ledger of what content was last uploaded (`ledger.json`). None of it is ground truth:
/// the append-only capture directories under `captures/` are, and CloudKit's own servers
/// are truth for what has synced. Losing this directory — a corrupt read, a reinstall, an
/// owner-initiated reset — costs a resync, never data.
///
/// That governing rule is why every read here collapses "the file doesn't exist" and "the
/// file exists but couldn't be read or decoded" into the same nil/empty answer, unlike
/// `JournalStore` or `EntryMetadataStore`, which throw on the second case — there,
/// treating a parse failure as "absent" would re-file or resurrect real content behind a
/// bug. Nothing here can lose data by degrading; the worst a bad read costs is redoing
/// work CloudKit already has.
///
/// An actor to serialize the ledger's read-modify-write (`recordUpload`/`clearUpload`
/// each read `ledger()` then write the whole dictionary back) against concurrent callers;
/// `engineState`/`systemFields` are independent single-file operations kept on the same
/// actor so every sync bookkeeping call goes through one queue.
actor SyncBookkeepingStore {
    private static let engineStateFileName = "engine-state.bin"
    private static let systemFieldsDirectoryName = "system-fields"
    private static let ledgerFileName = "ledger.json"

    /// Always `AppContainer.syncRoot(containerRoot:)` in production — this store never
    /// derives it itself, matching `JournalCoverStore`'s pattern of taking the path it
    /// needs rather than reconstructing it from a parent root.
    nonisolated let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: Engine state

    /// CKSyncEngine's opaque state blob. Absent (never synced yet) and unreadable
    /// (corrupt) both mean "start fresh" — see the type's doc comment.
    func engineState() -> Data? {
        Self.read(url: Self.engineStateURL(root: root))
    }

    func saveEngineState(_ data: Data) throws {
        try Self.write(data, url: Self.engineStateURL(root: root))
    }

    // MARK: Per-record system fields

    /// The opaque CloudKit system fields last saved for `recordName`, or nil if there are
    /// none, or they couldn't be read.
    func systemFields(for recordName: String) -> Data? {
        Self.read(url: Self.systemFieldsURL(root: root, recordName: recordName))
    }

    func saveSystemFields(_ data: Data, for recordName: String) throws {
        try Self.write(data, url: Self.systemFieldsURL(root: root, recordName: recordName))
    }

    /// Idempotent, like `JournalCoverStore.delete`: deleting a record's fields when none
    /// are on disk is not an error, so a caller retiring a record doesn't have to check
    /// existence first.
    func deleteSystemFields(for recordName: String) throws {
        try Self.delete(url: Self.systemFieldsURL(root: root, recordName: recordName))
    }

    // MARK: Upload ledger

    /// The dedupe ledger, recordName → last-uploaded digest. An absent or unreadable
    /// `ledger.json` is an empty ledger — the worst case is T3 re-uploading content
    /// CloudKit already has, not a wrong or lost answer.
    func ledger() -> [String: UploadedDigest] {
        guard let data = Self.read(url: Self.ledgerURL(root: root)) else { return [:] }
        return (try? CaptureCoding.decoder().decode([String: UploadedDigest].self, from: data)) ?? [:]
    }

    func recordUpload(_ digest: UploadedDigest, for recordName: String) throws {
        var current = ledger()
        current[recordName] = digest
        try Self.saveLedger(current, root: root)
    }

    func clearUpload(for recordName: String) throws {
        var current = ledger()
        current.removeValue(forKey: recordName)
        try Self.saveLedger(current, root: root)
    }

    // MARK: Wipe

    /// Deletes `sync/` wholesale — every engine-state blob, every system-fields file, the
    /// ledger, gone. Safe by the type's own governing rule: nothing here is ground truth,
    /// so the next sync pass rebuilds it against CloudKit from scratch. Wiping a `sync/`
    /// that was never created is not an error.
    func wipe() throws {
        do {
            try FileManager.default.removeItem(at: root)
        } catch let error as CocoaError where error.code == .fileNoSuchFile
                                           || error.code == .fileReadNoSuchFile {
            // Nothing to wipe.
        }
    }

    // MARK: Pure seams (sync, so tests can exercise paths/format without an actor hop)

    static func engineStateURL(root: URL) -> URL {
        root.appendingPathComponent(engineStateFileName)
    }

    static func systemFieldsDirectory(root: URL) -> URL {
        root.appendingPathComponent(systemFieldsDirectoryName, isDirectory: true)
    }

    /// `recordName` is a single filename component here, not a path — it may contain
    /// dots (`a.<26-char-ULID>.0`, `m.<ulid>.<ulid>`, T3's `SyncRecordName` shapes) but a
    /// dot is not a path separator, so it stays one file inside `system-fields/`.
    /// `SyncRecordName` never contains a slash (T3 owns that guarantee); this method does
    /// not re-validate it.
    static func systemFieldsURL(root: URL, recordName: String) -> URL {
        systemFieldsDirectory(root: root).appendingPathComponent("\(recordName).bin")
    }

    static func ledgerURL(root: URL) -> URL {
        root.appendingPathComponent(ledgerFileName)
    }

    private static func read(url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    private static func write(_ data: Data, url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.replace(at: url, writing: data)
    }

    private static func delete(url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile
                                           || error.code == .fileReadNoSuchFile {
            // Already gone.
        }
    }

    private static func saveLedger(_ ledger: [String: UploadedDigest], root: URL) throws {
        let data = try CaptureCoding.lineEncoder().encode(ledger)
        try write(data, url: ledgerURL(root: root))
    }
}
