# Search (#194) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full-text search over transcripts with highlighted snippets, journal and date filters, and a tap that opens the entry on the match — three PRs (A1 index core, A2 Search place, A3 in-entry highlight).

**Architecture:** An FTS5 index (`search/index.sqlite`, via GRDB) that is a disposable derivative of the file archive, reconciled after every library scan by per-entry fingerprints; a `Place.search` screen whose model joins FTS hits against `LibraryScreenModel.allEntries` for journal/date/trash filtering; a `SearchHighlight` carried on `LibraryDestination.entry` that the detail view renders with a pure `TranscriptHighlighter`.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (iOS 26 / macOS 26), GRDB.swift 7.x (SPM, first dependency), system SQLite FTS5, XCTest.

**Spec:** `docs/plans/2026-10-08-search-design.md`

## Global Constraints

- `project.yml` is the source of truth; after any new file or package: `xcodegen generate`. New source files AND new test files both need the regen (CLAUDE.md, memory `new-test-file-needs-xcodegen-regen`).
- Unit suite: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="$PWD/Raconte/Raconte-nocloud.entitlements" test` — never `CODE_SIGNING_ALLOWED=NO`. (Path made absolute in Task 1: with a package in the build the relative form fails on GRDB's bundle target.) The owner's `/Applications/Raconte.app` must not be running. Use `-only-testing:RaconteTests/<Class>` while iterating; the full suite once per task. Dispatch with `timeout: 600000`.
- ~~UI suite is CI-only on this laptop (CoreSimulator out of date)~~ **Amended 2026-10-10:** the simulator works on this laptop again — the pre-flight ran `AboutUITests` green on iPhone 17 (iOS 26.5). Run the UI classes you add or touch locally, one class per call: `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .superpowers/dd -only-testing:RaconteUITests/<Class> test`, foreground, `timeout: 600000`. UI RED proofs are local. The WHOLE UI suite is still judged by CI (it exceeds the ten-minute cap locally); read `Executed N tests` from the job log (`gh api --allow-escape-sequences repos/nicolovejoy/raconte/actions/jobs/<id>/logs | grep -a Executed`), never from a commit message.
- **Unit baselines:** `main` after #198 = **2336** executed, 1 skipped in CI (job 114357411506); locally 2336 executed, 0 failures (Task 1's run). Build into `.superpowers/dd` inside the worktree: the pre-flight's probe built into `/private/tmp` and `BuildStampTests.testLoadedImageUUIDFindsARealLoadedMachOImage` failed there and nowhere else.
- Index path `AppContainer.root()/search/index.sqlite` — NEVER under `captures/`.
- Paper screens take a `TypeRole`, never a bare text style or size literal; `SearchView.swift` goes into `RaconteTests/SourceScanning.swift`'s `paperScreenFiles`.
- Never request a presentation in the same transaction that dismisses another; `.sheet` on the screen's outer view, never a `Section`.
- Inbound-sync rule holds: the indexer only READS the archive. It never writes under `captures/` and never fires `noteLocalChange`.
- Logging the owner reads back: `.notice`, not `.info`.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (the session that runs the plan; this line named the authoring session's model before); PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`; PRs end open — merges are Nico's.
- Every test gets a RED proof (stash the production change or assert against the pre-change behaviour) before it is reported green; a test that cannot fail is a plan defect — report it.

### Added by the pre-flight (2026-10-10) — see "Pre-flight amendments" below

- **Stacked, unattended (owner ruling 2026-10-10: "all 3 please").** PR 1 `feat/194-search-index` → base `main`. PR 2 `feat/194-search-place` → base `feat/194-search-index`. PR 3 `feat/194-search-highlight` → base `feat/194-search-place`. Wherever a phase heading says "off `main` after PR N merges", read "stacked on PR N's branch". All three PRs end open; Nico merges them in order.
- **Pushes and PRs are the controller's.** Phase A1's branch is pushed and its PR opened as a draft right after Task 1, so CI proves the GRDB package resolves on the runners while Tasks 2–6 proceed; after that each phase is pushed at its close. `pull_request` is the only CI trigger off `main`, so a branch with no PR gets no CI.
- **Never log transcript text, snippet text or the query string.** CaptureIDs, counts and durations only.
- **No `Image` in a macOS `Menu` label** (CLAUDE.md, #69): the chip labels are text-only.
- **Local runs:** every `xcodebuild` call is foreground with `timeout: 600000`, never backgrounded. Never erase, delete or recreate a simulator. Before a macOS test run `pgrep -x Raconte` must print nothing; if the owner's app is running, do not kill it — report BLOCKED.

## Review Focus

1. **Typing fast then deleting to empty** — results must clear and no late query may repaint stale hits over the empty state. Pinned in Task 8 (`SearchScreenModelTests.testResultsForASupersededQueryAreDropped`).
2. **A rescan during a reconcile** (sync lands while indexing) — exactly one more reconcile runs afterwards, never zero, never N. Pinned in Task 6.
3. **An entry edited after it was indexed** — the next scan re-indexes it (fingerprint moved) and the viewer's `0 of 0` state never crashes. Pinned in Tasks 5 and 12.
4. **Diacritics and case** — "etaient" must find "Étaient" in both the index and the in-entry highlighter, or the list promises what the entry cannot show. Pinned in Tasks 3 and 11.
5. **Date filter edge** — an entry dated on the last day of a chosen year is IN that year (exclusive upper bound built from `dateInterval(of:for:).end`). Pinned in Task 8.

## Pre-flight amendments (2026-10-10)

Made by the session that ran the plan, before Task 1, from two sources: the prompt-lab research
reply (`~/src/.handoff/raconte-prompt-lab.md`, 2026-10-08, which landed after this plan was
written — the spec promises to fold it in) and a conflict scan of the plan against itself, the
spec and the code at `9587f639`. The owner has NOT reviewed the written spec or this plan; the
three PRs are his first look. Each amendment is repeated inside the task it changes, marked
**Amendment**, and wins over older text in that task where they differ.

1. **GRDB stays** (reply recommended raw `SQLite3`). CLAUDE.md's Stack names GRDB, both documents
   are written for it, and the reply's own exception applies (not owning C-pointer code under
   strict concurrency). Costs if wrong: the inside of `SearchIndex` and `project.yml`.
2. **GRDB is pinned with `exactVersion`** (Task 1). `Package.resolved` lives in the gitignored
   generated project, so `from:` would let CI and release builds pick up any new 7.x unreviewed.
3. **Shared rowids** (Task 3, from the reply). `DELETE FROM entry_text WHERE captureID = ?` is a
   full scan of the FTS table per upsert — quadratic on a cold start. The state table owns an
   integer id and the FTS row shares it.
4. **The migrator is the schema version** (Task 3). The reply asked for `PRAGMA user_version`;
   under GRDB the migration table already is one. A schema or tokenizer change is a new
   migration that drops both tables, and the empty fingerprints rebuild everything.
5. **Backup exclusion** (Task 3, from the reply). The index is a second plaintext copy of every
   transcript; its directory is marked `isExcludedFromBackup`, as `StagedRemoval.swift` does.
   File protection: the archive sets none explicitly (grep-verified), so the index inherits the
   same platform default — nothing to add.
6. **Rebuild timing** (Task 5, from the reply). One `.notice` line per reconcile that changed
   anything, with counts and elapsed milliseconds, so the owner's first real run reports it.
7. **Elisions** (Tasks 3 and 11). `unicode61` splits `l'école` at the apostrophe; ICU's
   `.byWords` does not. The Task 11 highlighter as written would show `0 of 0` for a hit the
   list promised (Review Focus 4). The highlighter splits on non-letter-non-number, the rule
   `SearchQuery.terms` already uses; Task 3 pins the index side.
8. **Deterministic fakes** (Tasks 6 and 8). `release()` before the reconcile has parked is a
   no-op and the test then hangs or reads zero calls. Fakes gain `waitForCalls(_:)`; fixed
   sleeps become bounded polls.
9. **The superseded-query test could not fail** (Task 8, Review Focus 1). With a 150 ms
   debounce, `text = "ab"; text = ""` cancels the first query before it runs, so the test
   passes with the generation guard deleted. Rewritten to park a real query, with a hit that
   joins a real entry and a positive control.
10. **Re-query when the index changes** (Tasks 6 and 8). Nothing in the plan re-ran the visible
    query when a reconcile finished: type during "Indexing…" and "No matches" stayed until the
    next keystroke. `LibraryScreenModel.searchIndexRevision` moves per completed pass and
    `SearchScreenModel` observes it.
11. **"Search is unavailable"** (Tasks 8 and 9). The spec's error state had no task.
12. **Task 8 references `SearchView`, which Task 9 creates.** Task 8 lands a stub so the route
    compiles; Task 9 fills it in.
13. **Dropped:** the spec's "test pins that `Raconte.xcodeproj` references GRDB only through
    `project.yml`". The project file is gitignored and generated; there is nothing to pin.
14. **Smoke commands carry no bare backslash** (CLAUDE.md shared conventions): paths are quoted.
15. **Test-count arithmetic moves with the amendments:** A1 +34 unit, A2 +13 unit / +3 UI,
    A3 +10 unit / +1 UI. If a task's report states a different number of tests, the report wins
    and the PR body says why.

