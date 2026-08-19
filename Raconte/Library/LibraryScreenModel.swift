import Foundation

/// Model-to-model rescan notification (#62, nav redesign §5.1). `CaptureScreenModel`
/// conforms so `LibraryScreenModel.rescan()` can tell it directly that the world may
/// have changed — no view, no `.onChange`, in the loop. "A receipt whose entry left the
/// library is cleared" becomes a model invariant that holds regardless of what is
/// mounted, rather than a fact only true while `CaptureView` happens to be on screen.
@MainActor
protocol LibraryRescanObserver: AnyObject {
    func libraryDidRescan()
}

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
    /// Backs both permanent-delete paths this model owns (Delete Now). The 30-day sweep
    /// has its own, built the same way, inside `TrashSweeper` (#25).
    private let remover: StagedRemover
    /// Not private (M3 T5): `CaptureScreenModel` uses **these** instances rather than
    /// building its own pair over the same files. Two `EntryMetadataStore` actors do not
    /// serialize with each other, so a backdate written from the detail screen and a
    /// journal write from the capture screen were a read-modify-write race with a lost
    /// update in it. One actor per file, app-wide, is the whole point of the type.
    let journalStore: JournalStore
    let entryMetadataStore: EntryMetadataStore
    let journalCoverStore: JournalCoverStore
    /// One `TranscriptRevisionStore` for the whole app (T6c), same reasoning as
    /// `entryMetadataStore`: `CaptureScreenModel` reads THIS instance rather than
    /// building its own over the same `capturesRoot`.
    let revisionStore: TranscriptRevisionStore

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
    /// Every non-trashed entry, across every journal, independent of `journalScope` —
    /// the source `recent` and `dateRange(forJournal:)` both derive from, since neither
    /// wants the current filter's narrowing (issue #14 part 2).
    private(set) var allEntries: [EntryListItem] = []
    private(set) var journals: [Journal] = []
    /// Cover JPEG bytes by journal id (issue #14 part 3), for whichever journals have
    /// one. Reloaded on every `rescan()` alongside `journals` — the chips and the
    /// capture header both read this rather than hitting the store themselves, the same
    /// "one scan, three consumers" shape `items`/`recent`/`trashed` already use.
    private(set) var journalCovers: [String: Data] = [:]
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

    /// WEAK. `CaptureScreenModel` holds `library` strongly; a strong back-reference here
    /// would be a retain cycle — and although both live for the app's lifetime in the
    /// running app, every test that builds a `CaptureScreenModel`/`LibraryScreenModel`
    /// pair (there are many) would leak one for the length of the test process.
    weak var rescanObserver: (any LibraryRescanObserver)?

    /// Bumped on entry to `rescan()` and checked before results are assigned. Three UI
    /// paths (`selectJournalScope`, `moveEntry`, `setBackdate`) each fire their own Task,
    /// so scans overlap and, unguarded, the *later-finishing* one wins rather than the
    /// later-started one — a filter change that resolves fast is then overwritten by the
    /// previous filter's results. Same precedent as `CaptureScreenModel.finishing`.
    private var scanGeneration = 0

    /// Guards `promoteCorpusOnce()` — the launch pass runs at most once per app launch
    /// (per model instance), never on every `rescan()`.
    private var corpusPromotionRan = false

    /// Guards `closeStaleDraftsOnce()` (T7 prereq #41), same reasoning as
    /// `corpusPromotionRan`: `closeStaleDraftIfNeeded` is individually idempotent, so
    /// this guard is a cost saver against a second `bootstrap()` re-walking the whole
    /// corpus, not a correctness one.
    private var staleDraftsClosedRan = false

    /// Guards `stampUnstampedHeadsOnce()` (T7 Task 3 fix round 2), same reasoning as
    /// `corpusPromotionRan`: `stampUnstampedHeads` is itself a no-op per-capture once
    /// a head is trustworthy, so this guard is a cost saver against a second
    /// `bootstrap()` re-walking the whole corpus, not a correctness one.
    private var headStampRan = false

    init(capturesRoot: URL, journalsContainerRoot: URL? = nil) {
        self.capturesRoot = capturesRoot
        let containerRoot = journalsContainerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        self.scanner = LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
        self.sweeper = TrashSweeper(capturesRoot: capturesRoot, containerRoot: containerRoot)
        self.remover = StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)
        self.journalStore = JournalStore(containerRoot: containerRoot)
        self.entryMetadataStore = EntryMetadataStore(capturesRoot: capturesRoot)
        self.journalCoverStore = JournalCoverStore(containerRoot: containerRoot)
        self.revisionStore = TranscriptRevisionStore(capturesRoot: capturesRoot)
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
            let capturesRoot = UITestHarnessRoot.capturesRoot(id: id)
            // T7 Task 4.6: an entry with a real chain to edit, since nothing is ever
            // transcribed under the synthetic harness. No-op unless asked for.
            UITestEntrySeed.seedIfRequested(capturesRoot: capturesRoot)
            // T7 Mark Voices, issue #56, Task 6: two more entries with real
            // frame-bounded spans (one already voice-marked, one not), since the
            // editor's fixture above is deliberately frameless. No-op unless asked for.
            UITestVoiceMarkingSeed.seedIfRequested(capturesRoot: capturesRoot)
            return LibraryScreenModel(capturesRoot: capturesRoot)
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
        var loadedCovers: [String: Data] = [:]
        for journal in loadedJournals ?? [] {
            if let data = await journalCoverStore.read(journalID: journal.id) {
                loadedCovers[journal.id] = data
            }
        }
        let result = await scanner.scan(filter: EntryListFilter(journal: .all, trash: .all))

        // A superseded scan publishes nothing, and leaves `isLoading` set — the scan
        // that overtook it is still running and owns clearing it.
        guard generation == scanGeneration else { return }

        journals = loadedJournals ?? []
        journalCovers = loadedCovers
        journalsUnreadable = loadedJournals == nil || result.journalsUnreadable
        items = EntryListFilter(journal: scope, trash: .excludeTrashed).apply(to: result.items)
        trashed = EntryListFilter(journal: .all, trash: .trashedOnly).apply(to: result.items)
        skipped = result.skipped
        allEntries = EntryListFilter(journal: .all, trash: .excludeTrashed).apply(to: result.items)
        recent = Self.mostRecentlyCaptured(allEntries, limit: 3)
        isLoading = false
        // Model-to-model, no view in the loop (#62, nav redesign §5.1). Placed after
        // every published assignment and after the superseded-scan guard above: the
        // observer's whole job is to compare a receipt against `allEntries`, so it must
        // never see a half-applied scan or one this model has already abandoned.
        rescanObserver?.libraryDidRescan()
    }

    /// Derived, not stored — see `JournalDateRange`. `nil` for a journal with no
    /// (non-trashed) entries, including one that does not exist.
    func dateRange(forJournal journalID: String) -> JournalDateRange? {
        JournalDateRange.compute(from: allEntries.filter { $0.journalID == journalID })
    }

    /// The one date line for a journal, span-first. `SidebarView` and the journal header
    /// both read this rather than deciding for themselves.
    func dateLine(forJournal journalID: String) -> String? {
        JournalDateLine.text(span: journals.first { $0.id == journalID }?.span,
                             derived: dateRange(forJournal: journalID))
    }

    /// Durable per-journal multi-voice carry-over (T6 §14, owner decision 5): the
    /// journal's most recently captured non-trashed entry decides. Derived from
    /// `allEntries` — the same collection `dateRange(forJournal:)` reads — so it costs
    /// nothing beyond the scan the library already does, and it re-publishes whenever
    /// that scan lands.
    ///
    /// Deliberately **auto-enabling**, and the recorded divergence from the 2026-08-02
    /// backdate rule (design §2): a wrong voice attribute is visible and editable in the
    /// T7 editor, where a wrong backdate is a quiet data error.
    ///
    /// The tiebreak the design leaves open is "most recently captured", so trashing a
    /// journal's latest entry moves carry-over to the next-latest. That is a coherent
    /// reading of the journal's durable state, not an accident.
    func lastMultiVoice(forJournal journalID: String) -> Bool {
        Self.mostRecentlyCaptured(allEntries.filter { $0.journalID == journalID }, limit: 1)
            .first?.multiVoice ?? false
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

    /// The current row for `captureID`, from the last scan — **independent of
    /// `journalScope`** (issue #32). `nil` means the capture is in none of the three
    /// lists: never scanned, or permanently deleted.
    ///
    /// Scope-independence is the whole point. This resolves a pushed navigation
    /// destination, and the ids that get pushed do not come from `items` alone: the
    /// capture screen's recents strip is built from `allEntries`, so a recent filed in
    /// another journal used to resolve nil and push a blank page, as did an entry moved
    /// out of the active filter while its detail screen was open.
    func item(_ captureID: String) -> EntryListItem? {
        items.first { $0.captureID == captureID }
            ?? allEntries.first { $0.captureID == captureID }
            ?? trashed.first { $0.captureID == captureID }
    }

    // MARK: - Entry edits (detail screen)

    /// Reassign an entry's journal. `nil` files it as unfiled. Returns `false` (and
    /// leaves the sidecar untouched) when the store throws — an unreadable/undecodable
    /// `entry.json`, or a write that fails on disk. The move never happened silently
    /// either way: the caller decides whether to tell the owner.
    @discardableResult
    func moveEntry(_ captureID: String, toJournal journalID: String?) async -> Bool {
        let succeeded: Bool
        do {
            _ = try await entryMetadataStore.update(captureID: captureID) { $0.journalID = journalID }
            succeeded = true
        } catch {
            succeeded = false
        }
        await rescan()
        return succeeded
    }

    /// Set, change, or clear (`date == nil`) the backdate. `precision` is ignored when
    /// clearing — `EntryMetadata.effectivePrecision` is meaningless without a date, so
    /// there is nothing to reset it to. Returns `false` on a store failure OR when
    /// `EntryMetadata.setOriginalDate` refuses a future date — both are genuine "did not
    /// happen" outcomes now that `EntryMetadataStore.setOriginalDate` (T7 §7.1 nit) stops
    /// discarding that Bool and logs the rejected attempt instead. See `moveEntry` for
    /// the store-failure half.
    @discardableResult
    func setBackdate(_ captureID: String, to date: Date?, precision: DatePrecision = .day) async -> Bool {
        let calendar = Calendar.gregorianCurrent
        let partial = date.map { PartialDate(from: $0, precision: precision, calendar: calendar) }
        let succeeded: Bool
        do {
            succeeded = try await entryMetadataStore.setOriginalDate(partial, captureID: captureID)
        } catch {
            succeeded = false
        }
        await rescan()
        return succeeded
    }

    // MARK: - Journal editing (journal-editing IA, Task 6)

    /// Renames a journal. Returns `false` (sidecar untouched) when the store throws — an
    /// empty/whitespace-only name or an id no longer in the registry (deleted underneath
    /// an open editor). Same shape as `moveEntry`: the caller alerts on `false`.
    @discardableResult
    func renameJournal(_ journalID: String, to name: String) async -> Bool {
        guard (try? await journalStore.rename(id: journalID, to: name)) != nil else {
            return false
        }
        await rescan()
        return true
    }

    /// Sets this journal's voice labels wholesale (empty dict clears both). Same
    /// false-on-store-failure shape as `renameJournal`.
    @discardableResult
    func setJournalVoiceLabels(_ journalID: String, labels: [String: String]) async -> Bool {
        guard (try? await journalStore.setVoiceLabels(id: journalID, labels: labels)) != nil else {
            return false
        }
        await rescan()
        return true
    }

    // MARK: - Journal cover (issue #14 part 3)

    /// Sets or replaces a journal's cover image. `imageData` is any ImageIO-decodable
    /// format (JPEG/PNG/HEIC) straight from the camera or `PhotosPicker` — the store
    /// re-encodes and downscales it. Rethrows `JournalCoverError.invalidImage` so the
    /// picker sheet can tell the owner the pick didn't take; every other read of a cover
    /// degrades silently instead.
    func setJournalCover(_ journalID: String, imageData: Data) async throws {
        try await journalCoverStore.write(imageData: imageData, journalID: journalID)
        await rescan()
    }

    func removeJournalCover(_ journalID: String) async {
        await journalCoverStore.delete(journalID: journalID)
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
    ///
    /// Returns `false` (never resurrecting/backdating anything, just reporting the
    /// truth) when the store throws — the device failure this guards against: an
    /// `update` that silently no-ops while the caller believes the entry is trashed.
    @discardableResult
    func trashEntry(_ captureID: String, now: Date = Date()) async -> Bool {
        let succeeded: Bool
        do {
            _ = try await entryMetadataStore.update(captureID: captureID) { $0.trashedAt = now }
            succeeded = true
        } catch {
            succeeded = false
        }
        await rescan()
        return succeeded
    }

    /// Undo. Clearing the tombstone is the whole restore — nothing ever moved. Returns
    /// `false` on a store failure — see `trashEntry`.
    @discardableResult
    func restoreEntry(_ captureID: String) async -> Bool {
        let succeeded: Bool
        do {
            _ = try await entryMetadataStore.update(captureID: captureID) { $0.trashedAt = nil }
            succeeded = true
        } catch {
            succeeded = false
        }
        await rescan()
        return succeeded
    }

    /// "Delete Now" from the Trash view: skip the remaining grace period.
    ///
    /// Re-reads the sidecar and refuses unless it says the entry is trashed, rather than
    /// trusting the row the button was drawn from. The row is a snapshot of a scan that
    /// may be seconds old and, on a synced device later, may describe a restore that has
    /// since landed. The only thing that may cost a recording is what is on disk now.
    ///
    /// **The rename is the deletion.** `stage` moves the directory out of every scanned
    /// tree in one atomic step (#25); the purge that follows only reclaims bytes. So this
    /// returns `true` once the rename lands even if the purge fails — the entry is gone
    /// from the library and cannot come back, and a purge failure retries at the next
    /// launch. The alert on `false` now means exactly one thing: the entry is still there.
    @discardableResult
    func deleteEntryPermanently(_ captureID: String) async -> Bool {
        guard let metadata = try? await entryMetadataStore.read(captureID: captureID),
              metadata.isTrashed else { return false }
        let remover = self.remover
        let staged = await Task.detached(priority: .userInitiated) { () -> Bool in
            do { _ = try remover.stage(captureID: captureID) } catch { return false }
            _ = remover.purge()
            return true
        }.value
        await rescan()
        return staged
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

    // MARK: - Revision promotion (T6c)

    /// The launch pass: promote every capture's `live.jsonl` into revision zero, once.
    /// Called fire-and-forget from `CaptureScreenModel.bootstrap()`, in the same spot
    /// `sweepTrash()` is — after the first scan has published, and BEFORE the sweep, so
    /// a corpus pass never contends with a purge over the same directories. Guarded so
    /// a second `bootstrap()` (interruption resume, a second window) never re-walks the
    /// whole corpus; `promoteIfNeeded` is also individually idempotent
    /// (`.skippedAlreadyPromoted`), so this guard is a cost saver, not a correctness one.
    func promoteCorpusOnce() async {
        guard !corpusPromotionRan else { return }
        corpusPromotionRan = true
        _ = await revisionStore.promoteCorpus()
    }

    /// Thin passthrough for the entry-open call site (`EntryDetailView.refresh()`):
    /// promote before reading, so a capture opened for the first time since finalize
    /// shows canonical text rather than waiting for the next corpus pass.
    @discardableResult
    func promoteIfNeeded(_ captureID: String) async -> TranscriptRevisionStore.PromotionOutcome {
        await revisionStore.promoteIfNeeded(captureID: captureID)
    }

    /// The launch pass (T7 Task 3 fix round 2, owner ruling): stamp every promoted
    /// capture's `head.json` with the size fingerprint fix round 1's trust condition
    /// requires — without this, Task 3's whole win reaches no entry that existed
    /// before this fix shipped, since `persistHead`'s only other caller (`append`)
    /// never runs again once a chain exists. Called fire-and-forget from
    /// `CaptureScreenModel.bootstrap()`, same shape as `promoteCorpusOnce()`, placed
    /// right after it and BEFORE `closeStaleDraftsOnce()` — a capture must be promoted
    /// before its head is worth stamping (an unpromoted capture has no chain, so
    /// `stampUnstampedHeads` skips it outright regardless of ordering here, but
    /// stamping before promotion would just mean re-walking it a second time this
    /// same launch once promotion lands). `stampUnstampedHeads` is itself per-capture
    /// idempotent (a no-op once trustworthy), so this guard is a cost saver, not a
    /// correctness one.
    func stampUnstampedHeadsOnce() async {
        guard !headStampRan else { return }
        headStampRan = true
        await revisionStore.stampUnstampedHeads()
    }

    /// The launch pass (T7 prereq #41): close every capture's stale draft (rule 9,
    /// §4.6), so an edit abandoned mid-sitting on a prior session is recovered into a
    /// real revision rather than left dangling in `draft.json` forever. Called
    /// fire-and-forget from `CaptureScreenModel.bootstrap()`, same shape as
    /// `promoteCorpusOnce()` and placed right after it in source order — after
    /// promotion, before the sweep.
    func closeStaleDraftsOnce() async {
        guard !staleDraftsClosedRan else { return }
        staleDraftsClosedRan = true
        await revisionStore.closeStaleDrafts(now: Date())
    }

    /// Thin passthrough for the entry-open call site (`EntryDetailView.refresh()`, T7
    /// prereq #41): close THIS capture's stale draft, if any, before the transcript read
    /// that follows it — a recovered edit must be visible in the text the screen shows
    /// immediately, not only after the next launch's corpus-wide pass.
    @discardableResult
    func closeStaleDraftIfNeeded(_ captureID: String) async -> String? {
        await revisionStore.closeStaleDraftIfNeeded(captureID: captureID, now: Date())
    }

    /// Cheap, `nonisolated` existence check for this capture's `draft.json` — no actor
    /// hop (T7 prereq #41, fix round 1, Important 2). `capturesRoot` is itself
    /// `nonisolated let`, so this reads straight off disk without touching
    /// `revisionStore`'s actor at all.
    nonisolated func hasDraft(_ captureID: String) -> Bool {
        TranscriptRevisionStore.draftExists(capturesRoot: capturesRoot, captureID: captureID)
    }

    /// The entry-open pre-read sequence (`EntryDetailView.refresh()`, T7 prereq #41,
    /// fix round 1: Important 1 + Important 2 share one fix, per review ruling).
    ///
    /// A draft-free capture — the overwhelmingly common case — takes the `hasDraft`
    /// fast path and returns `false` immediately with NO actor hop, preserving the
    /// exact non-blocking property the T6c comment on the promote-after-read call in
    /// `EntryDetailView.refresh()` already defends: an entry opened during the launch
    /// corpus walk must never queue behind it.
    ///
    /// Only when a draft exists do we pay the actor cost, and then order matters:
    /// `promoteIfNeeded` MUST run before `closeStaleDraftIfNeeded`. Closing a stale
    /// draft mints a `.userEdit` revision, and `promoteIfNeeded` unconditionally skips
    /// (`.skippedAlreadyPromoted`) the moment ANY canonical file exists — so closing
    /// first would make that `.userEdit` permanently block the `.machineLive` baseline
    /// from ever entering the chain (Important 1, probe-confirmed). Promoting first
    /// matches launch's own order (`promoteCorpusOnce()` then `closeStaleDraftsOnce()`).
    ///
    /// Returns whether the actor was hopped — purely so this ordering is directly
    /// observable by a test without relying on timing.
    @discardableResult
    func recoverStaleDraftBeforeRead(_ captureID: String) async -> Bool {
        guard hasDraft(captureID) else { return false }
        await promoteIfNeeded(captureID)
        await closeStaleDraftIfNeeded(captureID)
        return true
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
    ///
    /// Always asks for attribution (`AttributionMode.compute`) — this is the detail
    /// screen's one path, the only consumer that renders paragraphs, unlike
    /// `LibraryScanner.transcriptSummary`'s `.skip` default (hazard 1).
    nonisolated func transcript(for captureID: String) async -> EntryTranscript {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                           captureID: captureID)
            let facts = Self.manifestFacts(captureDirectory: directory)
            return EntryTranscriptLoader.load(
                captureDirectory: directory,
                expectedRecords: facts.committedRecords,
                attribution: .compute(sampleRate: facts.sampleRate))
        }.value
    }

    /// The two manifest facts the transcript read needs, off one decode.
    private struct ManifestFacts {
        /// `TranscriptRef.committedRecords`, or nil when there is no manifest, no ref,
        /// or the manifest did not decode — all three mean "we cannot say whether the
        /// tail is short", which is exactly `Completeness.unknown`.
        var committedRecords: Int?
        /// `Manifest.format.sampleRate`, or a 48kHz fallback when the manifest is
        /// missing or undecodable. The rate only scales the marker snap window, and a
        /// missing manifest already means a capture that never closed cleanly — the
        /// fallback costs nothing this path wasn't already degrading past.
        var sampleRate: Double
    }

    private nonisolated static func manifestFacts(captureDirectory: URL) -> ManifestFacts {
        let url = SegmentLayout.manifestURL(captureDirectory: captureDirectory)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: data)
        else { return ManifestFacts(committedRecords: nil, sampleRate: 48_000) }
        return ManifestFacts(committedRecords: manifest.transcript?.committedRecords,
                             sampleRate: Double(manifest.format.sampleRate))
    }

    // MARK: - Chain snapshot (T7 Task 2)

    /// The editor's read model — also the revision-history panel's and the storage
    /// stat's (T7 Task 2, #39). One new disk read, deliberately kept separate from
    /// `transcript(for:)`/`EntryTranscript`: the row/scan path must never pay for it
    /// (#40.1, Task 3), so this is called only from a user action (editor open, history
    /// panel, diagnostics) — never from `LibraryScanner` or row construction.
    ///
    /// `nonisolated async`, the same shape as `transcript(for:)`: the read itself
    /// (`EntryChainSnapshot.build`) is synchronous and needs no actor of its own — every
    /// primitive it touches (`TranscriptRevisionStore.listing`, `EntryMetadataStore
    /// .read(url:)`, `TranscriptChain.*`) is `nonisolated static`/pure — so this
    /// deliberately does NOT hop onto `revisionStore`'s actor. `Task.detached` only
    /// keeps the handful of small file reads off whatever actor/thread the caller is on.
    nonisolated func chainSnapshot(for captureID: String) async -> EntryChainSnapshot {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                           captureID: captureID)
            return EntryChainSnapshot.build(captureDirectory: directory)
        }.value
    }

    // MARK: - Editor draft passthroughs (T7 Task 4)

    /// The un-edited machine transcript, for the editor's degraded-chain refusal (T7 plan
    /// ruling Q5): a chain we cannot read still gets its `live.jsonl` text offered
    /// read-only, labeled as the machine transcript rather than as "the transcript".
    ///
    /// Reads `live.jsonl` and NOTHING else (`EntryTranscriptLoader.machineLiveText`). It used
    /// to ride `transcript(for:)`, which was wrong in a way only a two-revision fixture could
    /// show (Gate A finding I3): that path prefers the canonical chain's `current` and falls
    /// back to the log only when no revision is readable, so a chain with one damaged file and
    /// one readable `.userEdit` returned the owner's OWN EDIT under this heading.
    ///
    /// `nil` for an absent or unreadable log, and for a readable log with nothing in it:
    /// the editor has nothing to offer in any of those cases, and an empty box under a
    /// "here is the machine transcript" heading would claim otherwise.
    nonisolated func machineTranscript(for captureID: String) async -> String? {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            EntryTranscriptLoader.machineLiveText(
                captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                                 captureID: captureID))
        }.value
    }

    /// `transcript/draft.json` as it is on disk right now — the editor's only way to notice
    /// that a `refresh()`-driven `closeStaleDraftIfNeeded` closed the draft beneath an open
    /// editing session. Calls the store's own shared `readDraft` primitive rather than a
    /// second copy of the absent/undecodable-collapse rule.
    nonisolated func openDraft(for captureID: String) async -> TranscriptDraft? {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                           captureID: captureID)
            return TranscriptRevisionStore.readDraft(captureDirectory: directory)
        }.value
    }

    /// Thin passthrough. Deliberately does NOT `rescan()`: this runs on every debounce fire
    /// (every 2 s of typing), and a whole-corpus scan per keystroke-burst is exactly the
    /// cost `chainSnapshot` was kept off the scan path to avoid. The library rows are
    /// refreshed once, by the detail screen, after the editor closes.
    func writeDraft(captureID: String, text: String, now: Date) async throws {
        try await revisionStore.writeDraft(captureID: captureID, text: text, now: now)
    }

    /// Thin passthrough. Returns the minted revision id, or `nil` when the draft matched
    /// `current` and was simply deleted (design §2.5) — the editor treats both as success;
    /// only a THROW means nothing was saved.
    @discardableResult
    func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) async throws -> String? {
        try await revisionStore.closeDraft(captureID: captureID, reason: reason, now: now)
    }

    // MARK: - Revision history passthrough (T7 Task 8)

    /// Thin passthrough — the revision-history panel's revert action. Every guard
    /// (missing/trashed capture, §15b.15 degraded-chain refusal, `.notMachineLineage`)
    /// lives once, inside `TranscriptRevisionStore.revert`, never duplicated here.
    /// Returns the minted revision's id.
    @discardableResult
    func revert(captureID: String, toRevisionID: String, now: Date) async throws -> String {
        try await revisionStore.revert(captureID: captureID, toRevisionID: toRevisionID, now: now)
    }
}

