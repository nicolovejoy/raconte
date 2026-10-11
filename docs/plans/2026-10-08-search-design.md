# Search (2026-10-08) — design (#194)

Brainstormed 2026-10-08 with mockups; owner rulings restated inline. Research input requested
from prompt-lab in `~/src/.handoff/raconte-prompt-lab.md` (2026-10-08 entry) — any answer
that contradicts a choice here is folded in before the plan runs.

## What

Full-text search over the owner's transcripts, on iOS and macOS, with highlighted snippets,
scoped by journal and date range, and a tap that lands inside the entry on the match. Phase 1
of the "global search and filtered by journal, date, etc. eventually" ask.

Not in scope: searching images, audio or revision history; stemming beyond prefix matching;
relevance ranking (results are in date order); saved searches; a search field on every
screen; entry descriptions (no such field exists today — #194 said "probably"; add to the
index when it does).

## Owner rulings (2026-10-08)

1. **A Search place in the sidebar**, low in the list near Trash and About — "doesn't need to
   be super prominent". Not a field at the top of the sidebar, not per-journal fields.
2. **Indexed text:** the canonical transcript; an entry with no canonical revision is indexed
   from its committed segment transcript so everything recorded is findable.
3. **Trash excluded** from results.
4. **Results:** a flat list, date · journal, one highlighted snippet per entry. **Tap opens the
   entry scrolled to the match, matches highlighted, with previous/next.**
5. **Filters as chips under the field:** journal and date range for now, each chip a menu;
   more chips later.
6. **Journal chip defaults to the last-viewed journal** (`CurrentJournal`), All journals one
   tap away.

Mine, not asked: search is as-you-type; every term is prefix-matched and all terms must
match; a quoted phrase is honoured; diacritics are folded. Results sort by effective date
descending, newest first, not by relevance — the owner's mental model is the journal, not a
search engine. In-entry match positions are computed over the loaded transcript, not read
from the index.

## Approach chosen

**SQLite FTS5 through the system `libsqlite3`, driven by GRDB.swift 7.** Verified on this
laptop (macOS 27, SQLite 3.54.0): `ENABLE_FTS5`, `unicode61 remove_diacritics 2`, `snippet()`
and `highlight()` all present. GRDB brings `FTS5Pattern(matchingAllPrefixesIn:)` (user input
never reaches the FTS query parser raw), connection and statement lifetimes under Swift 6
strict concurrency, and migrations if the index ever grows. It is the project's first SPM
dependency; XcodeGen `packages:` declares it, CI resolves it. Rejected: raw `import SQLite3`
(own the escaping and lifetimes for one table), Core Spotlight (no snippets or offsets;
transcript text leaves the sandbox), an in-memory index (decodes every canonical body on
every launch — the cost `head.json` exists to avoid).

The index is a **disposable derivative of the archive**. Files stay ground truth; deleting
the index file loses nothing but a rebuild.

### Research reply, folded in 2026-10-10

prompt-lab answered on 2026-10-08 (`~/src/.handoff/raconte-prompt-lab.md`), after this document
and the plan were committed. Folded in by the session that ran the plan; the owner has not
reviewed this section.

- **It recommended raw `SQLite3` in one actor, not GRDB.** GRDB stays: CLAUDE.md's Stack already
  names it, both documents are written for it, and the reply itself lists "would rather not own
  C-pointer code under strict concurrency" as a reason to pick it. The SQL carries over unchanged
  if this is reversed; the cost is the inside of `SearchIndex` and one block of `project.yml`.
  GRDB is pinned by exact version, because `Package.resolved` sits in the gitignored project.
- **Shared rowids.** An `UNINDEXED` FTS column has no index, so deleting an FTS row by
  `captureID` scans every stored transcript. The state table owns an integer id and the FTS row
  uses it as its `rowid`:

```sql
CREATE TABLE entry_index_state(
    id INTEGER PRIMARY KEY AUTOINCREMENT, captureID TEXT NOT NULL UNIQUE, fingerprint TEXT NOT NULL);
-- entry_text.rowid == entry_index_state.id; captureID stays in entry_text only to be SELECTed
```

- **Schema version.** The reply asked for `PRAGMA user_version` and delete-on-mismatch. GRDB's
  migration table is that version; a schema or tokenizer change is a migration that drops both
  tables, after which the empty fingerprints rebuild everything.