---

## Phase A1 — index core (PR 1, branch `feat/194-search-index` off `main`)

### Task 1: GRDB dependency and an FTS5 availability test

**Files:**
- Modify: `project.yml` (top-level `packages:`; `Raconte` target `dependencies:`)
- Create: `RaconteTests/SearchDependencyTests.swift`
- Modify: `.github/workflows/*.yml` only if package resolution fails in CI (read the workflow first; `xcodebuild` resolves SPM packages itself — expect no change)

**Interfaces:**
- Produces: `import GRDB` available to `Raconte` and (via `@testable import Raconte`) to `RaconteTests`.

- [ ] **Step 1: Add the package**

In `project.yml`, after the `options:` block and before `settings:`:

```yaml
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    exactVersion: "7.11.1"
```

**Amendment (pre-flight 2):** pinned with `exactVersion`, not `from:`. `7.11.1` is the release the
research reply confirmed on 2026-10-08 (swift-tools 6.1, no transitive dependencies,
`SQLITE_ENABLE_FTS5` defined). If a newer 7.x exists today, still pin `7.11.1`; if `7.11.1` does
not resolve, pin the newest 7.x that does and say so. Report the resolved version AND its git
revision (from the generated project's `Package.resolved`) so the PR body can state both.

In the `Raconte` target, add:

```yaml
    dependencies:
      - package: GRDB
```

Run `xcodegen generate`. Resolve once: `xcodebuild -resolvePackageDependencies -project Raconte.xcodeproj -scheme Raconte`.

- [ ] **Step 2: Write the failing test**

```swift
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
```

- [ ] **Step 3: Run, expect FAIL to compile before Step 1 / PASS after** — RED proof here is the compile failure with the package absent (`git stash` the `project.yml` change, `xcodegen generate`, observe "no such module 'GRDB'", unstash, regenerate).

- [ ] **Step 4: Run the full unit suite** — expect the baseline +1. Record the baseline FIRST from main's latest code-carrying CI job log.

- [ ] **Step 5: Commit** — `build(#194): add GRDB 7 for the FTS5 search index; pin FTS5 availability`

### Task 2: `SearchQuery` and `SearchSnippet` (pure)

**Files:**
- Create: `Raconte/Search/SearchQuery.swift`
- Create: `RaconteTests/SearchQueryTests.swift`

**Interfaces:**
- Produces: `SearchQuery(text:).pattern: FTS5Pattern?`; `SearchQuery.terms: [String]` (the tokens the highlighter will use); `SearchSnippet.parse(_:)`, `SearchSnippet.openMarker`/`closeMarker`, `SearchSnippet.attributed`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import GRDB
@testable import Raconte

final class SearchQueryTests: XCTestCase {
    func testTwoWordsBecomePrefixTokens() {
        let pattern = SearchQuery(text: "new str").pattern
        XCTAssertEqual(pattern?.rawPattern, "\"new\"* \"str\"*")
    }
    func testPunctuationOnlyHasNoPattern() {
        XCTAssertNil(SearchQuery(text: " … - ").pattern)
        XCTAssertNil(SearchQuery(text: "").pattern)
    }
    func testWhollyQuotedInputIsAPhrase() {
        XCTAssertEqual(SearchQuery(text: "\"new strings\"").pattern?.rawPattern, "\"new strings\"")
    }
    func testUnbalancedQuoteIsOrdinaryText() {
        XCTAssertEqual(SearchQuery(text: "\"new").pattern?.rawPattern, "\"new\"*")
    }
    func testTermsAreTheLowercasedTokens() {
        XCTAssertEqual(SearchQuery(text: "New  Strings").terms, ["new", "strings"])
        XCTAssertEqual(SearchQuery(text: "\"new strings\"").terms, ["new", "strings"])
    }
}

final class SearchSnippetTests: XCTestCase {
    private let o = SearchSnippet.openMarker, c = SearchSnippet.closeMarker
    func testMarkersBecomeRanges() {
        let s = SearchSnippet.parse("the new \(o)strings\(c) arrived")
        XCTAssertEqual(s.text, "the new strings arrived")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["strings"])
    }
    func testNoMarkersNoMatches() {
        let s = SearchSnippet.parse("plain")
        XCTAssertEqual(s.text, "plain"); XCTAssertTrue(s.matches.isEmpty)
    }
    func testTwoMatchesAndOneAtTheEnd() {
        let s = SearchSnippet.parse("\(o)a\(c) b \(o)c\(c)")
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["a", "c"])
    }
    func testAttributedCarriesABackgroundOnEachMatch() {
        let s = SearchSnippet.parse("x \(o)y\(c) z")
        let runs = s.attributed.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(runs.count, 1)
    }
}
```

- [ ] **Step 2: Run, expect FAIL** ("cannot find 'SearchQuery' in scope").

- [ ] **Step 3: Implement**

```swift
import Foundation
import GRDB
import SwiftUI

/// What the owner typed, turned into an FTS5 pattern that never reaches the query parser
/// raw (a stray quote or `-` is a syntax error in FTS5; GRDB's constructors tokenise first).
struct SearchQuery: Sendable, Equatable {
    var text: String

