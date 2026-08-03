import Foundation

/// Composition + orchestration for the library and entry-detail screens (M3 T4).
///
/// Constraints this shape exists to hold:
/// - ONE `JournalStore` / `EntryMetadataStore` pair for both screens — two actors over
///   the same file do not serialize with each other (T1).
/// - Entry detail is not a separate model; it edits through this one, so a reassignment
///   made there is visible to the list without a second store racing the first.
/// - Every filter change re-scans disk instead of re-filtering a cache: at dogfood scale
///   the scan is milliseconds, and a cache is one more place for the list to disagree
///   with what an edit just wrote (M3 plan, "architecture stance").
@MainActor
@Observable
final class LibraryScreenModel {
    nonisolated let capturesRoot: URL
    private let scanner: LibraryScanner
    private let sweeper: TrashSweeper
    /// Not private (M3 T5): `CaptureScreenModel` uses **these** instances rather than
    /// building its own pair over the same files. Two `EntryMetadataStore` actors do not
    /// serialize with each other, so a backdate written from the detail screen and a
    /// journal write from the capture screen were a read-modify-write race with a lost
    /// update in it. One actor per file, app-wide, is the whole point of the type.
    let journalStore: JournalStore
    let entryMetadataStore: EntryMetadataStore

    private(set) var items: [EntryListItem] = []
    /// The 3 most recently *captured* entries, across every journal, regardless of
    /// `journalScope` — the capture screen's "what I just did" section (M3 T4.5). A
    /// separate scan rather than a slice of `items`: `items` is filtered/sorted by
    /// `effectiveDate` for the library list, and recency here means capture time, not
    /// the (possibly backdated) effective date.
    private(set) var recent: [EntryListItem] = []
    /// Everything in the trash, across every journal and independent of `journalScope`
    /// (M3 T5). Not journal-scoped on purpose: the owner deletes an entry, then goes
    /// looking for it — making him first recall which journal it was filed in is how a
    /// recoverable entry reads as gone.
    private(set) var trashed: [EntryListItem] = []
    private(set) var journals: [Journal] = []
    /// `journals.json` exists and did not decode. Rendered by `LibraryView`: without it
    /// every filed entry reads as having a dangling journal, with no way to tell why.
    private(set) var journalsUnreadable = false
    /// True from the first `rescan()` until the most recent one lands. Read by the view
    /// so an in-flight scan does not present itself as "no recordings yet".
    private(set) var isLoading = false
    /// Capture directories the scan produced no row for, and why.
    ///
    /// Surfaced only in DEBUG builds (`LibraryView`). The single reason recorded today —
    /// `.noDurableContent` — is a mis-tap or a mid-flight capture setup, so shipping
    /// chrome for it would be noise; but a silent skip is exactly how an entry
    /// disappears without anyone noticing, so the owner's own builds get to see the
    /// count rather than the scanner recording it for nobody.
    private(set) var skipped: [SkippedCapture] = []
    /// What the launch sweep did, once it has run (M3 T5). `nil` until then.
    ///
    /// Surfaced only in DEBUG, for `skipped`'s reason: a permanent deletion the owner
    /// asked for thirty days ago needs no announcement, but a sweep that keeps skipping
    /// the same directory — an unreadable sidecar, a removal that keeps failing — is a
    /// capture stuck in the trash forever, and nothing else would ever say so.
    private(set) var lastSweep: TrashSweepResult?

    var journalScope: JournalScope = .all

    /// Bumped on entry to `rescan()` and checked before results are assigned. Three UI
    /// paths (`selectJournalScope`, `moveEntry`, `setBackdate`) each fire their own Task,
    /// so scans overlap and, unguarded, the *later-finishing* one wins rather than the
    /// later-started one — a filter change that resolves fast is then overwritten by the
    /// previous filter's results. Same precedent as `CaptureScreenModel.finishing`.
    private var scanGeneration = 0