/// The editor writes through this model, never straight to `TranscriptRevisionStore` — one
/// store instance per file, app-wide (see `entryMetadataStore`'s own note).
extension LibraryScreenModel: TranscriptEditorStore {}

/// The mark-voices screen writes through this model, never straight to
/// `MarkerCorrectionWriter`/`EntryTranscript.voiceMarkingLayout` — one store instance
/// per file, app-wide. Lives here rather than in `VoiceMarkingModel.swift` because it
/// needs `manifestFacts`, `private` to this file.
extension LibraryScreenModel: VoiceMarkingStore {
    nonisolated func voiceMarkingLayout(for captureID: String) async -> EntryTranscript.VoiceMarkingLayout {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            let facts = Self.manifestFacts(captureDirectory: directory)
            return EntryTranscript.voiceMarkingLayout(captureDirectory: directory, sampleRate: facts.sampleRate)
        }.value
    }

    /// `current`'s own spans — the exact frame source `addVoiceBoundary` anchors to.
    /// `nil` when there is no readable current revision. Was `MarkerCorrectionStore
    /// .currentSpans` before that protocol was retired (T7 Mark Voices, issue #56,
    /// Task 6); kept as a private helper here since only this extension calls it now.
    private nonisolated func currentSpans(for captureID: String) async -> [TranscriptSpan]? {
        let capturesRoot = self.capturesRoot
        return await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            guard let chain = TranscriptRevisionStore.loadChain(captureDirectory: directory),
                  let current = TranscriptChain.current(TranscriptChain.ordered(chain.revisions))
            else { return nil }
            return current.spans
        }.value
    }

    /// Re-reads `current`'s spans rather than trusting a caller-supplied array — the
    /// screen's own `spans` could be one action stale (another marking session, or the
    /// editor, changed the chain since this screen last opened), and writing against a
    /// stale span array could anchor to the wrong frame silently.
    @discardableResult
    func addVoiceBoundary(atSpanIndex spanIndex: Int, voice: String, captureID: String) async throws -> Int64 {
        guard let spans = await currentSpans(for: captureID) else {
            throw MarkerCorrectionWriter.BoundaryAddError.noUsableBounds
        }
        let capturesRoot = self.capturesRoot
        return try await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            return try MarkerCorrectionWriter.addVoiceBoundary(atSpanIndex: spanIndex, spans: spans,
                                                                voice: voice, captureDirectory: directory)
        }.value
    }

    /// No span prerequisite (see `MarkerCorrectionWriter.addOpeningVoice`'s own doc
    /// comment) — writes unconditionally at frame 0.
    func addOpeningVoice(voice: String, captureID: String) async throws {
        let capturesRoot = self.capturesRoot
        try await Task.detached(priority: .userInitiated) {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            try MarkerCorrectionWriter.addOpeningVoice(voice: voice, captureDirectory: directory)
        }.value
    }
}
