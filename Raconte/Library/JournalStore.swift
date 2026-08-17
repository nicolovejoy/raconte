import Foundation

enum JournalStoreError: Error, Equatable {
    /// The file exists and could not be read or decoded. **Not** the same as absent:
    /// treating it as empty would let the next write replace a registry we merely failed
    /// to parse (issue #11's rule, applied here before it can be broken).
    case unreadable(String)
}

/// Persists the journals registry as a single JSON file beside `captures/`.
///
/// An actor for the same reason `SegmentStore` is one: `create` and `rename` are
/// read-modify-write over one file, and two of them interleaving loses a journal. The
/// pure decisions live in `JournalRegistry`; everything here is I/O.
actor JournalStore {
    nonisolated let url: URL

    /// `mintID` is injected so tests get deterministic ids, matching
    /// `CaptureCoordinator`'s `mintCaptureID` seam.
    private let mintID: @Sendable () -> String
    private let now: @Sendable () -> Date

    /// M4 T5. Nil everywhere sync is off — unit tests, the UI-test harness, and any build
    /// whose composition root refused to construct an engine. A store with no hook behaves
    /// exactly as it did before M4.
    private var syncHooks: (any SyncHooks)?

    init(containerRoot: URL,
         mintID: @escaping @Sendable () -> String = { ULID.make() },
         now: @escaping @Sendable () -> Date = { Date() },
         syncHooks: (any SyncHooks)? = nil) {
        self.url = AppContainer.journalsURL(containerRoot: containerRoot)
        self.mintID = mintID
        self.now = now
        self.syncHooks = syncHooks
    }

    /// Wired after construction because the composition root builds this store (inside
    /// `LibraryScreenModel`) before it can build the sync coordinator that conforms to
    /// `SyncHooks` — and the coordinator's own ingest path needs this store, so one of the
    /// two has to be attached second. Doing it this way rather than with a two-phase init
    /// leaves every existing `init` call site untouched.
    func attach(syncHooks: any SyncHooks) {
        self.syncHooks = syncHooks
    }

    // MARK: Reads

    /// The registry on disk. An absent file is an empty registry — that is a fresh
    /// install, not a failure. Anything else that goes wrong throws.
    func load() throws -> JournalRegistry {
        try Self.load(url: url)
    }

    func list() throws -> [Journal] {
        try load().journals
    }

    func journal(id: String) throws -> Journal? {
        try load().journal(id: id)
    }

    // MARK: Writes

    @discardableResult
    func create(name: String) async throws -> Journal {
        var registry = try load()
        // `insert` normalizes the name and hands back what it stored. One clock read,
        // reused for both `createdAt` and the M4 T1 `modified["name"]` stamp `insert`
        // writes — the journal's creation instant and its name's first-write instant
        // are the same moment.
        let createdAt = now()
        let created = try registry.insert(Journal(id: mintID(), name: name, createdAt: createdAt),
                                          now: createdAt)
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: created.id))
        return created
    }

    @discardableResult
    func rename(id: String, to name: String) async throws -> Journal {
        var registry = try load()
        let renamed = try registry.rename(id: id, to: name, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return renamed
    }

    /// Stamps `modified["cover"]` — the LWW stamp for the cover image, which lives outside
    /// this registry at `journals/<id>/cover.jpg`. Called by `JournalCoverStore` after it
    /// writes or removes those bytes, so `journals.json` keeps exactly one writer (this
    /// actor) while the stamp still lands.
    ///
    /// Fires the hook like any other local edit: the journal record's digest includes the
    /// cover's own sha (`SyncTreeScanner.journalArtifact`), so a new cover really is a
    /// change to the Journal record and has to be pushed.
    func stampCoverModified(id: String) async throws {
        var registry = try load()
        try registry.stampCover(id: id, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
    }

    /// Writes a merged journal back verbatim (M4 T5, design §6) — **no restamping, and no
    /// sync hook**.
    ///
    /// The missing hook is the no-echo rule, and it is load-bearing rather than an
    /// optimization. A sync-caused save that announced itself as a local change would
    /// re-upload what was just downloaded; and because `applySyncMerge` also does not
    /// restamp, the echo would carry the *remote's* stamps back at the remote — which,
    /// combined with the deviceID tie-break, is a loop two devices can sit in indefinitely,
    /// each one's echo answering the other's. See `JournalRegistry.applySyncMerge` for why
    /// the stamps travel untouched.
    func applySyncMerge(_ journal: Journal) throws {
        var registry = try load()
        registry.applySyncMerge(journal)
        try save(registry)
    }

    /// Sets (or clears, via an empty dict) a journal's voice labels (T7 Mark Voices,
    /// issue #56). Same load -> mutate -> save shape as `rename`; the pure trim/drop
    /// rule lives on `JournalRegistry.setVoiceLabels`.
    @discardableResult
    func setVoiceLabels(id: String, labels: [String: String]) async throws -> Journal {
        var registry = try load()
        let updated = try registry.setVoiceLabels(id: id, labels: labels, now: now())
        try save(registry)
        await syncHooks?.noteLocalChange(.journal(id: id))
        return updated
    }

    // Deletion is deliberately absent: a journal with entries has no defined disposal
    // for them yet (M3 T5 owns trash). Adding `delete` before that is how orphans happen.

    private func save(_ registry: JournalRegistry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.replace(at: url, writing: try Self.encode(registry))
    }

    // MARK: Pure seams (sync, so tests can exercise the format without an actor hop)

    static func load(url: URL) throws -> JournalRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
                                           || error.code == .fileNoSuchFile {
            return JournalRegistry()
        } catch {
            throw JournalStoreError.unreadable(String(describing: error))
        }
        do {
            return try CaptureCoding.decoder().decode(JournalRegistry.self, from: data)
        } catch {
            throw JournalStoreError.unreadable(String(describing: error))
        }
    }

    /// `lineEncoder()` (sorted keys, no pretty-printing) rather than the manifest's
    /// pretty encoder: this file is machine state, is rewritten whole on every change,
    /// and a stable single-line-per-value encoding keeps diffs and byte counts boring.
    /// Dates are the same ISO8601-with-milliseconds the capture path uses.
    static func encode(_ registry: JournalRegistry) throws -> Data {
        try CaptureCoding.lineEncoder().encode(registry)
    }
}