    init(capturesRoot: URL, journalsContainerRoot: URL? = nil) {
        self.capturesRoot = capturesRoot
        let containerRoot = journalsContainerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        self.scanner = LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
        self.sweeper = TrashSweeper(capturesRoot: capturesRoot)
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
            // Container root derived, not overridden — the harness keys the container
            // and `captures/` sits beneath it, exactly as in the shipping layout.
            return LibraryScreenModel(capturesRoot: UITestHarnessRoot.capturesRoot(id: id))
        }
        #endif
        return LibraryScreenModel(capturesRoot: CaptureScreenModel.defaultCapturesRoot())
    }

    var yearGroups: [EntryYearGroup] { EntryListItem.groupedByYear(items) }

    // MARK: - Scan

    /// Reloads journals and re-scans captures. **One** disk scan, unfiltered, with the
    /// three published lists derived from it in memory (M3 T5).
    ///
    /// It used to be up to two scans, and T5 would have made it three (list, recents,
    /// trash). `EntryListFilter.apply` is pure over `[EntryListItem]` and the scan itself
    /// is the expensive half — it reads and consolidates every capture's `live.jsonl` —
    /// so scanning the superset once and filtering it three ways is both cheaper and
    /// strictly more consistent: the list, the recents strip and the trash count now
    /// always describe the same instant on disk.
    func rescan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        isLoading = true

        // The scope is snapshotted here, before any suspension: this scan's results
        // belong to the filter that was current when it was asked for, not to whatever
        // a concurrent `selectJournalScope` has since set.
        let scope = journalScope

        // `nil` is an unreadable registry, `[]` a genuinely empty one. Collapsing them
        // with `try?` is the same mistake one level up from the store that draws the
        // line — the chips would silently show no journals over a registry that has them.
        let loadedJournals = try? await journalStore.list()
        let result = await scanner.scan(filter: EntryListFilter(journal: .all, trash: .all))

        // A superseded scan publishes nothing, and leaves `isLoading` set — the scan
        // that overtook it is still running and owns clearing it.
        guard generation == scanGeneration else { return }

        journals = loadedJournals ?? []
        journalsUnreadable = loadedJournals == nil || result.journalsUnreadable
        items = EntryListFilter(journal: scope, trash: .excludeTrashed).apply(to: result.items)
        trashed = EntryListFilter(journal: .all, trash: .trashedOnly).apply(to: result.items)
        skipped = result.skipped
        let live = EntryListFilter(journal: .all, trash: .excludeTrashed).apply(to: result.items)
        recent = Self.mostRecentlyCaptured(live, limit: 3)
        isLoading = false
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
        items.first { $0.captureID == captureID } ?? trashed.first { $0.captureID == captureID }
    }

    // MARK: - Entry edits (detail screen)

    /// Reassign an entry's journal. `nil` files it as unfiled.
    func moveEntry(_ captureID: String, toJournal journalID: String?) async {
        _ = try? await entryMetadataStore.update(captureID: captureID) { $0.journalID = journalID }
        await rescan()
    }

    /// Set, change, or clear (`date == nil`) the backdate. `precision` is ignored when
    /// clearing — `EntryMetadata.effectivePrecision` is meaningless without a date, so
    /// there is nothing to reset it to.
    func setBackdate(_ captureID: String, to date: Date?, precision: DatePrecision = .day) async {
        _ = try? await entryMetadataStore.update(captureID: captureID) {
            $0.originalDate = date
            $0.precision = date == nil ? nil : precision
        }
        await rescan()
    }

    // MARK: - Trash (M3 T5)

    /// Soft-delete: stamp `trashedAt`. The entry leaves the library list and the recents
    /// strip (the filter already excluded trashed items) and appears in the Trash view
    /// with its countdown running. Nothing is removed from disk.
    ///
    /// Through `update`, so an `entry.json` we cannot parse is never overwritten with a
    /// tombstone-plus-defaults — the read throws first and the entry stays exactly as it
    /// is, visible and undeleted. That is the same rule the sweep holds one layer down.
    func trashEntry(_ captureID: String, now: Date = Date()) async {
        _ = try? await entryMetadataStore.update(captureID: captureID) { $0.trashedAt = now }
        await rescan()
    }

    /// Undo. Clearing the tombstone is the whole restore — nothing ever moved.
    func restoreEntry(_ captureID: String) async {
        _ = try? await entryMetadataStore.update(captureID: captureID) { $0.trashedAt = nil }
        await rescan()
    }

    /// "Delete Now" from the Trash view: skip the remaining grace period.
    ///
    /// Re-reads the sidecar and refuses unless it says the entry is trashed, rather than
    /// trusting the row the button was drawn from. The row is a snapshot of a scan that
    /// may be seconds old and, on a synced device later, may describe a restore that has
    /// since landed. The only thing that may cost a recording is what is on disk now.
    @discardableResult
    func deleteEntryPermanently(_ captureID: String) async -> Bool {
        guard let metadata = try? await entryMetadataStore.read(captureID: captureID),
              metadata.isTrashed else { return false }
        let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try? FileManager.default.removeItem(at: dir)
        await rescan()
        return true
    }

    /// The 30-day sweep. Called once per launch, after the first scan has published, so
    /// it never sits between the owner and his library.
    func sweepTrash() async {
        let result = await sweeper.run()
        lastSweep = result
        // Only rescan when the disk actually changed — a launch with nothing expired is
        // the normal case and must not pay for a second scan.
        if !result.deleted.isEmpty { await rescan() }
    }

    // MARK: - Transcript (detail screen)

    /// The detail screen's view of one capture's transcript: full text plus the same
    /// degradations the row carries, from `EntryTranscriptLoader` — the one
    /// implementation, shared with the scanner.
    ///
    /// `nonisolated async`, like `LibraryScanner.scan`, so the read + consolidate runs
    /// on the cooperative pool. It was `@MainActor` and synchronous, which put an
    /// O(records) file parse on the main thread every time an entry was opened.
    ///
    /// `expectedRecords` is read from the manifest here rather than taken from the row:
    /// the detail screen can outlive the row (a reassignment can move it out of scope).
    nonisolated func transcript(for captureID: String) async -> EntryTranscript {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                           captureID: captureID)
            return EntryTranscriptLoader.load(
                captureDirectory: directory,
                expectedRecords: Self.committedRecords(captureDirectory: directory))
        }.value
    }

    /// `TranscriptRef.committedRecords` off the manifest, or nil when there is no
    /// manifest, no ref, or the manifest did not decode — all three mean "we cannot say
    /// whether the tail is short", which is exactly `Completeness.unknown`.
    private nonisolated static func committedRecords(captureDirectory: URL) -> Int? {
        let url = SegmentLayout.manifestURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.transcript?.committedRecords
    }
}
