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

    init(containerRoot: URL,
         mintID: @escaping @Sendable () -> String = { ULID.make() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = AppContainer.journalsURL(containerRoot: containerRoot)
        self.mintID = mintID
        self.now = now
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
    func create(name: String) throws -> Journal {
        var registry = try load()
        // `insert` normalizes the name and hands back what it stored.
        let created = try registry.insert(Journal(id: mintID(), name: name, createdAt: now()))
        try save(registry)
        return created
    }

    @discardableResult
    func rename(id: String, to name: String) throws -> Journal {
        var registry = try load()
        let renamed = try registry.rename(id: id, to: name)
        try save(registry)
        return renamed
    }

    /// Sets (or clears, via an empty dict) a journal's voice labels (T7 Mark Voices,
    /// issue #56). Same load -> mutate -> save shape as `rename`; the pure trim/drop
    /// rule lives on `JournalRegistry.setVoiceLabels`.
    @discardableResult
    func setVoiceLabels(id: String, labels: [String: String]) throws -> Journal {
        var registry = try load()
        let updated = try registry.setVoiceLabels(id: id, labels: labels)
        try save(registry)
        return updated
    }

    /// Sets (or clears, via `nil`) a journal's stored span (spec ruling 2). Same
    /// load -> mutate -> save shape as `setVoiceLabels`; the pure rule lives on
    /// `JournalRegistry.setSpan`.
    @discardableResult
    func setSpan(id: String, span: JournalSpan?) throws -> Journal {
        var registry = try load()
        let updated = try registry.setSpan(id: id, span: span)
        try save(registry)
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
