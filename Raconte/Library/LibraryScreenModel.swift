import Foundation

/// Composition + orchestration for the library and entry-detail screens (M3 T4). Owns the
/// scan, the journal filter, and the single `JournalStore` / `EntryMetadataStore` instances
/// both screens edit through — one of each for the whole flow, the same rule
/// `CaptureScreenModel` documents (T1: two actors over the same file don't serialize with
/// each other). The entry-detail screen is not a separate model; it reads and writes
/// through this one so a journal reassignment or backdate made in detail is visible to the
/// list without a second store racing the first.
///
/// Re-scans disk on every filter change rather than caching and re-filtering in memory —
/// deliberate, per the M3 plan's "architecture stance": at dogfood scale (tens to low
/// hundreds of entries) a full scan is milliseconds, and a cache is one more place for the
/// list to disagree with what an edit just wrote.
@MainActor
@Observable
final class LibraryScreenModel {
    let capturesRoot: URL
    private let scanner: LibraryScanner
    private let journalStore: JournalStore
    private let entryMetadataStore: EntryMetadataStore

    private(set) var items: [EntryListItem] = []
    /// The 3 most recently *captured* entries, across every journal, regardless of
    /// `journalScope` — the capture screen's "what I just did" section (M3 T4.5). A
    /// separate scan rather than a slice of `items`: `items` is filtered/sorted by
    /// `effectiveDate` for the library list, and recency here means capture time, not
    /// the (possibly backdated) effective date.
    private(set) var recent: [EntryListItem] = []
    private(set) var journals: [Journal] = []
    private(set) var journalsUnreadable = false
    private(set) var isLoading = false

    var journalScope: JournalScope = .all

    init(capturesRoot: URL, journalsContainerRoot: URL? = nil) {
        self.capturesRoot = capturesRoot
        let containerRoot = journalsContainerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        self.scanner = LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
        self.journalStore = JournalStore(containerRoot: containerRoot)
        self.entryMetadataStore = EntryMetadataStore(capturesRoot: capturesRoot)
    }

    /// Live composition root, matching `CaptureScreenModel.live()`'s captures root exactly
    /// — including its `RACONTE_UITEST_ID` harness redirect, via the same
    /// `UITestHarnessRoot` helper, so the library scans the tree the capture screen is
    /// actually writing to under UI test.
    static func live() -> LibraryScreenModel {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["RACONTE_UITEST_ID"] {
            let root = UITestHarnessRoot.capturesRoot(id: id)
            return LibraryScreenModel(capturesRoot: root, journalsContainerRoot: root)
        }
        #endif
        return LibraryScreenModel(capturesRoot: CaptureScreenModel.defaultCapturesRoot())
    }

    var yearGroups: [EntryYearGroup] { EntryListItem.groupedByYear(items) }

    // MARK: - Scan

    /// Reloads journals and re-scans captures under the current `journalScope`. Trashed
    /// entries are always excluded — T5 owns the Trash screen and its own filter value;
    /// this screen never asks for anything but `.excludeTrashed`.
    func rescan() async {
        isLoading = true
        defer { isLoading = false }
        journals = (try? await journalStore.list()) ?? []
        let filter = EntryListFilter(journal: journalScope, trash: .excludeTrashed)
        let result = await scanner.scan(filter: filter)
        items = result.items
        journalsUnreadable = result.journalsUnreadable

        let recentResult = journalScope == .all
            ? result
            : await scanner.scan(filter: EntryListFilter(journal: .all, trash: .excludeTrashed))
        recent = Self.mostRecentlyCaptured(recentResult.items, limit: 3)
    }

    /// Sorted by `capturedAt` descending — deliberately not `effectiveDate`: recency on
    /// the capture screen means "what I just recorded", not wherever a backdate put it.
    static func mostRecentlyCaptured(_ items: [EntryListItem], limit: Int) -> [EntryListItem] {
        let sorted = items.sorted {
            $0.capturedAt == $1.capturedAt
                ? $0.captureID > $1.captureID
                : $0.capturedAt > $1.capturedAt
        }
        return Array(sorted.prefix(limit))
    }

    func selectJournalScope(_ scope: JournalScope) async {
        journalScope = scope
        await rescan()
    }

    /// The current row for `captureID`, if the last scan still includes it — `nil` after
    /// an edit that moves it out of the active journal filter. Callers (the detail screen)
    /// must keep their own last-known copy rather than treating `nil` as "gone".
    func item(_ captureID: String) -> EntryListItem? {
        items.first { $0.captureID == captureID }
    }

    // MARK: - Entry edits (detail screen)

    /// Reassign an entry's journal. `nil` files it as unfiled.
    func moveEntry(_ captureID: String, toJournal journalID: String?) async {
        try? await entryMetadataStore.update(captureID: captureID) { $0.journalID = journalID }
        await rescan()
    }

    /// Set, change, or clear (`date == nil`) the backdate.
    func setBackdate(_ captureID: String, to date: Date?) async {
        try? await entryMetadataStore.update(captureID: captureID) { $0.originalDate = date }
        await rescan()
    }

    // MARK: - Transcript (detail screen)

    /// The full consolidated transcript for one capture — not the library row's truncated
    /// snippet. Same reader and the same `TranscriptConsolidator` replay
    /// `LibraryScanner.transcriptSummary` uses (issue #10: reading the raw log does not
    /// reproduce the live view), just without the character limit.
    func transcriptText(for captureID: String) -> (state: EntryTranscriptState, text: String?) {
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let load = LiveTranscriptReader.load(captureDirectory: directory)
        switch load.source {
        case .absent:
            return (.absent, nil)
        case .unreadable:
            return (.unreadable, nil)
        case .present:
            let text = LiveTranscriptReader.consolidate(load.records).committedText
            return (.present, text)
        }
    }
}