- **A second plaintext copy.** The `search/` directory is excluded from backup. The archive sets
  no explicit file protection, so the index inherits the same platform default. Nothing about
  it syncs or is exported.
- **Rebuild time.** Each reconcile that changes anything logs its counts and elapsed
  milliseconds at `.notice`; PR 1's smoke reads the first one.
- **Tokenizer vs highlighter.** `unicode61` splits `l'école` at the apostrophe. The in-entry
  highlighter therefore splits on non-letter-non-number too, not on ICU word boundaries, or a
  French elision would be found by the list and shown as `0 of 0` in the entry.
- **Not taken, deferred to #194's follow-ups:** English stemming (`porter`), `-excluded` words
  and `OR`, per-field columns with `bm25()` weighting (there is one field today), relevance
  order (results stay in date order — the owner's model is the journal).
- **Also added by the same pre-flight:** a finished reconcile re-runs the visible query (typing
  during "Indexing…" no longer strands "No matches"); the "Search is unavailable" state below
  has a task.

## Architecture

### `SearchIndex` — the store (new, `Raconte/Search/SearchIndex.swift`, actor)

One database at `AppContainer.root()/search/index.sqlite` (never inside `captures/`). Schema:

```sql
CREATE VIRTUAL TABLE entry_text USING fts5(
    captureID UNINDEXED, body, tokenize = 'unicode61 remove_diacritics 2');
CREATE TABLE entry_index_state(captureID TEXT PRIMARY KEY, fingerprint TEXT NOT NULL);
```

```swift
actor SearchIndex {
    init(databaseURL: URL) throws         // opens or creates; a corrupt file is deleted and recreated
    func fingerprints() async throws -> [String: String]   // captureID → fingerprint
    func upsert(captureID: String, fingerprint: String, body: String) async throws
    func remove(captureIDs: [String]) async throws
    func search(_ query: SearchQuery) async throws -> [SearchHit]   // in index order; caller sorts
}
struct SearchHit: Sendable, Equatable { var captureID: String; var snippet: SearchSnippet }
```

Only `captureID` and `body` live in the index. Journal, date and trash are facts the library
already holds for every entry (`LibraryScreenModel.allEntries`), so filtering happens in
Swift after the FTS query — the index never goes stale on a metadata edit, and a restored
entry is findable the moment it leaves the trash.

### `SearchQuery` + `SearchSnippet` — pure (new, `Raconte/Search/SearchQuery.swift`)

```swift
struct SearchQuery: Sendable, Equatable {
    var text: String
    /// nil when the typed text has no searchable token (empty, punctuation only).
    var pattern: FTS5Pattern? { FTS5Pattern(matchingAllPrefixesIn: text) }
}
struct SearchSnippet: Sendable, Equatable {
    /// Plain text with the match runs, from FTS5 `snippet()` with private-use markers.
    var text: String
    var matches: [Range<String.Index>]
    static func parse(_ marked: String) -> SearchSnippet   // markers "\u{E000}"…"\u{E001}"
    var attributed: AttributedString                       // matches get `.backgroundColor`
}
```

Quoted phrases: `FTS5Pattern(matchingAllPrefixesIn:)` tokenises, so `"new strings"` becomes
two prefix tokens, not a phrase. When the WHOLE trimmed input is one double-quoted string,
`SearchQuery.pattern` uses `FTS5Pattern(matchingPhrase:)` on the inside instead. Mixed input
(a quoted part plus loose words) is prefix-matched as a whole — combining the two needs
GRDB's database-validated `makeFTS5Pattern(rawPattern:)`, not worth the plumbing in phase 1.
A lone or unbalanced quote is ordinary text (the tokeniser drops it).

### `SearchIndexer` — reconciliation (new, `Raconte/Search/SearchIndexer.swift`, actor)

Keeps the index in step with the files after every library scan.

```swift
actor SearchIndexer {
    init(index: SearchIndex)
    /// Compare each entry's fingerprint with the index; re-index the changed, drop the gone.
    func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report
    struct Entry: Sendable { var captureID: String; var directory: URL; var expectedRecords: Int? }
    struct Report: Sendable, Equatable { var indexed: Int; var removed: Int; var unchanged: Int; var failed: Int }
}
```

- **Fingerprint** (pure, `SearchFingerprint.compute(directory:) -> String`): the
  `head.json` current revision id + `characterCount` when `TranscriptRevisionStore.validatedHead`
  returns one; otherwise `live.jsonl`'s byte size and modification date. O(1) per entry — no
  body is decoded unless the fingerprint moved. Trashed entries are indexed too (ruling 3 is
  enforced at query time); a swept entry's id is absent from the scan and is removed.
- **Body** (`EntryTranscriptLoader.fullText(captureDirectory:expectedRecords:) -> String?`,
  new static on the existing loader): the canonical current revision's spans joined, else the
  consolidated committed text — the same two sources `load(…, attribution: .compute)` uses for
  `text`, without the attribution pass. `nil` or empty → the entry is removed from the index
  (nothing to find) and counted `failed` only when the directory exists and the read errored.
- **Trigger:** `LibraryScreenModel.rescan()` already runs after every local write and every
  inbound sync batch (`SyncCoordinator.localStoreDidChange`). After it publishes, it hands
  `allEntries + trashed` (as `SearchIndexer.Entry`s) to the attached `SearchReconciling`
  (`attach(searchReconciler:)`), coalescing: one reconcile at a time, any number of rescans
  during a run collapse into exactly one follow-up. The model exposes
  `private(set) var searchIndexing: Bool` for the screen's footer.
- **Cold start / missing file:** `fingerprints()` is empty, so the first reconcile indexes
  everything. At dogfood scale (hundreds of entries) this is seconds, in the background.

### Search screen (new, `Raconte/Search/UI/SearchView.swift`, `SearchScreenModel.swift`)

`Place.search` joins the sidebar between Trash and About (`sidebar.search`), on both
platforms. `ContentView` routes it to `SearchView(model: services.search)`.

- Field: `.searchable(text:isPresented:placement:)` on the screen's navigation stack — nav-bar
  field on iPhone, toolbar field on Mac — with `searchFocused` so the field has focus on
  arrival. Typing debounces 150 ms and queries; an empty field shows the chips and a one-line
  hint, no results.
- Chips row under the field: **journal** (`Menu`: All journals, then `journals.displayOrdered`;
  default `CurrentJournal.resolve(in:)` ?? All) and **date** (`Menu`: Any time, This year, Last
  year, Custom…; Custom presents a sheet with two `PartialDate` fields reusing
  `JournalSpanEditor`'s field, compared with the exclusive-upper-bound rule from
  `JournalSpan`). Identifiers `search.chip.journal`, `search.chip.date`.
- Results: `List` of `SearchResultRow` — date line (`EntryListItem` effective date, the row's
  existing formatting), journal name, attributed snippet. `search.result.<captureID>`. Sorted
  by effective date descending. Footer "Indexing…" while `searchIndexing`; "No matches" state.
- Tap: `router.openEntry(captureID, highlight: SearchHighlight(terms:))` — the detail path
  gains the highlight.
- `SearchScreenModel` (`@MainActor @Observable`) holds `text`, `journalScope`, `dateFilter`,
  `results: [SearchResult]`, and does the filter join: hits × `library.allEntries` by
  captureID (which drops trash by construction), then journal and date predicates, then sort.

### Viewer highlight (modify `EntryDetailView`, `LibraryDestination`)

`LibraryDestination.entry(String)` becomes `entry(String, highlight: SearchHighlight? = nil)`
(`struct SearchHighlight: Hashable, Sendable { var terms: [String] }`). Every existing
`.entry(id)` call site compiles unchanged; `case .entry = last` still matches.

- `TranscriptHighlighter` (pure, `Raconte/Search/TranscriptHighlighter.swift`):
  `matches(in text: String, terms: [String]) -> [Range<String.Index>]` — case- and
  diacritic-insensitive prefix matches at word starts, the same rule the index applies, so
  what the list promised the entry shows; `attributed(_ text: String, matches:, current:) ->
  AttributedString`.
- The prose renders through the highlighter when a highlight is present: the single-`Text`
  branch and the per-paragraph branch both. Current match gets the stronger colour.
- A match bar above the prose: `‹ 1 of 4 ›` (`detail.search.previous`, `detail.search.next`,
  `detail.search.count`). Next/previous move the current match; the view scrolls the
  containing paragraph into view via `ScrollViewReader` (paragraph granularity — SwiftUI
  cannot scroll to a character; stated, not hidden). On arrival the first match is current and
  scrolled to. The single-`Text` branch scrolls to the top of the prose.
- Leaving the entry (pop, pager to another entry) clears the highlight: `page(to:)` pushes
  `.entry(id)` with no highlight.

### Mac

Same screen. `.searchable` lands in the toolbar; chips render under it; results in the
detail column, entry opens in place. ⌘F in the Search place focuses the field
(`RaconteCommands`), nothing else changes.

## Error handling

- Index open fails (disk full, corrupt): `SearchIndex.init` deletes and recreates once; a
  second failure leaves `services.search` with `index == nil`, the Search screen shows
  "Search is unavailable" with the error's `localizedDescription`, and the app runs as today.
  Logged at `.notice`.
- Reconcile errors per entry are counted in `Report.failed` and logged `.notice` with the
  captureID; the run continues.
- A query that produces no pattern (empty, punctuation) shows the hint, never an error.
- An entry opened from a result whose transcript no longer contains the terms (edited since
  the scan) shows the bar as `0 of 0` and the prose unhighlighted — no crash, no stale highlight.

## Testing

Unit (`RaconteTests`, pure where possible, a temp directory for the index):
- `SearchQueryTests`: prefix pattern for two terms; punctuation-only → nil; balanced quotes →
  phrase + prefix; unbalanced quote → text.
- `SearchSnippetTests`: marker parse yields the ranges; no markers → empty matches; marker at
  string end.
- `SearchIndexTests`: upsert then search finds by prefix and with a diacritic folded
  ("etaient" finds "étaient"); remove drops; a second `upsert` with the same captureID
  replaces, not duplicates; corrupt file recreated; `fingerprints()` round-trips.
- `SearchFingerprintTests`: canonical head present → id+count; absent → live size+mtime;
  editing the revision moves it; touching an unrelated file does not.
- `SearchIndexerTests`: three entries → first reconcile indexes 3; second reconcile with no
  change indexes 0, unchanged 3; one entry edited → indexes 1; one directory removed →
  removed 1; an unreadable directory → failed 1 and the other two still indexed.
- `EntryTranscriptLoaderFullTextTests`: canonical present → spans joined; absent → consolidated
  committed text; both absent → nil.
- `SearchScreenModelTests`: trash excluded; journal scope filters; date range uses the
  exclusive upper bound (an entry on the last day of the range is in); sort newest first;
  default journal scope follows `CurrentJournal`.
- `TranscriptHighlighterTests`: word-start prefix, case and diacritic folding, no mid-word
  hit, multiple terms, current index styling differs.
- `TypeScaleTests` paper-screen scan: `SearchView.swift` added to `paperScreenFiles`.
- `EntitlementsParityTests` unaffected; `project.yml` gains the GRDB package — a test pins
  that `Raconte.xcodeproj` references it only through `project.yml` (no hand edits).

UI (`RaconteUITests`, simulator, CI): with `RACONTE_UITEST_SEED_ENTRY` (canonical text
"the machine heard these words"): `openPlace(app, "sidebar.search")` → type "heard" →
`search.result.<seeded id>` exists → tap → `detail.search.count` reads "1 of 1" → the prose's
accessibility value contains "heard". Second test: type "zzzz" → "No matches". Third: journal
chip set to a journal the seeded entry is not in → no result; back to All → result.

Every test spec gets a RED proof before it is reported green.

## Phasing

Three PRs, each smoke-tested before the next starts:
- **A1 — index core:** GRDB dependency, `SearchIndex`, `SearchQuery`/`SearchSnippet`,
  `SearchFingerprint`, `fullText`, `SearchIndexer`, model trigger. No UI; the only visible
  change is the `search/index.sqlite` file appearing. Smoke: file exists after launch; About
  unchanged.
- **A2 — Search place:** `Place.search`, screen, chips, results, tap opens the entry at the
  top (no highlight yet). Smoke on Mac and iPhone.
- **A3 — in-entry highlight:** `SearchHighlight`, `TranscriptHighlighter`, match bar,
  scroll-to-paragraph.

## Not touched

`LibraryScanner`'s read path and `head.json`'s shape; `TranscriptRevisionStore`'s write path
(the index is read-only against the archive); sync records (nothing about search syncs — each
device builds its own index); the capture screen.
