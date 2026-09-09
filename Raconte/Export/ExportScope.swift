import Foundation

/// #157: WHICH entries an export writes. `.all` is the T13 behaviour (every capture the
/// walker lists). `.selected` names journal ids to include plus whether the unfiled bucket
/// rides along. Pure value; `ArchiveExporter.export(into:scope:)` applies it.
enum ExportScope: Equatable, Sendable {
    case all
    case selected(journalIDs: Set<String>, includeUnfiled: Bool)

    /// `journalID` is a RESOLVED bucket (`ExportInventory.bucket`): a journal id that is in
    /// the registry, or nil for "unfiled". Never pass a raw sidecar `journalID` here — an
    /// orphan id would be silently excluded from every partial export while the sheet
    /// counted it under Unfiled.
    func includes(bucket journalID: String?) -> Bool {
        switch self {
        case .all:
            return true
        case let .selected(journalIDs, includeUnfiled):
            guard let journalID else { return includeUnfiled }
            return journalIDs.contains(journalID)
        }
    }
}

/// #157: what the confirmation sheet shows — one row per registry journal with its entry
/// count, plus the unfiled count. Read once per sheet presentation from the container the
/// exporter will read; the sheet's live `Export N entries` label is `entryCount(for:)` over
/// this, so the number the owner confirms is computed from the same classification the
/// exporter applies.
struct ExportInventory: Equatable, Sendable {
    struct JournalRow: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var entryCount: Int
    }

    /// Registry order (`journals.json`), same as the sidebar.
    var journals: [JournalRow]
    var unfiledCount: Int
    var totalEntries: Int

    /// Ruling 3: nil, and any id NOT in `known`, is the unfiled bucket. A sidecar naming a
    /// journal that was deleted (or never synced here) must still be exportable — it lands
    /// under Unfiled rather than in no bucket at all.
    static func bucket(journalID: String?, known: Set<String>) -> String? {
        guard let journalID, known.contains(journalID) else { return nil }
        return journalID
    }

    /// Reads one capture's sidecar and resolves its bucket. A missing or unreadable sidecar
    /// is nil (unfiled) — the exporter still copies the capture's bytes; this only decides
    /// which toggle it sits under.
    static func bucket(captureDirectory: URL, known: Set<String>) -> String? {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        guard let metadata = try? EntryMetadataStore.read(url: url) else { return nil }
        return bucket(journalID: metadata.journalID, known: known)
    }

    /// One walk (`ArchiveWalker.list`), one registry read, one sidecar read per capture.
    /// Throws only `ArchiveWalkerError.containerRootMissing` — an unreadable `journals.json`
    /// yields zero journal rows and every entry unfiled, which is what the exporter would
    /// write in that state too.
    static func read(containerRoot: URL) throws -> ExportInventory {
        let listing = try ArchiveWalker.list(containerRoot: containerRoot)
        let registry = try? JournalStore.load(url: AppContainer.journalsURL(containerRoot: containerRoot))
        let journals = registry?.journals ?? []
        let known = Set(journals.map(\.id))

        var counts: [String: Int] = [:]
        var unfiled = 0
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        for captureID in listing.captureIDs {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            if let bucket = bucket(captureDirectory: directory, known: known) {
                counts[bucket, default: 0] += 1
            } else {
                unfiled += 1
            }
        }

        return ExportInventory(
            journals: journals.map { JournalRow(id: $0.id, name: $0.name, entryCount: counts[$0.id] ?? 0) },
            unfiledCount: unfiled,
            totalEntries: listing.captureIDs.count)
    }

    func entryCount(for scope: ExportScope) -> Int {
        switch scope {
        case .all:
            return totalEntries
        case let .selected(journalIDs, includeUnfiled):
            let filed = journals.filter { journalIDs.contains($0.id) }.reduce(0) { $0 + $1.entryCount }
            return filed + (includeUnfiled ? unfiledCount : 0)
        }
    }
}