    /// The trimmed input when it is one whole double-quoted string, else nil.
    private var quotedPhrase: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return nil }
        let inner = t.dropFirst().dropLast()
        guard !inner.contains("\"") else { return nil }
        return String(inner)
    }

    var pattern: FTS5Pattern? {
        if let phrase = quotedPhrase { return FTS5Pattern(matchingPhrase: phrase) }
        return FTS5Pattern(matchingAllPrefixesIn: text)
    }

    /// Lowercased word tokens, for the in-entry highlighter (Phase A3) and tests.
    var terms: [String] {
        (quotedPhrase ?? text)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// FTS5 `snippet()` output with private-use markers, parsed into text + match ranges.
struct SearchSnippet: Sendable, Equatable {
    static let openMarker = "\u{E000}"
    static let closeMarker = "\u{E001}"

    var text: String
    var matches: [Range<String.Index>]

    static func parse(_ marked: String) -> SearchSnippet {
        var text = ""
        var matches: [Range<String.Index>] = []
        var openAt: String.Index?
        for ch in marked {
            switch String(ch) {
            case openMarker: openAt = text.endIndex
            case closeMarker:
                if let start = openAt { matches.append(start..<text.endIndex); openAt = nil }
            default: text.append(ch)
            }
        }
        return SearchSnippet(text: text, matches: matches)
    }

    var attributed: AttributedString {
        var out = AttributedString(text)
        for range in matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = InkTone.accent.color.opacity(0.35)
        }
        return out
    }
}
```

(`InkTone.accent` exists — `Raconte/Library/UI/InkSurface.swift`. If `.color` is not the accessor name there, use the one the file exposes; do not add a new tone.)

- [ ] **Step 4: Run, expect PASS.** Note `rawPattern` is GRDB's public property on `FTS5Pattern` — if the exact string form differs on the installed GRDB (quoting), update the expected strings to what GRDB emits and say so in the report; the behaviour under test is prefix-vs-phrase, not quoting style.

- [ ] **Step 5: `xcodegen generate` (new files), full suite, commit** — `feat(#194): SearchQuery and SearchSnippet — pure FTS5 pattern and snippet parsing`

### Task 3: `SearchIndex` actor

**Files:**
- Create: `Raconte/Search/SearchIndex.swift`
- Create: `RaconteTests/SearchIndexTests.swift`

**Interfaces:**
- Consumes: `SearchQuery.pattern`, `SearchSnippet.parse`.
- Produces:

```swift
actor SearchIndex {
    init(databaseURL: URL) throws
    func fingerprints() throws -> [String: String]
    func upsert(captureID: String, fingerprint: String, body: String) throws
    func remove(captureIDs: [String]) throws
    func search(_ query: SearchQuery) throws -> [SearchHit]
}
struct SearchHit: Sendable, Equatable { var captureID: String; var snippet: SearchSnippet }
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

final class SearchIndexTests: XCTestCase {
    private var url: URL!
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func testUpsertThenSearchByPrefixAndFoldedDiacritic() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "les pianos étaient là")
        try await index.upsert(captureID: "B", fingerprint: "1", body: "the new strings arrived")
        let hits = try await index.search(SearchQuery(text: "etai"))
        XCTAssertEqual(hits.map(\.captureID), ["A"])
        XCTAssertEqual(hits.first?.snippet.matches.map { String(hits.first!.snippet.text[$0]) }, ["étaient"])
    }
    func testUpsertReplacesNotDuplicates() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        try await index.upsert(captureID: "A", fingerprint: "2", body: "beta")
        XCTAssertTrue(try await index.search(SearchQuery(text: "alpha")).isEmpty)
        XCTAssertEqual(try await index.search(SearchQuery(text: "beta")).count, 1)
        XCTAssertEqual(try await index.fingerprints(), ["A": "2"])
    }
    func testRemoveDropsBothTables() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        try await index.remove(captureIDs: ["A"])
        XCTAssertTrue(try await index.search(SearchQuery(text: "alpha")).isEmpty)
        XCTAssertTrue(try await index.fingerprints().isEmpty)
    }
    func testEmptyQueryReturnsNothingWithoutError() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        XCTAssertTrue(try await index.search(SearchQuery(text: "  ")).isEmpty)
    }
    func testCorruptFileIsRecreated() async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: url)
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "alpha")
        XCTAssertEqual(try await index.search(SearchQuery(text: "alpha")).count, 1)
    }
    func testReopenKeepsTheRows() async throws {
        do { let i = try SearchIndex(databaseURL: url); try await i.upsert(captureID: "A", fingerprint: "1", body: "alpha") }
        let again = try SearchIndex(databaseURL: url)
        XCTAssertEqual(try await again.fingerprints(), ["A": "1"])
    }
    // Amendment (pre-flight 7): the tokenizer splits at an apostrophe, so the stem of an elided
    // word is findable. Task 11's highlighter must apply the same rule.
    func testElidedWordIsFoundByItsStem() async throws {
        let index = try SearchIndex(databaseURL: url)
        try await index.upsert(captureID: "A", fingerprint: "1", body: "l'école d'été")
        let hits = try await index.search(SearchQuery(text: "ecole"))
        XCTAssertEqual(hits.map(\.captureID), ["A"])
        XCTAssertEqual(hits.first?.snippet.matches.map { String(hits.first!.snippet.text[$0]) }, ["école"])
    }
    // Amendment (pre-flight 5): a second plaintext copy of every transcript stays out of backups.
    func testIndexDirectoryIsExcludedFromBackup() throws {
        _ = try SearchIndex(databaseURL: url)
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
```

**Amendment (pre-flight 3, 4, 5) — the schema and the three write paths below are replaced:**

- Schema. The state table owns an integer id and the FTS row shares it as its `rowid`:

```swift
            try db.create(table: "entry_index_state") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captureID", .text).notNull().unique()
                t.column("fingerprint", .text).notNull()
            }
```

- `upsert`, one write transaction: `SELECT id FROM entry_index_state WHERE captureID = ?`. Found →
  `DELETE FROM entry_text WHERE rowid = ?` and `UPDATE entry_index_state SET fingerprint = ? WHERE id = ?`.
  Not found → `INSERT INTO entry_index_state(captureID, fingerprint)` and take `db.lastInsertedRowID`.
  Then `INSERT INTO entry_text(rowid, captureID, body) VALUES (?, ?, ?)` with that id.
- `remove`: per id, look the state row up by `captureID`, `DELETE FROM entry_text WHERE rowid = ?`,
  then delete the state row.
- **No statement may filter `entry_text` by `captureID`.** An `UNINDEXED` FTS column has no index;
  that `WHERE` is a full scan of every stored transcript, once per upsert. `captureID` stays in
  the FTS table only so `search` can SELECT it.
- After `createDirectory`, mark the directory excluded from backup — the `StagedRemoval.swift:52`
  precedent (`var values = URLResourceValues(); values.isExcludedFromBackup = true;
  try directory.setResourceValues(values)` on a `var` URL). A failure here is logged at `.notice`
  and does not fail `init`. RED proof for the backup test: remove the call.
- No `PRAGMA user_version`: the migrator's table is the schema version. Leave a one-line comment
  saying a schema or tokenizer change is a new migration that drops both tables.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — the block below predates the amendment above. Its `init`, `open`'s
FTS table, `fingerprints` and `search` stand; its `entry_index_state` table, `upsert` and `remove`
are SUPERSEDED — write the amended versions, do not transcribe these three.

```swift
import Foundation
import GRDB
import os

/// The FTS5 index: a disposable derivative of the archive (spec §Approach). Only
/// `captureID` and `body` live here — journal, date and trash are filtered in Swift from
/// `LibraryScreenModel.allEntries`, so a metadata edit never stales the index.
actor SearchIndex {
    private let queue: DatabaseQueue
    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
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
        migrator.registerMigration("v1") { db in
            try db.create(virtualTable: "entry_text", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("captureID").notIndexed()
                t.column("body")
            }
            try db.create(table: "entry_index_state") { t in
                t.primaryKey("captureID", .text)
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
            try db.execute(sql: "DELETE FROM entry_text WHERE captureID = ?", arguments: [captureID])
            try db.execute(sql: "INSERT INTO entry_text(captureID, body) VALUES (?, ?)", arguments: [captureID, body])
            try db.execute(sql: "INSERT OR REPLACE INTO entry_index_state(captureID, fingerprint) VALUES (?, ?)",
                           arguments: [captureID, fingerprint])
        }
    }

    func remove(captureIDs: [String]) throws {
        guard !captureIDs.isEmpty else { return }
        try queue.write { db in
            for id in captureIDs {
                try db.execute(sql: "DELETE FROM entry_text WHERE captureID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM entry_index_state WHERE captureID = ?", arguments: [id])
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
```

- [ ] **Step 4: Run, expect PASS. RED proof for the corrupt-file test:** temporarily remove the `catch` recreate and watch it fail with a `DatabaseError`.

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): SearchIndex — FTS5 store over GRDB with fingerprint table`

### Task 4: `SearchFingerprint` and `EntryTranscriptLoader.fullText`

**Files:**
- Create: `Raconte/Search/SearchFingerprint.swift`
- Modify: `Raconte/Library/EntryTranscript.swift` (add `static func fullText` to `EntryTranscriptLoader`)
- Create: `RaconteTests/SearchFingerprintTests.swift`
- Create: `RaconteTests/EntryTranscriptLoaderFullTextTests.swift`

**Interfaces:**
- Consumes: `TranscriptRevisionStore.validatedHead(captureDirectory:) -> TranscriptHead?` (`current: TranscriptHeadSummary?` with `id`, `characterCount`); `TranscriptRevisionStore.loadChain(captureDirectory:) -> ChainLoad?` (`revisions: [TranscriptRevision]`, each `spans: [TranscriptSpan]` with `text`); `LiveTranscriptReader.load(captureDirectory:)` and `LiveTranscriptStore.consolidate(_:)`; `SegmentLayout.transcriptDirectory(captureDirectory:)`.
- Produces: `enum SearchFingerprint { static func compute(directory: URL) -> String? }` (nil when the directory has neither a head nor a live log); `EntryTranscriptLoader.fullText(captureDirectory: URL, expectedRecords: Int?) -> String?`.

- [ ] **Step 1: Write the failing tests.** Fixtures: use the SAME helpers the existing `EntryTranscriptLoader`/`TranscriptRevisionStore` tests use to write a `live.jsonl` and a canonical revision into a temp capture directory (find them with `grep -rn "canonical-1.json\|live.jsonl" RaconteTests | head` and reuse; do not write a third fixture writer).

```swift
final class SearchFingerprintTests: XCTestCase {
    func testCanonicalHeadDrivesTheFingerprint() throws {
        let dir = try makeCaptureWithCanonical(text: "alpha")           // existing fixture helper
        let a = SearchFingerprint.compute(directory: dir)
        try appendCanonicalRevision(dir, text: "alpha beta")           // existing fixture helper
        let b = SearchFingerprint.compute(directory: dir)
        XCTAssertNotNil(a); XCTAssertNotEqual(a, b)
    }
    func testLiveLogDrivesItWhenThereIsNoCanonical() throws {
        let dir = try makeCaptureWithLiveLog(records: ["one"])
        let a = SearchFingerprint.compute(directory: dir)
        try appendLiveRecord(dir, "two")
        XCTAssertNotEqual(a, SearchFingerprint.compute(directory: dir))
    }
    func testUnrelatedFileDoesNotMoveIt() throws {
        let dir = try makeCaptureWithCanonical(text: "alpha")
        let a = SearchFingerprint.compute(directory: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        XCTAssertEqual(a, SearchFingerprint.compute(directory: dir))
    }
    func testEmptyDirectoryIsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(SearchFingerprint.compute(directory: dir))
    }
}

final class EntryTranscriptLoaderFullTextTests: XCTestCase {
    func testCanonicalSpansAreJoined() throws {
        let dir = try makeCaptureWithCanonical(spans: ["the new", "strings arrived"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil),
                       "the new strings arrived")
    }
    func testFallsBackToConsolidatedCommittedText() throws {
        let dir = try makeCaptureWithLiveLog(records: ["one", "two"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: 2), "one two")
    }
    func testNothingIsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil))
    }
}
```

Join rule for spans: the same join `load(…, attribution: .compute)` uses to build `text` from `current.spans` — read that branch (`EntryTranscript.swift`, the `.compute` canonical branch) and call the same helper; if it is inline, extract it to a `private static func flattened(_ spans: [TranscriptSpan]) -> String` and use it from both places. The consolidated-committed join is whatever `LiveTranscriptStore.consolidate(_:)`'s consumer in `load` does for `text`. The tests' expected strings must match THAT rule (space-joined above is the assumption; adjust to the real rule and say so).

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

```swift
import Foundation

/// O(1) change detection per entry for the search index: no body is decoded here.
enum SearchFingerprint {
    static func compute(directory: URL) -> String? {
        if let head = TranscriptRevisionStore.validatedHead(captureDirectory: directory),
           let current = head.current {
            return "rev:\(current.id):\(current.characterCount)"
        }
        let live = SegmentLayout.transcriptDirectory(captureDirectory: directory)
            .appendingPathComponent("live.jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: live.path),
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return "live:\(size.int64Value):\(Int64(modified.timeIntervalSince1970 * 1000))"
    }
}
```

(Confirm the live log's file name and location from `LiveTranscriptReader.load` rather than trusting the literal above.)

`fullText` on `EntryTranscriptLoader`:

```swift
    /// The whole text the search index stores: the canonical current revision's spans,
    /// else the consolidated committed text. No attribution, no snippet truncation.
    static func fullText(captureDirectory: URL, expectedRecords: Int?) -> String? {
        if let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory),
           let current = chain.revisions.last {           // same "current" rule as load()
            let text = flattened(current.spans)
            return text.isEmpty ? nil : text
        }
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        guard case .present = loaded.source else { return nil }
        let text = LiveTranscriptStore.consolidate(loaded.records).text   // the same accessor load() uses
        return text.isEmpty ? nil : text
    }
```

Verify "current = `revisions.last`" against how `load` picks `current` (it may use a head id or an `isForked` rule); use the same expression.

- [ ] **Step 4: Run, expect PASS.** RED proof: the `nil`/`notEqual` assertions fail against a stub returning a constant.

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): SearchFingerprint and EntryTranscriptLoader.fullText`

### Task 5: `SearchIndexer` reconcile

**Files:**
- Create: `Raconte/Search/SearchIndexer.swift`
- Create: `RaconteTests/SearchIndexerTests.swift`

**Interfaces:**
- Consumes: `SearchIndex`, `SearchFingerprint.compute`, `EntryTranscriptLoader.fullText`.
- Produces:

```swift
actor SearchIndexer {
    struct Entry: Sendable, Equatable { var captureID: String; var directory: URL; var expectedRecords: Int? }
    struct Report: Sendable, Equatable { var indexed = 0; var removed = 0; var unchanged = 0; var failed = 0 }
    init(index: SearchIndex)
    func reconcile(_ entries: [Entry]) async -> Report
}
```

- [ ] **Step 1: Write the failing tests** (fixtures from Task 4's helpers; three capture dirs under one temp root)

```swift
final class SearchIndexerTests: XCTestCase {
    func testFirstReconcileIndexesEverythingSecondIndexesNothing() async throws {
        let (index, indexer, entries) = try await makeThree()
        XCTAssertEqual(await indexer.reconcile(entries), .init(indexed: 3, removed: 0, unchanged: 0, failed: 0))
        XCTAssertEqual(await indexer.reconcile(entries), .init(indexed: 0, removed: 0, unchanged: 3, failed: 0))
        XCTAssertEqual(try await index.search(SearchQuery(text: "alpha")).map(\.captureID), [entries[0].captureID])
    }
    func testEditedEntryIsReindexed() async throws {
        let (index, indexer, entries) = try await makeThree()
        _ = await indexer.reconcile(entries)
        try appendCanonicalRevision(entries[1].directory, text: "beta gamma")
        XCTAssertEqual(await indexer.reconcile(entries).indexed, 1)
        XCTAssertEqual(try await index.search(SearchQuery(text: "gamma")).map(\.captureID), [entries[1].captureID])
    }
    func testGoneEntryIsRemoved() async throws {
        let (index, indexer, entries) = try await makeThree()
        _ = await indexer.reconcile(entries)
        let report = await indexer.reconcile(Array(entries.dropLast()))
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(try await index.search(SearchQuery(text: "charlie")).isEmpty)
    }
    func testUnreadableEntryIsCountedFailedAndOthersStillIndex() async throws {
        let (_, indexer, entries) = try await makeThree()
        try FileManager.default.removeItem(at: entries[2].directory)      // directory gone but still listed
        let report = await indexer.reconcile(entries)
        XCTAssertEqual(report.indexed, 2); XCTAssertEqual(report.failed, 1)
    }
    func testEmptyTextEntryIsNotIndexedAndNotFailed() async throws {
        // a capture dir with a live.jsonl holding zero committed records
        …
        XCTAssertEqual(report.indexed, 0); XCTAssertEqual(report.failed, 0)
    }
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement**

```swift
import Foundation
import os

/// Keeps the index in step with the files after every library scan. Read-only against
/// `captures/` — never a write there, never a `noteLocalChange`.
actor SearchIndexer {
    struct Entry: Sendable, Equatable { var captureID: String; var directory: URL; var expectedRecords: Int? }
    struct Report: Sendable, Equatable { var indexed = 0; var removed = 0; var unchanged = 0; var failed = 0 }

    private let index: SearchIndex
    private static let log = Logger(subsystem: "org.pianohouseproject.raconte", category: "search")

    init(index: SearchIndex) { self.index = index }

    func reconcile(_ entries: [Entry]) async -> Report {
        var report = Report()
        let known = (try? await index.fingerprints()) ?? [:]
        let listed = Set(entries.map(\.captureID))
        let gone = known.keys.filter { !listed.contains($0) }
        if !gone.isEmpty, (try? await index.remove(captureIDs: Array(gone))) != nil { report.removed = gone.count }

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                report.failed += 1
                Self.log.notice("search: capture directory missing for \(entry.captureID, privacy: .public)")
                continue
            }
            guard let fingerprint = SearchFingerprint.compute(directory: entry.directory) else {
                // Nothing transcribed yet — not an error, nothing to find.
                if known[entry.captureID] != nil { try? await index.remove(captureIDs: [entry.captureID]); report.removed += 1 }
                continue
            }
            if known[entry.captureID] == fingerprint { report.unchanged += 1; continue }
            guard let body = EntryTranscriptLoader.fullText(captureDirectory: entry.directory,
                                                            expectedRecords: entry.expectedRecords) else {
                if known[entry.captureID] != nil { try? await index.remove(captureIDs: [entry.captureID]); report.removed += 1 }
                continue
            }
            do {
                try await index.upsert(captureID: entry.captureID, fingerprint: fingerprint, body: body)
                report.indexed += 1
            } catch {
                report.failed += 1
                Self.log.notice("search: index write failed for \(entry.captureID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return report
    }
}
```

**Amendment (pre-flight 6):** `reconcile` measures itself (`ContinuousClock`) and, when
`indexed + removed + failed > 0`, logs ONE `.notice` line before returning:
`search: reconcile indexed=… removed=… unchanged=… failed=… in …ms`. A run that changed nothing
logs nothing (it happens after every rescan). Counts and a duration only — never transcript text.

- [ ] **Step 4: Run, expect PASS.** RED proof: comment out the fingerprint comparison and watch `unchanged` fail.

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): SearchIndexer — fingerprint reconcile of the archive into the index`

### Task 6: Trigger from the library model; app wiring

**Files:**
- Modify: `Raconte/Library/LibraryScreenModel.swift` (`attach(searchIndexer:)`, `scheduleReconcile`, `searchIndexing`, call at the end of `rescan()`)
- Modify: `Raconte/App/RaconteApp.swift` (`AppServices.search: SearchServices?`)
- Create: `Raconte/Search/SearchServices.swift`
- Modify: `Raconte/Library/AppContainer.swift` — add `static func searchDirectory(containerRoot:) -> URL` beside the existing root helpers (read the file's layout comment: `search/` is a SIBLING of `captures/`, never inside it)
- Modify: `RaconteTests/LibraryScreenModelBlankEntryTests.swift` or the model test file with the simplest fixture (add tests)

**Interfaces:**
- Produces: `protocol SearchReconciling: Sendable { func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report }` (conformed by `SearchIndexer`; a fake in tests); `LibraryScreenModel.attach(searchReconciler:)`; `private(set) var searchIndexing: Bool`; `final class SearchServices { let index: SearchIndex?; let indexer: SearchIndexer?; let unavailableReason: String? }`.

**Amendment (pre-flight 8, 10) — the tests below replace the plan's originals.** The originals
called `release()` right after `rescan()`; the reconcile runs in an unstructured `Task`, so
`release()` could arrive before the fake had parked — a no-op, then a hang or a zero-call read.
Every test now waits for the call it is about to release, and every "nothing more happens"
assertion waits for `searchIndexing == false` instead of sleeping a fixed 50 ms. Also added:
`searchIndexRevision`, which Task 8 observes to re-run the visible query.

- [ ] **Step 1: Write the failing tests**

```swift
/// Counts reconcile calls and blocks until released, to prove coalescing.
actor FakeReconciler: SearchReconciling {
    var calls: [[String]] = []
    private var gate: CheckedContinuation<Void, Never>?
    func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report {
        calls.append(entries.map(\.captureID))
        await withCheckedContinuation { gate = $0 }
        return .init()
    }
    /// True when a parked call was released. A false return means nothing was parked — the
    /// test called it too early; assert on it.
    @discardableResult func release() -> Bool {
        guard let g = gate else { return false }
        gate = nil; g.resume(); return true
    }
    /// Returns once `n` calls have PARKED (or after ~2 s, so a broken build fails an assertion
    /// instead of hanging the suite).
    func waitForParkedCall(_ n: Int) async {
        for _ in 0..<400 where !(calls.count >= n && gate != nil) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Bounded wait for the model to go idle (~2 s), same reason.
@MainActor func waitUntilIdle(_ model: LibraryScreenModel) async {
    for _ in 0..<400 where model.searchIndexing { try? await Task.sleep(for: .milliseconds(5)) }
}

func testRescanHandsAllEntriesAndTrashedToTheReconciler() async throws {
    // fixture: model over a temp captures root with one live entry and one trashed entry (existing fixtures)
    let fake = FakeReconciler()
    model.attach(searchReconciler: fake)
    _ = await model.rescan()
    await fake.waitForParkedCall(1)
    let ids = await fake.calls.first ?? []
    XCTAssertEqual(Set(ids), Set([liveID, trashedID]))
    let released = await fake.release(); XCTAssertTrue(released)
    await waitUntilIdle(model)
}

func testRescansDuringAReconcileCoalesceIntoExactlyOneMore() async throws {
    let fake = FakeReconciler()
    model.attach(searchReconciler: fake)
    _ = await model.rescan()                 // starts reconcile #1
    await fake.waitForParkedCall(1)          // #1 is parked inside the fake
    _ = await model.rescan()
    _ = await model.rescan()                 // two more while #1 runs
    var released = await fake.release(); XCTAssertTrue(released)   // #1 finishes → exactly one follow-up
    await fake.waitForParkedCall(2)
    let afterFirst = await fake.calls.count
    XCTAssertEqual(afterFirst, 2)
    released = await fake.release(); XCTAssertTrue(released)
    await waitUntilIdle(model)
    let afterSecond = await fake.calls.count
    XCTAssertEqual(afterSecond, 2)              // nothing queued after the follow-up
    XCTAssertFalse(model.searchIndexing)
}

func testSearchIndexingIsTrueWhileAReconcileRuns() async throws {
    … rescan; waitForParkedCall(1); XCTAssertTrue(model.searchIndexing); release; waitUntilIdle; XCTAssertFalse …
}

func testEachCompletedPassBumpsSearchIndexRevision() async throws {
    … XCTAssertEqual(model.searchIndexRevision, 0); rescan; waitForParkedCall(1);
      XCTAssertEqual(model.searchIndexRevision, 0)      // not before the pass completes
      release; waitUntilIdle; XCTAssertEqual(model.searchIndexRevision, 1) …
}
```

`searchIndexRevision`: `private(set) var searchIndexRevision = 0` on `LibraryScreenModel`,
incremented inside the `repeat` loop right after each `reconcile` call returns (so a coalesced
follow-up bumps it again). It is the signal "the index may have changed"; Task 8's model observes
it. Name the container helper `AppContainer.searchRoot(containerRoot:)` to match its siblings
`syncRoot` / `quarantineRoot` — the file list above says `searchDirectory`, written before the
file was read.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — in `LibraryScreenModel`:

```swift
    // MARK: Search index (#194)
    private var searchReconciler: (any SearchReconciling)?
    private(set) var searchIndexing = false
    private var reconcilePending = false
    private var reconcileRunning = false

    func attach(searchReconciler: any SearchReconciling) { self.searchReconciler = searchReconciler }

    /// Coalescing: one reconcile at a time; any number of requests during a run collapse
    /// into exactly one follow-up. Entries are re-read from the model when the follow-up
    /// starts, so it always sees the latest scan.
    private func scheduleSearchReconcile() {
        guard searchReconciler != nil else { return }
        if reconcileRunning { reconcilePending = true; return }
        reconcileRunning = true
        searchIndexing = true
        Task { [weak self] in await self?.runSearchReconcile() }
    }

    private func runSearchReconcile() async {
        defer { reconcileRunning = false; searchIndexing = false }
        repeat {
            reconcilePending = false
            let entries = (allEntries + trashed).map {
                SearchIndexer.Entry(captureID: $0.captureID,
                                    directory: capturesRoot.appendingPathComponent($0.captureID),
                                    expectedRecords: $0.expectedTranscriptRecords)   // the field the scanner already carries; find its real name
            }
            _ = await searchReconciler?.reconcile(entries)
        } while reconcilePending
    }
```

Call `scheduleSearchReconcile()` in `rescan()` right after `rescanObserver?.libraryDidRescan()`. If `EntryListItem` has no `expectedRecords`-shaped field, pass `nil` and note it — `fullText` falls back correctly without it.

`SearchServices` (constructed in `AppServices.init` from `AppContainer.searchDirectory(containerRoot:)`): `try SearchIndex(databaseURL:)`; on throw, `index = nil`, `unavailableReason = error.localizedDescription`, `.notice` log. When non-nil: `library.attach(searchReconciler: indexer)`. Under `RACONTE_UITEST_ID` the container root is the harness root, so the index lands in the harness too — nothing to special-case.

- [ ] **Step 4: Run, expect PASS.** RED proof for coalescing: make `scheduleSearchReconcile` start a Task unconditionally and watch `calls.count` reach 3.

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): reconcile the search index after every library scan; wire SearchServices`

### Task 7 (A1 close): final review, PR 1

- [ ] Whole-branch review (most capable model), one fix round, scoped re-review.
- [ ] Test count: baseline (from main's latest code-carrying CI job log) + Tasks 1–6 additions (1 + 9 + 8 + 7 + 5 + 4 = **+34** unit after the pre-flight amendments — Task 3 +2, Task 6 +1; UI unchanged). State both numbers in the PR body with the job-log source.
- [ ] PR body: what/why, the GRDB decision (one paragraph: the research reply recommended raw `SQLite3`, why GRDB stayed, the pinned version and revision, link the spec), that the owner has not reviewed the written spec or plan, the pre-flight amendments by number, and smoke steps for the owner — self-contained, build-number first:
  1. About → App → Build shows the build number handed over with the smoke build.
  2. Quit the app; `ls "$HOME/Library/Containers/org.pianohouseproject.raconte/Data/Library/Application Support/Raconte/search/"` lists `index.sqlite` (Mac). (Quoted path, no backslash — CLAUDE.md shared conventions.)
  3. `/usr/bin/log show --last 10m --predicate 'subsystem == "org.pianohouseproject.raconte" AND category == "search"'` prints one `search: reconcile indexed=N … in …ms` line: N is the number of entries with a transcript, and the milliseconds are the full-rebuild time the research reply asked for.
  4. Record a short entry, wait for the transcript, quit → the file's modification time moved.
  Nothing else changes in this PR.
- [ ] **Amendment (stacked run):** the PR is already open as a draft from the first push; mark it ready, leave it open. Do NOT stop: Phase A2 starts on `feat/194-search-place`, branched from this branch's head. Merge is Nico's. Build 27 bump happens on main after merge (owner smoke).

---

## Phase A2 — Search place (PR 2, branch `feat/194-search-place` off `main` after PR 1 merges)

### Task 8: `Place.search`, sidebar row, routing, `SearchScreenModel`

**Files:**
- Modify: `Raconte/App/Place.swift` (`case search`; `SidebarModel.rows` inserts the row between Trash and About, identifier `sidebar.search`, systemImage `magnifyingglass`; every `switch` over `Place` gains the case — the compiler lists them)
- Modify: `Raconte/App/ContentView.swift` (`case .search: SearchView(model: services.searchScreen, library: services.library)` with the same `.tint`/`.background` as `.trash`)
- Modify: `Raconte/App/RaconteApp.swift` (`AppServices.searchScreen: SearchScreenModel`)
- Create: `Raconte/Search/SearchScreenModel.swift`
- Create: `Raconte/Search/SearchDateFilter.swift`
- Create: `RaconteTests/SearchScreenModelTests.swift`, `RaconteTests/SearchDateFilterTests.swift`
- Modify: `RaconteTests/PlaceRoutingTests.swift` (or wherever `SidebarModel.rows` is pinned — `grep -rn "sidebar.trash" RaconteTests`) to assert the new row's position

**Interfaces:**
- Consumes: `SearchIndex.search`, `LibraryScreenModel.allEntries` / `journals`, `CurrentJournal.resolve(in:)`, `JournalSpan`'s exclusive-upper-bound comparison (`JournalSpan.swift` — reuse its helper, do not re-derive).
- Produces:

```swift
enum SearchDateFilter: Sendable, Equatable {
    case anyTime, thisYear, lastYear
    case custom(from: PartialDate?, to: PartialDate?)
    func contains(_ date: Date, calendar: Calendar, now: Date) -> Bool
    var title: String
}
struct SearchResult: Identifiable, Sendable, Equatable {
    var id: String { item.captureID }
    var item: EntryListItem
    var snippet: SearchSnippet
}
@MainActor @Observable final class SearchScreenModel {
    var text: String                         // the field; setting it schedules a query
    var journalScope: JournalScope           // .all or .journal(id); defaults from CurrentJournal on first appear
    var dateFilter: SearchDateFilter = .anyTime
    private(set) var results: [SearchResult]
    private(set) var hasQuery: Bool          // false when text has no pattern
    func appeared()                          // seeds journalScope from CurrentJournal once
    func refresh() async                     // runs the query now (also called on filter change)
    static func filterAndSort(hits: [SearchHit], entries: [EntryListItem], scope: JournalScope,
                              date: SearchDateFilter, calendar: Calendar, now: Date) -> [SearchResult]  // pure
}
```

- [ ] **Step 1: Write the failing tests**

```swift
final class SearchDateFilterTests: XCTestCase {
    let cal = Calendar.gregorianCurrent
    func testLastDayOfThisYearIsInThisYear() {
        let now = date(2026, 10, 8), dec31 = date(2026, 12, 31, 23, 59, 59)
        XCTAssertTrue(SearchDateFilter.thisYear.contains(dec31, calendar: cal, now: now))
        XCTAssertFalse(SearchDateFilter.thisYear.contains(date(2027, 1, 1), calendar: cal, now: now))
    }
    func testLastYear() { … 2025-12-31 in, 2026-01-01 out … }
    func testCustomYearPrecisionExpandsToTheWholeYear() {
        let f = SearchDateFilter.custom(from: PartialDate(year: 2024), to: PartialDate(year: 2024))
        XCTAssertTrue(f.contains(date(2024, 12, 31), calendar: cal, now: now))
        XCTAssertFalse(f.contains(date(2025, 1, 1), calendar: cal, now: now))
    }
    func testOpenEndedCustom() { … from only; to only … }
}

final class SearchScreenModelTests: XCTestCase {
    func testTrashIsExcludedBecauseOnlyAllEntriesAreJoined() {
        let hits = [SearchHit(captureID: "live", snippet: .parse("x")), SearchHit(captureID: "trashed", snippet: .parse("x"))]
        let results = SearchScreenModel.filterAndSort(hits: hits, entries: [liveItem], scope: .all, date: .anyTime, calendar: cal, now: now)
        XCTAssertEqual(results.map(\.id), ["live"])
    }
    func testJournalScopeFilters() { … scope .journal("J1") keeps only J1 items … }
    func testNewestFirst() { … three items out of index order come back by effectiveDate descending … }
    func testAppearedSeedsScopeFromCurrentJournalOnce() async {
        // CurrentJournal with an InMemoryJournalPreferenceStore pointing at "J2"
        model.appeared(); XCTAssertEqual(model.journalScope, .journal("J2"))
        model.journalScope = .all; model.appeared(); XCTAssertEqual(model.journalScope, .all)
    }
    func testResultsForASupersededQueryAreDropped() async {
        // a FakeSearching index whose search() awaits a gate; type "ab", then "" before releasing
        model.text = "ab"; model.text = ""
        await fake.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.results.isEmpty); XCTAssertFalse(model.hasQuery)
    }
    func testSidebarRowSitsBetweenTrashAndAbout() {
        let ids = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false).map(\.accessibilityIdentifier)
        XCTAssertEqual(ids.suffix(3), ["sidebar.trash", "sidebar.search", "sidebar.about"])
    }
}
```

Give `SearchScreenModel` a `protocol SearchQuerying: Sendable { func search(_ query: SearchQuery) async throws -> [SearchHit] }` (conformed by `SearchIndex`) so tests inject a fake; the model takes `(searching: (any SearchQuerying)?, unavailableReason: String?, library: LibraryScreenModel, currentJournal: CurrentJournal)`.

**Amendments to this task (pre-flight 9, 10, 11, 12):**

- **(12) `SearchView` does not exist until Task 9, and this task's `ContentView` case names it.**
  Create `Raconte/Search/UI/SearchView.swift` here as a stub — the real init signature (model,
  library, and the router however `.trash`'s screen receives it; read `ContentView`'s `.trash`
  case), a body of `List { }` with `.navigationTitle("Search")` and nothing else. Task 9 fills it
  in. The stub is not yet in `paperScreenFiles`.
- **(11) "Search is unavailable" has an owner.** The model stores `let unavailableReason: String?`
  (`AppServices` passes `services.search?.unavailableReason`, and a nil `searching`). Add:

```swift
    func testAnUnavailableIndexReportsItsReasonAndNeverHasResults() async {
        let model = SearchScreenModel(searching: nil, unavailableReason: "disk full", library: library, currentJournal: current)
        model.text = "alpha"; await model.refresh()
        XCTAssertEqual(model.unavailableReason, "disk full"); XCTAssertTrue(model.results.isEmpty)
    }
```

- **(9) `testResultsForASupersededQueryAreDropped` above cannot fail — replace it.** With the
  150 ms debounce, `text = "ab"; text = ""` cancels the first query before it ever calls the
  index, so the test passes with the generation guard deleted; and its fake returned no hit that
  joins an entry, so nothing could repaint anyway. Replacement — the fixture's library must hold
  one LIVE entry whose captureID the fake's hit carries (mint it with `ULID.make()`; a
  non-ULID id is skipped by code paths elsewhere):

```swift
    /// Parks each search until released, then returns the hits it was given.
    actor FakeSearching: SearchQuerying {
        var calls = 0
        private var gate: CheckedContinuation<[SearchHit], Never>?
        func search(_ query: SearchQuery) async throws -> [SearchHit] {
            calls += 1
            return await withCheckedContinuation { gate = $0 }
        }
        @discardableResult func release(_ hits: [SearchHit]) -> Bool {
            guard let g = gate else { return false }
            gate = nil; g.resume(returning: hits); return true
        }
        func waitForParkedCall(_ n: Int) async {
            for _ in 0..<400 where !(calls >= n && gate != nil) { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    // Positive control: the fixture CAN paint a result. Without it the next test proves nothing.
    func testAQueryThatIsNotSupersededPublishesItsHit() async {
        model.text = "ab"
        let running = Task { await model.refresh() }        // refresh() runs now, no debounce
        await fake.waitForParkedCall(1)
        let released = await fake.release([SearchHit(captureID: liveID, snippet: .parse("ab"))])
        XCTAssertTrue(released); await running.value
        XCTAssertEqual(model.results.map(\.id), [liveID])
    }
    func testResultsForASupersededQueryAreDropped() async {
        model.text = "ab"
        let running = Task { await model.refresh() }
        await fake.waitForParkedCall(1)                     // the query is IN the index, parked
        model.text = ""                                     // superseded while in flight
        XCTAssertTrue(model.results.isEmpty); XCTAssertFalse(model.hasQuery)   // cleared at once
        let released = await fake.release([SearchHit(captureID: liveID, snippet: .parse("ab"))])
        XCTAssertTrue(released); await running.value
        XCTAssertTrue(model.results.isEmpty)                // the late hit did not repaint
        XCTAssertFalse(model.hasQuery)
    }
```

  Requirement this pins: setting `text` to a value with no pattern clears `results` and
  `hasQuery` synchronously (not after the debounce) and bumps the query generation. RED proof:
  delete the generation check in `refresh()` — the late hit repaints and the last
  `XCTAssertTrue(model.results.isEmpty)` fails, while the positive control stays green.
- **(10) A finished reconcile re-runs the visible query.** The model observes
  `library.searchIndexRevision` itself — model-owned observation, the mechanism
  `CaptureScreenModel` uses for its own state (CLAUDE.md: never a view's `.onChange` for
  something that must happen) — and calls `refresh()` when it moves and `hasQuery` is true. Add:

```swift
    func testAFinishedReconcileRerunsTheCurrentQuery() async {
        // library has an attached reconciler fake that returns immediately; `fake` (FakeSearching)
        // answers the first search with [] and the second with the live entry's hit.
        model.text = "ab"
        let first = Task { await model.refresh() }
        await fake.waitForParkedCall(1); await fake.release([]); await first.value
        XCTAssertTrue(model.results.isEmpty)
        _ = await library.rescan()                           // → a reconcile pass → revision moves
        await fake.waitForParkedCall(2)                      // the model re-queried on its own
        await fake.release([SearchHit(captureID: liveID, snippet: .parse("ab"))])
        … bounded wait for results …
        XCTAssertEqual(model.results.map(\.id), [liveID])
    }
```

  RED proof: remove the observation — `waitForParkedCall(2)` times out and the assertion fails.

- **The debounce is injectable.** `SearchScreenModel.init` takes `debounce: Duration = .milliseconds(150)`.
  The three tests above build the model with `.seconds(3600)`: otherwise the debounced query for
  `"ab"` fires on its own at 150 ms, and in the re-query test it would satisfy
  `waitForParkedCall(2)` without the observation existing — a pass that proves nothing.

Test count for this task after the amendments: `SearchDateFilterTests` 4 + `SearchScreenModelTests` 9 = **+13**.

- [ ] **Step 2: Run, expect FAIL** (new `Place` case alone breaks the build until every switch is handled — do the `Place` edit first, build, then the tests).

- [ ] **Step 3: Implement.** Query generation guard: each `refresh()` increments `queryGeneration`, captures it, awaits the search, and publishes only if the generation is still current — the same pattern `rescan()` uses with `scanGeneration`. `text`'s `didSet` schedules `refresh()` through a 150 ms debounce `Task` that is cancelled and replaced on every keystroke. `filterAndSort`: build `[captureID: EntryListItem]` from `entries`, keep hits with an item, apply `scope` (`JournalScope.all` keeps all; `.journal(id)` matches `item.journalID`; `.unfiled` matches nil), apply `date.contains(item.metadata.effectiveDate(capturedAt: item.capturedAt))`, sort by that date descending then captureID descending.

- [ ] **Step 4: Run, expect PASS.** RED proofs: drop the generation guard → superseded test fails; remove the exclusive-bound expansion → Dec 31 test fails.

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): Place.search, SearchScreenModel and SearchDateFilter`

### Task 9: `SearchView` — field, chips, results; UI tests

**Files:**
- Create: `Raconte/Search/UI/SearchView.swift`
- Create: `Raconte/Search/UI/SearchResultRow.swift`
- Modify: `RaconteTests/SourceScanning.swift` (`paperScreenFiles` += `SearchView.swift`, `SearchResultRow.swift`)
- Modify: `Raconte/App/RaconteCommands.swift` (⌘F → focus the search field when `router.place == .search`; otherwise unchanged behaviour — read the file for how commands reach the router)
- Create: `RaconteUITests/SearchUITests.swift`
- Modify: `RaconteUITests/UITestNavigation.swift` only if `openPlace` needs nothing new (it should not — `sidebar.search` is a row like `sidebar.trash`)

**Interfaces:**
- Consumes: `SearchScreenModel`, `LibraryScreenModel.journals` (`displayOrdered`), `router.select`/`detailPath` for opening an entry (`pushedRouter.detailPath.append(.entry(id))` — follow `ContentView.swift:106-110`'s pattern and its comment about never appending in the same transaction as another navigation).
- Produces identifiers: `search.field` (the `.searchable` field is found by XCUITest as `app.searchFields.firstMatch`; add `.accessibilityIdentifier("search.field")` on the List for the screen), `search.chip.journal`, `search.chip.date`, `search.result.<captureID>`, `search.empty` (the hint), `search.noMatches`, `search.indexing`.

**Amendments to this task (pre-flight 11, 12, and the Global Constraints added 2026-10-10):**

- `SearchView.swift` already exists as Task 8's stub; this task replaces its body. Its init stays
  whatever Task 8 gave it (the `SearchView(model:library:router:)` in Step 2 is illustrative).
- **RED proof is local and comes first.** Write the three UI tests, run `SearchUITests` on the
  simulator against Task 8's stub, and record all three failing on `waitForExistence`. Then build
  the view and run the class green. (This replaces Step 3's "replace the body with `EmptyView()`"
  and its "push and read the UI job log".)
- **"Search is unavailable":** when `model.unavailableReason` is non-nil the list shows one row,
  "Search is unavailable" (`TypeRole.body`) with the reason under it (`TypeRole.footnote`),
  identifier `search.unavailable`, and no chips, hint or results.
- **Chip labels are text-only** — no `Image`, no `Label` with an icon, inside either `Menu` label
  (CLAUDE.md, #69: macOS paints an `Image` in a `Menu` label at intrinsic size).
- **Result waits are 15 s, not 5.** The seeded entry is only findable once the launch scan's
  reconcile has indexed it; Task 8's re-query repaints when it lands. A cold CI simulator is slow.
- The view never logs the query text.

- [ ] **Step 1: Write the failing UI tests**

```swift
final class SearchUITests: XCTestCase {
    func testTypingFindsTheSeededEntryAndOpensIt() {
        let app = launchApp(seedEntry: true)          // existing launcher helper with RACONTE_UITEST_SEED_ENTRY
        openPlace(app, "sidebar.search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("heard")
        let result = app.buttons["search.result.\(UITestEntrySeed.captureID)"]   // or otherElements, per the row's element type
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("heard"))
        result.tap()
        XCTAssertTrue(app.staticTexts["detail.transcript.text"].waitForExistence(timeout: 5))
    }
    func testNoMatchesState() {
        … type "zzzz" → app.staticTexts["search.noMatches"] exists …
    }
    func testJournalChipScopesOut() {
        … seed a journal (RACONTE_UITEST_SEED_JOURNAL_COVER seeds one; read UITestSupport for its id/name), set chip → that journal → no result; chip → All journals → result …
    }
}
```

`UITestEntrySeed.captureID` is in the app target; the UI test target cannot import it — copy the literal `"01KYX77KK5QM15915EZBVXTQZ4"` into the test with a comment naming its source (the existing UI tests do the same; grep for the literal).

- [ ] **Step 2: Build the view**

```swift
struct SearchView: View {
    @Bindable var model: SearchScreenModel
    let library: LibraryScreenModel
    let router: AppRouter
    @State private var searchFocused = false
    @State private var customDates = false

    var body: some View {
        List {
            chips
            if !model.hasQuery {
                Text("Search your transcripts").font(TypeRole.body.font)
                    .foregroundStyle(InkTone.inkSecondary.color).accessibilityIdentifier("search.empty")
            } else if model.results.isEmpty {
                Text("No matches").font(TypeRole.body.font).accessibilityIdentifier("search.noMatches")
            } else {
                ForEach(model.results) { result in
                    Button { open(result) } label: { SearchResultRow(result: result) }
                        .accessibilityIdentifier("search.result.\(result.id)")
                }
            }
            if library.searchIndexing {
                Text("Indexing…").font(TypeRole.label.font).accessibilityIdentifier("search.indexing")
            }
        }
        .navigationTitle("Search")
        .searchable(text: $model.text, placement: .automatic, prompt: "Search")
        .searchFocused($searchFocused)
        .onAppear { model.appeared(); searchFocused = true }
        .sheet(isPresented: $customDates) { SearchCustomDatesSheet(filter: $model.dateFilter) }   // outer view, never a Section
    }

    private var chips: some View {
        HStack {
            Menu { journalItems } label: { chip(model.journalScopeTitle(library.journals)) }
                .accessibilityIdentifier("search.chip.journal")
            Menu { dateItems } label: { chip(model.dateFilter.title) }
                .accessibilityIdentifier("search.chip.date")
        }
        .environment(\.colorScheme, .light)   // only if the band pins a background; otherwise drop this line
    }

    private func open(_ result: SearchResult) {
        router.detailPath.append(.entry(result.id))
    }
}
```

Row: `SearchResultRow` shows the date line (reuse the library row's date formatting — `grep -n "effectiveDate" Raconte/Library/UI/LibraryView.swift` for the formatter), the journal name (`result.item.journal?.name ?? "Unfiled"`), and `Text(result.snippet.attributed)` with `TypeRole`s throughout. Combine the row into one accessibility element (`.accessibilityElement(children: .combine)`) so `result.label` carries the snippet text for the UI test.

`SearchCustomDatesSheet`: two `PartialDate` fields reusing `JournalSpanEditor`'s field view (read the file; extract the single-field subview if it is private) and a Done button; writes `.custom(from:to:)`.

- [ ] **Step 3: Verify** — paper-screen scan passes (`TypeScaleTests`), full unit suite, push and read the UI job log for the three new tests. RED proof for the UI tests: with the branch's `SearchView` body replaced by `EmptyView()` the three tests fail on `waitForExistence`.

- [ ] **Step 4: regen, commit** — `feat(#194): SearchView — searchable field, journal and date chips, result rows`

### Task 10 (A2 close): final review, PR 2

- [ ] Whole-branch review, one fix round, scoped re-review.
- [ ] Counts: unit baseline (**amended, stacked run:** PR 1's own CI job log, since PR 1 has not merged) + Task 8 (4 + 9 = **+13** after the pre-flight amendments) ; UI baseline + **3**.
- [ ] PR body smoke, self-contained, both platforms:
  - Mac: About → Build N. Sidebar → Search (between Trash and About). Field has focus; type a word you know you said in a recent entry → a row with that word highlighted; tap → the entry opens. Journal chip → a journal you did not say it in → "No matches"; All journals → back. Date chip → Last year → only last year's entries.
  - iPhone: same path; the field is in the navigation bar; check the chips are tappable with a thumb.
- [ ] **Amendment (stacked run):** PR 2's base is `feat/194-search-index`, and its body says so and says "merge #<PR 1> first". Mark it ready, leave it open, and continue: Phase A3 starts on `feat/194-search-highlight`, branched from this branch's head.

---

## Phase A3 — in-entry highlight (PR 3, branch `feat/194-search-highlight` off `main` after PR 2 merges)

### Task 11: `SearchHighlight`, destination change, `TranscriptHighlighter`

**Files:**
- Create: `Raconte/Search/TranscriptHighlighter.swift` (also holds `struct SearchHighlight`)
- Modify: `Raconte/Library/UI/LibraryView.swift` (`case entry(String, highlight: SearchHighlight? = nil)`)
- Modify: `Raconte/Search/UI/SearchView.swift` (`open` passes `highlight: SearchHighlight(terms: SearchQuery(text: model.text).terms)`)
- Create: `RaconteTests/TranscriptHighlighterTests.swift`
- Modify: the test that pins `LibraryDestination` equality/hashing, if one exists (`grep -rn "LibraryDestination" RaconteTests`)

**Interfaces:**
- Produces:

```swift
struct SearchHighlight: Hashable, Sendable { var terms: [String] }
enum TranscriptHighlighter {
    /// Word-start, case- and diacritic-insensitive prefix matches — the index's rule.
    static func matches(in text: String, terms: [String]) -> [Range<String.Index>]
    static func attributed(_ text: String, matches: [Range<String.Index>], current: Int?) -> AttributedString
}
```

- [ ] **Step 1: Write the failing tests**

```swift
final class TranscriptHighlighterTests: XCTestCase {
    func testWordStartPrefixOnly() {
        let r = TranscriptHighlighter.matches(in: "strings restring string", terms: ["string"])
        XCTAssertEqual(r.map { String("strings restring string"[$0]) }, ["string", "string"])  // not inside "restring"
    }
    func testCaseAndDiacriticsFold() {
        let t = "Étaient etaient ÉTAIENT"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["etai"]).count, 3)
    }
    func testMultipleTermsInTextOrder() {
        let t = "b a b"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["a", "b"]).map { t.distance(from: t.startIndex, to: $0.lowerBound) }, [0, 2, 4])
    }
    func testCurrentMatchHasADifferentBackground() {
        let t = "a a"
        let ranges = TranscriptHighlighter.matches(in: t, terms: ["a"])
        let s = TranscriptHighlighter.attributed(t, matches: ranges, current: 1)
        let colours = s.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(colours.count, 2); XCTAssertNotEqual(colours[0], colours[1])
    }
    func testNoTermsNoMatches() { XCTAssertTrue(TranscriptHighlighter.matches(in: "x", terms: []).isEmpty) }
    func testDestinationDefaultKeepsOldCallSitesEqual() {
        XCTAssertEqual(LibraryDestination.entry("A"), .entry("A", highlight: nil))
        XCTAssertNotEqual(LibraryDestination.entry("A"), .entry("A", highlight: SearchHighlight(terms: ["x"])))
    }
}
```

- [ ] **Step 2: Run, expect FAIL.**

**Amendment (pre-flight 7) — the word rule changes, and two tests are added:**

```swift
    // The index splits at an apostrophe (Task 3 pins it); the highlighter must too, or the
    // list promises a match the entry shows as "0 of 0".
    func testElidedWordMatchesItsStem() {
        let t = "l'école d'été"
        XCTAssertEqual(TranscriptHighlighter.matches(in: t, terms: ["ecole"]).map { String(t[$0]) }, ["école"])
    }
    // Terms are folded too: SearchQuery.terms lowercases but keeps accents.
    func testAccentedTermMatchesUnaccentedText() {
        XCTAssertEqual(TranscriptHighlighter.matches(in: "etaient", terms: ["étai"]).count, 1)
    }
```

A "word" is a maximal run of Characters where `isLetter || isNumber` — the rule
`SearchQuery.terms` already uses and the one `unicode61` applies — NOT
`enumerateSubstrings(.byWords)`: ICU keeps `l'école` as one word, the index does not. Walk the
ORIGINAL string once, collecting those runs with their ranges; fold each run AND each term with
`folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`; a run matches when
its folded form `hasPrefix` a folded term; the highlighted range is the first
`term.count` Characters of the run when that is well-defined, else the whole run (state which
the tests pin: `["string", "string"]` in `testWordStartPrefixOnly` means the prefix, not the
word). RED proof for the elision test: the `.byWords` implementation returns no match.

The four pattern-match sites on `.entry` (line numbers at `9587f639`): `ContentView.swift:31`
and `EntryPager.swift:40` bind the id (`case .entry(let id)` becomes `case .entry(let id, _)`,
or binds the highlight where it is needed); `Place.swift:195` and `Place.swift:273` are
`case .entry = …` and compile unchanged. There is no `== .entry(…)` comparison in either
target (grep-verified) — keep it that way: an equality test against `.entry(id)` would silently
stop matching a highlighted destination.

Test count for this task after the amendment: **+8**.

- [ ] **Step 3: Implement** — (the `.byWords` instruction in this step is SUPERSEDED by the amendment above) `matches`: fold with `text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`; folding can change character counts for some scripts, so walk the ORIGINAL string's word boundaries (`enumerateSubstrings(in:options: .byWords)`), fold each word, and test `hasPrefix` per term — ranges then come from the original string. Sort by `lowerBound`. `attributed`: background `InkTone.accent.color.opacity(0.35)` for matches, `.opacity(0.7)` for `current`.

- [ ] **Step 4: Run, expect PASS.** RED proof: a `contains`-based implementation makes `testWordStartPrefixOnly` fail (3 hits).

- [ ] **Step 5: regen, full suite, commit** — `feat(#194): SearchHighlight on LibraryDestination.entry; TranscriptHighlighter`

### Task 12: Detail view — highlighted prose, match bar, scroll-to-paragraph

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (init gains `highlight: SearchHighlight?`; `ContentView`'s `navigationDestination(for: LibraryDestination.self)` passes it from the case)
- Modify: `Raconte/App/ContentView.swift` (destination switch)
- Create: `RaconteTests/EntryDetailSearchMatchesTests.swift` (pure model of the bar: `SearchMatchCursor`)
- Modify: `RaconteUITests/SearchUITests.swift` (+1 test)

**Interfaces:**
- Produces: `struct SearchMatchCursor: Equatable { var paragraphMatches: [[Range<String.Index>]]; var current: Int?; var total: Int; var label: String /* "1 of 4" or "0 of 0" */; mutating func next(); mutating func previous(); var currentParagraph: Int? }` in `Raconte/Search/SearchMatchCursor.swift`. Identifiers `detail.search.previous`, `detail.search.next`, `detail.search.count`.

- [ ] **Step 1: Write the failing tests**

```swift
final class SearchMatchCursorTests: XCTestCase {
    func testLabelAndWrap() {
        var c = SearchMatchCursor(paragraphTexts: ["a b", "c a"], terms: ["a"])
        XCTAssertEqual(c.label, "1 of 2"); XCTAssertEqual(c.currentParagraph, 0)
        c.next(); XCTAssertEqual(c.label, "2 of 2"); XCTAssertEqual(c.currentParagraph, 1)
        c.next(); XCTAssertEqual(c.label, "1 of 2")        // wraps
        c.previous(); XCTAssertEqual(c.label, "2 of 2")
    }
    func testNoMatchesIsZeroOfZeroAndNextIsANoOp() {
        var c = SearchMatchCursor(paragraphTexts: ["x"], terms: ["q"])
        XCTAssertEqual(c.label, "0 of 0"); XCTAssertNil(c.currentParagraph)
        c.next(); XCTAssertEqual(c.label, "0 of 0")
    }
}
// UI:
func testOpeningFromSearchShowsTheMatchBar() {
    … as testTypingFindsTheSeededEntryAndOpensIt, then:
    XCTAssertTrue(app.staticTexts["detail.search.count"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["detail.search.count"].label, "1 of 1")
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** In `EntryDetailView`: `@State private var cursor: SearchMatchCursor?` built in `refresh()` after the transcript loads when `highlight != nil` — paragraph texts are `transcript.paragraphs?.map(\.text) ?? [transcript.text ?? ""]`. The prose `ScrollView` gets a `ScrollViewReader`; each paragraph `Text` gets `.id("para.\(index)")` (the single-text branch `.id("para.0")`); when `cursor.currentParagraph` changes, `withAnimation { proxy.scrollTo("para.\(i)", anchor: .center) }` — in `.onChange(of: cursor?.current)` and once in `.task` after the first load. The paragraph `Text`s render `TranscriptHighlighter.attributed(paragraph.text, matches: cursor.paragraphMatches[i], current: cursor.currentIndexWithin(i))` when a cursor exists, else today's rendering untouched (identifiers unchanged; the `accessibilityValue` of the text stays the plain string). The bar: an `HStack` above the prose, shown only when `highlight != nil`, Buttons `chevron.left`/`chevron.right`, `Text(cursor.label)` with `detail.search.count`, `TypeRole.label`. `page(to:)` (next/previous entry) pushes `.entry(id)` with no highlight — verify by reading it; `replaceTopEntry(with:)` in the router also stays highlight-free.

- [ ] **Step 4: Verify** — full unit suite; run `SearchUITests` locally on the simulator (amended 2026-10-10: the simulator works here; the controller pushes for the whole-suite CI run). RED proof for the UI test: run it before the bar exists and watch `detail.search.count` time out.

- [ ] **Step 5: regen, commit** — `feat(#194): entry opens on the match — highlighted prose, match bar, scroll to paragraph`

### Task 13 (A3 close): final review, PR 3

- [ ] Whole-branch review, one fix round, scoped re-review.
- [ ] Counts: unit baseline (**amended, stacked run:** PR 2's own CI job log) + Task 11 (8 after the pre-flight amendment) + Task 12 (2) = **+10**; UI baseline + **1**.
- [ ] PR body smoke: Mac and iPhone — Search → a word → tap a result → the entry opens with the word highlighted and the bar reading "1 of N"; › moves to the next and the page scrolls; ‹ wraps; swipe/arrow to the next entry → no bar, no highlight; Back to the result list keeps the query.
- [ ] **Amendment (stacked run):** PR 3's base is `feat/194-search-place`; its body says "merge #<PR 1>, then #<PR 2>, first". Mark it ready, leave it open; stop. Then comment on the #194 issue with the three PR links, the merge order, and what is deferred (mixed phrase+prefix patterns, trigram substring matching, relevance ranking, entry descriptions, and from the research reply: English stemming, `-excluded` words and `OR`). Do not use a closing keyword next to `#194` anywhere — the issue closes when Nico says the smoke passed.
