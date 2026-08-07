# Staged removal — build prompts (#25)

**Status: UNVERIFIED — pending local run.** Written 2026-08-05 on a machine without
Xcode. Every line number, signature, and fixture name below was read against source at the
current head of `plan/structure-markers`, but **no command in this document has been
executed.** The first machine with Xcode must treat each step's red/green run as the actual
verification.

Three steps. **Step 3 fixes #25** — the issue is not closed until the trashed-skip rule
lands with it, because the resurrection the issue describes has two shapes and staged
removal only closes one of them (§0.3.6). Steps land in order: step 1 adds a type nobody
calls yet, step 2 rewires both delete paths onto it, step 3 hardens the read side. Each is
independently committable and nothing is broken in between.

The bug: `FileManager.removeItem`'s recursive walk deletes children before the parent, so a
mid-walk failure can destroy `entry.json` — the `trashedAt` tombstone — while the audio
survives. The entry then reappears in the library as live and untrashed. The same unguarded
walk exists in **two** places, and issue #25 names only one:
`LibraryScreenModel.deleteEntryPermanently` (`LibraryScreenModel.swift:294`) and
`TrashSweeper.apply` (`TrashSweeper.swift:80`).

The fix: rename the capture directory into `<container>/trash-pending/` first — `rename(2)`
within a volume is atomic — then delete at leisure. Before the rename nothing is touched;
after it the entry is out of every scanned tree. There is no third state.

**Out of scope, explicitly:** no undo of a staged removal, no "second chance" bin, no
change to the 30-day retention rule, no change to `RecoveryPlanner` or `DirectorySnapshot`,
no GRDB, no T6 revision machinery beyond the one rule §0.3.6 names.

## 0. Conventions for every step

### 0.1 Build/test commands

The Xcode project is generated and **steps 1 and 3 add files**, so `xcodegen generate` is
**required** — a new `.swift` file that is not in the regenerated `pbxproj` simply does not
compile into the target, and the failure looks like "cannot find `StagedRemover` in scope"
rather than like a missing file:

```
xcodegen generate
```

Full unit suite (the green gate for every step):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test
```

Focused runs (for red-first evidence), one per step:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/StagedRemovalTests
```

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryTrashTests -only-testing:RaconteTests/TrashSweeperTests
```

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryScannerTests -only-testing:RaconteTests/EntryMetadataStoreTests -only-testing:RaconteTests/TrashSweepTests
```

No UI tests in any step. Trash has no UI test today and this is not the change that should
add one — the whole point of the fix is that the visible behaviour is unchanged on the
happy path.

`project.yml` needs **no** edit: the app target is `sources: [Raconte]` and the test target
`sources: [RaconteTests]` (`project.yml:38`, `:73`), both directory globs. `xcodegen
generate` is still required to pick the new files up.

### 0.2 House rules that bite here

- **XCTest only** — no Swift Testing. `final class XxxTests: XCTestCase`, files flat in
  `RaconteTests/`. Step 1 adds `RaconteTests/StagedRemovalTests.swift`; steps 2 and 3 only
  edit existing test files.
- **Red first or mutation-verified.** Each test below is labelled RED (fails today, must be
  pasted failing before the fix) or GUARD (passes today; earns its keep via a *named*
  mutation that must make it fail). A GUARD test with no mutation is not acceptable
  evidence.
- **`chmod`-based failure injection must skip under root**, or it silently tests nothing.
  Idiom, copied from `LiveTranscriptIntegrityTests.swift:50-54`:

  ```swift
  try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path),
                "running as root — permissions cannot be made to bite")
  ```

  Always pair the seal with a `defer` that unseals. `tearDownWithError` in both trash test
  classes deletes the temp container (`LibraryTrashTests.swift:22-24`,
  `TrashSweeperTests.swift:18-20`), and a sealed directory's children cannot be removed, so
  a missing `defer` leaks temp directories forever.
- **A skip is not a pass.** If a sealing test reports SKIPPED, the run was root and that
  test measured nothing. Say so in the report; do not call the step green.
- **POSIX `rename`, not `FileManager.moveItem`.** Same reasoning `AtomicFile` already
  records (`AtomicFile.swift:8-12`): `rename(2)` is atomic within a volume and fails loudly
  with `EXDEV` across one, where `moveItem` may silently degrade to copy-then-delete — which
  is the non-atomic walk this issue is about, reintroduced under a different name.
- **No directory fsync after the rename.** `AtomicFile` states the project's threat model
  (`AtomicFile.swift:32-37`, `:48-53`): force-kill, not power loss. A dir-fsync would buy
  only power-loss durability, which nothing else here pays for.
- Swift 6 strict concurrency is on. `StagedRemover` is a `Sendable` struct with no mutable
  state, matching `TrashSweeper` (`TrashSweeper.swift:19`) and `LibraryScanner`
  (`LibraryScanner.swift:46`).
- Subagent builds: **leave changes uncommitted** — the parent session reviews the diff, then
  commits. Report red-run and green-run output verbatim.

### 0.3 What was read, and the decisions taken from it

Recorded here rather than smuggled into the steps. Items 1-6 are findings from the
design pass; items 7-11 are the owner's answers to the five questions that pass raised, all
five accepted as recommended.

1. **Staging inside the container but outside `captures/` is invisible to every scan and to
   recovery — verified exhaustively, not assumed.** `contentsOfDirectory` appears exactly
   five times in the whole app and not one of them enumerates the container root:
   `DirectorySnapshot.swift:138` (`capturesRoot`), `:172` (one capture's `segments/`),
   `:203` (one capture's `transcript/`), `FinalizerWorker.swift:191` (one capture's
   `segments/`), and `TrashSweeper.swift:48` (`capturesRoot`).
   `DirectorySnapshot.gather(capturesRoot:)` is the single walker feeding all three
   consumers — recovery (`CaptureCoordinator.swift:190-191`), the library scan
   (`LibraryScanner.swift:59`), and playback (`CapturePlayback.swift:112`). `JournalStore`
   and `JournalCoverStore` read keyed paths and never list. So
   `<container>/trash-pending/` is *structurally* unreachable, which is the same guarantee
   `journals/` already relies on and the same rule `AppContainer` states in prose
   (`AppContainer.swift:6-14`, `:19-23`).

2. **`holdsIrreplaceableArtifacts` is true for every staged directory and that is fine.**
   A staged capture carries `final/recording.m4a`, so `DirectorySnapshot.swift:71-73` would
   protect it — but nothing gathers it, so the planner never sees it and the quarantine rule
   never engages. The staging purge is the only code that may delete it. That keeps
   `TrashSweep`'s existing claim of sole authority (`TrashSweep.swift:95-101`, "Nothing else
   in the app may delete a directory holding an `.m4a` or a transcript") literally true
   rather than quietly false.

3. **Staging name is `<stagingULID>-<captureID>`.** Fresh ULID from `ULID.make()`
   (`ULID.swift:14`) makes collision unrepresentable: `rename(2)` onto a *non-empty*
   directory fails with `ENOTEMPTY`, so a purge that failed once and left
   `trash-pending/<captureID>` behind would block every future delete of that id — reachable
   after M4 sync restores an entry, or after a container restore. The captureID suffix is
   pure forensics for a container pull; nothing parses the name back.

4. **`TrashSweeper` needs the container root and gets it as an optional with the existing
   derivation as its default.** `AppContainer.containerRoot(capturesRoot:)`
   (`AppContainer.swift:65-67`) is `deletingLastPathComponent()`, and every construction site
   in the repo passes a captures root whose parent is the real container — verified at
   `LibraryScreenModel.swift:85` and at the three test sites that override
   `journalsContainerRoot` (`LibraryTrashTests.swift:27`, `LibraryScreenModelTests.swift:28`,
   `JournalCaptureContextTests.swift:72`), all of which pass the actual parent.
   `LibraryScreenModel` already has `containerRoot` in scope at `:83` and passes it
   explicitly, so the default is a fallback and not the load-bearing path.

5. **Delete Now's failure fixture inverts, and the existing test must be rewritten.**
   `LibraryTrashTests.testDeleteNowReturnsFalseWhenRemovalFails` (`:240-259`) seals the
   *capture directory* at 0o555. Under staged removal the rename needs write permission on
   the **parent** (`captures/`), so that fixture no longer reliably blocks anything; the
   failure fixture becomes a sealed `capturesRoot`. This is the whole fix in one sentence:
   **today, sealing `capturesRoot` destroys the sidecar; after this change, sealing
   `capturesRoot` changes nothing.** That test's own comment (`:225-239`) predicted this fix
   and named staged removal as the answer — it should be rewritten, not deleted, and the
   comment updated to say it landed.

6. **Staged removal does not close the resurrection hole on its own, so the read-side rule
   ships in the same change (step 3).** `EntryMetadataStore.write` creates its parent
   directory (`EntryMetadataStore.swift:85-88`), so a `restoreEntry` landing *after* a
   rename recreates `captures/<id>/entry.json` with `trashedAt: nil` and nothing else.
   Today that self-heals — no m4a, no transcript, no frames, so
   `LibraryScanner.holdsSomethingToShow` (`LibraryScanner.swift:104-107`) skips it and
   recovery deletes it — but it is the identical shape T6 rev 2 §6 flags as A2.3
   (`docs/plans/2026-08-03-t6-revision-chain-design.md:549-558`), where a recreated
   `canonical-0.json` makes `holdsIrreplaceableArtifacts` true, quarantines the directory
   permanently, and resurrects the entry as live. Step 3 installs the discipline before the
   writer that would make it fatal exists.

7. **Owner answer 1 — Delete Now reports success once the rename lands.** The return value
   now tracks the rename, not the unlink: after the rename the entry *is* gone from the
   library and cannot come back, and whether the bytes are already reclaimed is bookkeeping.
   A purge failure retries silently at the next launch. Consequence, intended: the "Couldn't
   delete this recording" alert (`TrashView.swift:67-71`) now means exactly one thing —
   *the entry is still there* — where today it can fire over an entry that is half gone.

8. **Owner answer 2 — the 30-day sweep is fixed in the same step.** `TrashSweeper.apply`
   (`TrashSweeper.swift:71-89`) carries the identical unguarded `removeItem` at `:80`, so
   closing only Delete Now would leave the same data-loss walk running unattended once a
   day. Both paths go through one `StagedRemover`.

9. **Owner answer 3 — purge after each staging, plus the launch-time safety net.** Delete
   Now purges immediately after staging; `TrashSweeper.run()` purges at the end of every
   run, which is already once per launch via `LibraryScreenModel.sweepTrash()`
   (`LibraryScreenModel.swift:308-314`) ← `CaptureView.swift:217`. No new launch hook is
   needed and none may be added: that call site is already ordered after `recoverAtLaunch`,
   after the finalizer drains, and after the first `rescan` (`CaptureView.swift:201-218`),
   which is exactly where a purge belongs.

10. **Owner answer 4 — `trash-pending/` is excluded from backup.** Set
    `isExcludedFromBackup` when the staging root is created (step 1, inside
    `StagedRemover`), so a deleted recording cannot reach iCloud backup during the
    stage→purge window. Nothing else in the app sets this flag today; it is set on the
    staging root only, never on `captures/`.

11. **Owner answer 5 — the trashed-skip rule is in scope (step 3), in two places.**
    - **Read side, `LibraryScanner.build`:** the sidecar is read *before* the
      `holdsSomethingToShow` gate, and a capture whose sidecar reads `trashedAt != nil` is
      always emitted as a row regardless of what else the directory holds. An **unreadable**
      sidecar keeps today's behaviour exactly — the gate applies and `.metadataUnreadable`
      is flagged — because fabricating "trashed" or "live" from a failed read is the one
      thing `SidecarState`'s three answers exist to prevent (`TrashSweep.swift:34-46`).
    - **Write side, `EntryMetadataStore.update`:** a new `EntryMetadataError.captureMissing`
      thrown when the capture directory is absent, so an edit can never *create* a capture
      directory. Every UI edit path already routes through `update` and already reports
      `false` to an alert (`LibraryScreenModel.swift:191-222`, `:254-280`).
    - **Sweep decision layer: no change.** `TrashSweep.decide`
      (`TrashSweep.swift:126-140`) already decides on `trashedAt` alone and consults nothing
      about the manifest, the segments, the `.m4a` or the transcript — its header comment
      says so at `:95-101`. Step 3 pins that with a GUARD test and a named mutation rather
      than editing working code.

12. **Rejected: serializing the rename inside `EntryMetadataStore`.** A
    `withExclusiveAccess { }` primitive on the actor would let Delete Now and the sweep stage
    a directory *under the same serialization as every sidecar write*, closing the
    restore-races-delete window in §0.3.6 completely rather than narrowing it. Not done:
    it couples a directory-level operation to the metadata store, it would have to be
    threaded into `TrashSweeper` (which today needs no store at all), and the residual
    window is harmless in shipping code — a recreated directory holding only `entry.json`
    is `noDurableContent`, invisible, and deleted by the next recovery pass. It stops being
    harmless when T6's canonical writer lands, and T6 already specifies its own answer for
    that (skip any capture with `trashedAt != nil`, doc `:549-558`). Revisit there, not
    here.

13. **Rejected: a new `EntryDegradation` flag for "trashed, nothing left to restore".**
    After step 3 a trashed capture with no durable content becomes a visible Trash row with
    a 0:00 duration and no snippet. A `.recordingMissing` flag would be more honest, but it
    costs three coupled edits (`allDeclared`, `reasonTable`, and
    `EntryDegradationTableTests`, whose bit-count tripwire fails otherwise) for a state only
    reachable from a *pre-fix* partial deletion. Named as available if the owner ever sees
    one on device. Related accepted consequence: **restoring such an entry makes it vanish**
    — with `trashedAt` cleared it fails the `holdsSomethingToShow` gate again and is skipped
    as `noDurableContent`. That is the honest answer (there is nothing to restore *to*) and
    it is counted in the DEBUG `skipped` note (`LibraryView.swift:124-134`).

### 0.4 Conflict found with the T6 design's expectations

One, and it is a scoping conflict rather than a contradiction. **T6 §6
(`docs/plans/2026-08-03-t6-revision-chain-design.md:549-558`) states the rule on the
*writer* side** — head rebuild, promotion, and stale-draft close each skip a capture whose
sidecar reports `trashedAt != nil` — and the failure it describes is a directory where
`entry.json` is *gone* ("no `entry.json` (so no `trashedAt`)") and a canonical revision has
reappeared. **A read-side rule cannot help there: there is no tombstone left to read.** So
step 3's scanner rule and T6's writer rule are complementary, not substitutes, and closing
#25 must not be read as closing A2.3.

Step 3 therefore carries a doc amendment (a short paragraph appended to T6 §6) recording
that the read-side half landed early with #25, that `EntryMetadataStore.update` now refuses
to create a capture directory, and that **T6 still owes the writer-side skip for every path
that writes into `transcript/`** — that clause is still load-bearing and must not be dropped
on the grounds that #25 "already fixed the trash race".

Nothing else in §6 or §9 conflicts. §9 item 7 (`:982-990`) independently concludes that an
authorized deletion "must take a path the recovery planner never sees, i.e. `TrashSweeper`'s"
— which is exactly what staged removal builds, and the staging directory makes that
separation structural rather than conventional.

### 0.5 Step order

Strictly ordered. Step 1 adds a type with no callers (nothing can regress). Step 2 rewires
both delete paths onto it and is where the behaviour changes. Step 3 is independent of the
staging mechanism but is what makes #25 actually closed, so it commits last and carries the
`fixes #25` trailer. If a session runs more than one, land and commit each before starting
the next — steps 2 and 3 both touch `RaconteTests/LibraryTrashTests.swift`.

---

## Step 1 — `StagedRemover`: atomic rename into `trash-pending/`, and a purge

Adds a type and its paths. **No call site changes; behaviour on disk is unchanged.**

### Files

**Edit: `Raconte/Library/AppContainer.swift`** — one name, two path functions, and the
layout comment (`:11-14`) gains a `trash-pending/<name>/` line so the doc-comment map stays
the whole map.

```swift
/// Where a capture directory waits between its atomic rename out of `captures/` and its
/// actual removal (#25). A sibling of `captures/`, never inside it, for the reason this
/// type's header already gives: a stray child of `captures/` is walked by
/// `DirectorySnapshot.gather` and handed to the recovery planner. A staged directory
/// still holds `final/recording.m4a`, so being unreachable by that walk is what keeps
/// the quarantine rule from adopting it forever.
static let trashPendingDirectoryName = "trash-pending"

static func trashPendingRoot(containerRoot: URL) -> URL
static func trashPendingURL(containerRoot: URL, name: String) -> URL
```

**New: `Raconte/Library/StagedRemoval.swift`**

```swift
enum StagedRemovalError: Error, Equatable {
    /// Nothing at `captures/<id>/` to stage.
    case captureDirectoryMissing
    /// A POSIX call failed. Mirrors `AtomicFileError.posix` deliberately rather than
    /// reusing it: that type is about replacing a file, this is about moving a tree.
    case posix(operation: String, code: Int32)
}

struct StagedPurgeResult: Sendable, Equatable {
    var removed: [String] = []
    var failed: [String] = []
    var isEmpty: Bool { removed.isEmpty && failed.isEmpty }
}

struct StagedRemover: Sendable {
    let capturesRoot: URL
    let containerRoot: URL
    var mintStagingID: @Sendable () -> String = ULID.make

    init(capturesRoot: URL, containerRoot: URL? = nil,
         mintStagingID: @escaping @Sendable () -> String = ULID.make)

    /// Atomically move `captures/<captureID>/` out of every scanned tree. Returns the
    /// staged directory's name. After this returns the entry is gone from the library and
    /// cannot be recovered by any in-app path — the one-way door, and the correct
    /// semantics for both "Delete Now" and the 30-day sweep.
    func stage(captureID: String) throws -> String

    /// Remove everything in `trash-pending/`. Best effort: a child that will not delete is
    /// reported and left for the next launch. An absent staging root is an empty success —
    /// that is a fresh install, not a failure.
    func purge() -> StagedPurgeResult
}
```

`stage` implementation notes, all load-bearing:

- `guard` the source exists and is a directory → `.captureDirectoryMissing`.
- Create the staging root with `withIntermediateDirectories: true`, then set
  `isExcludedFromBackup` on it (owner answer 4). Use a `var values = URLResourceValues();
  values.isExcludedFromBackup = true; try? url.setResourceValues(&values)` on a `var` copy of
  the root URL — `try?` because failing to set a backup hint must never block a deletion.
- `rename(srcPath, dstPath)`; non-zero → `.posix(operation: "rename", code: errno)`.
- Name is `"\(mintStagingID())-\(captureID)"`.
- No fsync (§0.2).

`purge` reads `contentsOfDirectory(atPath:)` on the staging root — this is the **sixth and
last** directory enumeration in the app, and it is over `trash-pending/`, not the container
root, so §0.3.1's inventory stays exact.

### Tests — write first

**New: `RaconteTests/StagedRemovalTests.swift`.** Fixture shape copied from
`TrashSweeperTests.swift:8-47`: a temp `containerRoot`, `capturesRoot` derived via
`AppContainer.capturesRoot(containerRoot:)`, `tearDownWithError` removing the container, and
a `writeCapture(_:)` helper that lays down `segments/000000.pcm`, `manifest.json`,
`final/recording.m4a`, and `entry.json` — i.e. a directory that
`holdsIrreplaceableArtifacts` protects.

- **1.1 `testStageRenamesTheWholeDirectoryOutOfCapturesRoot` — RED** (the type does not
  exist yet, so every test in this class is red until it does; "red" here means the class
  does not compile, which must still be captured, then each assertion seen passing). Assert
  `captures/<id>` gone, `trash-pending/<name>/final/recording.m4a` present, `entry.json`
  present and still decoding with `trashedAt` set.
- **1.2 `testStageLeavesCapturesRootOtherwiseUntouched`** — a second capture is unaffected.
- **1.3 `testStagedDirectoryIsInvisibleToDirectorySnapshotGather`** — the invisibility
  proof, and the single most important test in the step. Stage, then
  `DirectorySnapshot.gather(capturesRoot:)` and assert `captures.isEmpty`. Modelled on
  `LibraryScannerTests.testJournalsRegistryIsNotEnumeratedAsACapture` (`:135`).
- **1.4 `testStagedDirectoryIsInvisibleToLibraryScanAndToTrashSweeperGather`** — same, via
  `LibraryScanner(capturesRoot:containerRoot:).scan()` (`items` and `skipped` both empty)
  and `TrashSweeper.gather(capturesRoot:)` (empty).
- **1.5 `testStageFailsCleanlyWhenCapturesRootIsUnwritable`** — **the #25 assertion.** Seal
  `capturesRoot` 0o555 (+ `XCTSkipIf` + `defer` unseal), `stage` must throw `.posix`, and
  then assert **`entry.json` still decodes and `trashedAt` is still non-nil**, the `.m4a` is
  still present, and `trash-pending/` is empty or absent. This is the assertion the issue is
  about; everything else in the step is scaffolding for it.
- **1.6 `testStageOfAMissingCaptureThrowsCaptureDirectoryMissing`**.
- **1.7 `testTwoStagingsOfTheSameCaptureIDCannotCollide`** — inject
  `mintStagingID` returning a counter, stage id A, recreate `captures/<A>`, stage again,
  assert two distinct children in `trash-pending/` and both intact. **Mutation:** change the
  staged name to bare `captureID` → this test must fail (the second `rename` hits
  `ENOTEMPTY`). This is the test that justifies the naming decision in §0.3.3.
- **1.8 `testPurgeRemovesEveryStagedDirectory`** — two staged, `removed.count == 2`,
  `failed.isEmpty`, staging root now empty.
- **1.9 `testPurgeReportsWhatItCannotRemoveAndLeavesItForNextLaunch`** — seal one staged
  directory's *parent* (the staging root) 0o555 (+ `XCTSkipIf` + `defer`), assert the name
  appears in `failed` and the directory is still on disk.
- **1.10 `testPurgeOverAnAbsentStagingRootIsAnEmptySuccess`**.
- **1.11 `testPurgeIsIdempotent`** — purge twice; the second is empty, not a failure.
- **1.12 `testStagingRootIsExcludedFromBackup`** — after the first `stage`, read
  `resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true` on the
  staging root. **Mutation:** delete the `setResourceValues` call → must fail. Note: if this
  assertion cannot be made to hold on macOS (the key is honoured on both platforms but is a
  hint), report the measured behaviour rather than weakening the assertion silently — and
  keep the production line either way, since iOS is the device that backs up.
- **1.13 `testStageThenCrashLeavesNothingScannableAndIsSweptByTheNextPurge`** — stage, run
  no purge (this *is* the crash), then build a fresh `StagedRemover` (a new launch) and
  purge: staging empty, `captures/` empty, and `DirectorySnapshot.gather` empty throughout.

### Red/green evidence

Write all 13 tests first. The class will not compile against unmodified source — capture
that output (it is the honest red for a new type). Then add `AppContainer`'s paths and
`StagedRemoval.swift`, `xcodegen generate`, run focused to green, then run both named
mutations (1.7, 1.12) and paste each failure, reverting after each.

Green gate: full `-scheme Raconte` suite. Nothing else in the suite may change — no call
site was touched.

Commit:

```
library: StagedRemover — atomic rename into trash-pending, then purge (#25)
```

### Subagent prompt — step 1

```
You are implementing step 1 of docs/plans/2026-08-05-staged-removal-build-prompts.md in the
raconte repo (branch plan/structure-markers). Read that file's §0 and Step 1 in full first,
then read Raconte/Library/AppContainer.swift (all of it), Raconte/Library/TrashSweeper.swift,
Raconte/Capture/AtomicFile.swift, Raconte/Library/ULID.swift, and
RaconteTests/TrashSweeperTests.swift lines 1-60 (the fixture shape you will copy).

Background: permanent delete and the 30-day sweep both call FileManager.removeItem on a
whole capture directory. That walk deletes children before the parent, so a mid-walk failure
can destroy entry.json (the trashedAt tombstone) while the audio survives, and the entry
then reappears in the library as live. Issue #25. The fix is staged removal: rename the
directory into <container>/trash-pending/ first (rename(2) is atomic within a volume), then
delete at leisure.

This step adds the mechanism ONLY. Do not change any call site. deleteEntryPermanently and
TrashSweeper.apply keep calling removeItem — step 2 rewires them. Nothing on disk behaves
differently when this step lands.

Task:
1. AppContainer gains `trashPendingDirectoryName = "trash-pending"`,
   `trashPendingRoot(containerRoot:)`, and `trashPendingURL(containerRoot:name:)`, plus a
   `trash-pending/<name>/` line in the layout doc comment at the top of the file. The
   staging root is a SIBLING of captures/, never inside it — that placement is the entire
   safety property (a stray child of captures/ gets walked by DirectorySnapshot.gather and
   handed to the recovery planner).
2. New file Raconte/Library/StagedRemoval.swift with StagedRemovalError, StagedPurgeResult,
   and `struct StagedRemover: Sendable` exactly as specified in the plan's Step 1.
   - stage(captureID:) throws -> String: guard the source directory exists, create the
     staging root with withIntermediateDirectories, set isExcludedFromBackup on it (try? —
     a backup hint must never block a deletion), then POSIX rename(2). Staged name is
     "<freshULID>-<captureID>" using an injectable mintStagingID defaulting to ULID.make.
   - purge() -> StagedPurgeResult: removeItem each child of the staging root, collect names
     removed and names that failed. Absent root = empty success.
   - Use POSIX rename(), NOT FileManager.moveItem — moveItem may silently fall back to
     copy-then-delete across volumes, which is the non-atomic walk this issue is about.
   - No fsync: AtomicFile.swift lines 32-37 and 48-53 state this project's threat model is
     force-kill, not power loss.

TDD, in this order:
1. Write all 13 tests named in the plan's Step 1 into a NEW file
   RaconteTests/StagedRemovalTests.swift, copying the temp-container fixture shape from
   RaconteTests/TrashSweeperTests.swift lines 8-47. Every chmod-based test needs BOTH a
   `defer` that unseals AND
   `try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "running as root — permissions cannot be made to bite")`.
   A SKIPPED test measured nothing — if any sealing test skips, say so and do not call the
   run green.
2. Run `xcodegen generate` (this step ADDS files — without it the new file is not in the
   target and you get "cannot find StagedRemover in scope"), then run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/StagedRemovalTests`
   and CAPTURE the output. It will not compile — that is the honest red for a new type.
3. Implement, re-run focused to green, then the FULL suite:
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
   Nothing else in the suite may change — you touched no call site.
4. Mutation checks (run each, observe the failure, revert each):
   (a) make the staged name the bare captureID instead of "<ULID>-<captureID>" ->
       testTwoStagingsOfTheSameCaptureIDCannotCollide must fail (second rename hits
       ENOTEMPTY);
   (b) delete the setResourceValues(isExcludedFromBackup) call ->
       testStagingRootIsExcludedFromBackup must fail.

Swift 6 strict concurrency is on. XCTest only. Do not commit. Report: diff, red output,
green output, mutation results.
```

---

## Step 2 — both delete paths go through staging (Delete Now + the 30-day sweep)

This is where behaviour changes.

### Files

**Edit: `Raconte/Library/LibraryScreenModel.swift`**

`deleteEntryPermanently` (`:288-304`) keeps its sidecar guard verbatim — the disk decides,
not the row the button was drawn from — and replaces the `removeItem` body:

```swift
/// …existing doc comment, plus:
///
/// **The rename is the deletion.** `stage` moves the directory out of every scanned tree
/// in one atomic step (#25); the purge that follows only reclaims bytes. So this returns
/// `true` once the rename lands even if the purge fails — the entry is gone from the
/// library and cannot come back, and a purge failure retries at the next launch. The
/// alert on `false` now means exactly one thing: the entry is still there.
@discardableResult
func deleteEntryPermanently(_ captureID: String) async -> Bool {
    guard let metadata = try? await entryMetadataStore.read(captureID: captureID),
          metadata.isTrashed else { return false }
    let remover = self.remover            // stored, built in init
    let staged = await Task.detached(priority: .userInitiated) { () -> Bool in
        do { _ = try remover.stage(captureID: captureID) } catch { return false }
        _ = remover.purge()
        return true
    }.value
    await rescan()
    return staged
}
```

`init` builds `StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)`
alongside the sweeper at `:85`, and passes the same `containerRoot` into `TrashSweeper`.

**Edit: `Raconte/Library/TrashSweeper.swift`**

- `init(capturesRoot:containerRoot:now:)` with `containerRoot: URL? = nil` defaulting to
  `AppContainer.containerRoot(capturesRoot:)`, so all four existing construction sites keep
  compiling.
- `apply(_:capturesRoot:)` becomes `apply(_:remover:)`: `.deleteCaptureDirectory` calls
  `remover.stage(captureID:)`; a throw is recorded as the existing
  `SkippedSweep(.deleteFailed(…))`, unchanged. `result.deleted` keeps its name and its
  meaning *from the library's point of view* — the entry is gone — with one doc sentence
  saying so.
- `run()` ends with `remover.purge()` and folds the result in (owner answer 3: this is the
  launch-time safety net that clears whatever a crash left staged).

**Edit: `Raconte/Library/TrashSweep.swift`** — `TrashSweepResult` (`:86-91`) gains:

```swift
/// Staged directories the purge could not remove. Not a `SkippedSweep`: there is no
/// capture id to attach — the capture is already gone from `captures/` and this is a
/// disk-space leak, not an entry stuck in the trash. Retried every launch.
var pendingRemovalFailures: [String] = []
```

`isEmpty` includes it.

**Edit: `Raconte/Library/UI/LibraryView.swift`** — `sweepNote` (`:137-150`) fires when
`!sweep.skipped.isEmpty || !sweep.pendingRemovalFailures.isEmpty`, and appends
`", N pending"` when non-empty. DEBUG only, same as today: a staging directory that never
purges is a leak nothing else would ever mention.

Not touched: `TrashSweep.decide`, `TrashPolicy`, `TrashView`, `EntryDetailView`, the swipe
actions, `RecoveryPlanner`, `RecoveryExecutor`, `DirectorySnapshot`.

### Tests — write first

**Edit: `RaconteTests/LibraryTrashTests.swift`**, new MARK section
`// MARK: issue #25 — Delete Now stages, it does not walk`:

- **2.1 `testDeleteNowRemovesATrashedEntry`** — existing (`:189-200`), must stay green
  unchanged. The happy path is byte-identical from outside.
- **2.2 `testDeleteNowLeavesNothingStaged`** — GUARD. After a successful Delete Now,
  `trash-pending/` is empty (the purge ran). **Mutation:** delete the `purge()` call from
  `deleteEntryPermanently` → must fail. Pins owner answer 3.
- **2.3 `testDeleteNowSucceedsWhenTheStagedPurgeFails`** — RED. Stage-then-seal: seal the
  staging root before the delete (create it first via a throwaway `StagedRemover`, then
  0o555, + `XCTSkipIf` + `defer`). Assert `deleteEntryPermanently` returns **`true`**, the
  entry is absent from `model.items` and `model.trashed`, `captures/<id>` is gone, and the
  staged directory survives. This is owner answer 1 and it is red today for two reasons at
  once (today there is no staging, and today the walk would report failure).
- **2.4 `testDeleteNowReturnsFalseWhenStagingFails`** — **rewrite of
  `testDeleteNowReturnsFalseWhenRemovalFails` (`:240-259`)**. Seal `capturesRoot` 0o555, not
  the capture directory. Assert `false`, the directory survives, `metadata(idA).trashedAt`
  is still non-nil, and `model.trashed == [idA]`. Update the existing comment block
  (`:225-239`) to record that the staged-removal fix it called for has landed, and that
  sealing `capturesRoot` — the fixture that used to destroy the sidecar — now changes
  nothing.
- **2.5 `testDeleteNowRefusesAnEntryThatIsNotTrashed` / `2.6 …RefusesAnUnreadableSidecar`** —
  existing (`:203`, `:214`), must stay green unchanged.
- **2.7 `testDeleteNowSurvivesAnUnwritableCaptureDirectory`** — **write this one LAST, and
  drop it if the filesystem disagrees.** The claim is that an unwritable *child* can no
  longer block the delete, which is the shape of the improvement. But POSIX requires write
  permission on a directory being moved to a *different parent*, because its `..` entry must
  be updated, and whether APFS enforces that is a measured fact this document does not have.
  If it fails for that reason: **delete the test and record the measured behaviour in this
  section of the plan** — do not weaken it into something that asserts nothing, and do not
  change production code to make it pass.

**Edit: `RaconteTests/TrashSweeperTests.swift`**, same MARK:

- **2.8 `testExpiredCaptureIsStagedNotWalked`** — RED. Use a `TrashSweeper` whose remover is
  reachable, or assert on disk: after `run()`, `captures/` no longer holds the id and — with
  the purge suppressed by sealing the staging root — `trash-pending/` does. Simplest honest
  form: seal the staging root, run, assert the capture is out of `captures/`, one child in
  `trash-pending/`, and `result.pendingRemovalFailures.count == 1`.
- **2.9 `testSweepPurgesWhatItStagedInTheSameRun`** — GUARD. Normal run: `deleted == [idA]`,
  `captures/` empty of it, `trash-pending/` empty, `pendingRemovalFailures` empty.
  **Mutation:** remove the `purge()` from `run()` → must fail with a leftover staged
  directory.
- **2.10 `testSweepPurgesAStagingDirectoryLeftByAPreviousLaunch`** — pre-create a staged
  directory by hand, run a sweep with nothing expired, assert it is gone and `deleted` is
  empty. Owner answer 3's safety net.
- **2.11 `testSweepOverAnUnwritableCapturesRootLosesNoSidecar`** — RED. Seal `capturesRoot`,
  run, assert the expired capture is untouched, its `entry.json` still decodes with
  `trashedAt` set, and it is reported as `.deleteFailed`. **This is the #25 assertion for
  the sweep path** — the one the issue does not mention.
- **2.12 `testSweepIsIdempotent` / `2.13 testUnreadableSidecarIsSkippedAndLeftByteForByte`** —
  existing (`:172`, `:121`), must stay green unchanged. 2.13 is the "sweep never touches an
  unreadable sidecar" invariant and it must not move.

### Red/green evidence

Focused run:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryTrashTests -only-testing:RaconteTests/TrashSweeperTests
```

2.3, 2.4, 2.8 and 2.11 must be seen failing before any source change. Paste that output.
Implement, re-run focused to green, then run the two named mutations (2.2, 2.9) and paste
each failure, reverting after each.

Green gate: full `-scheme Raconte` suite, with `LibraryScannerTests` and `TrashSweepTests`
untouched and green.

Commit:

```
library: stage-then-purge both permanent-delete paths (#25)
```

### Subagent prompt — step 2

```
You are implementing step 2 of docs/plans/2026-08-05-staged-removal-build-prompts.md in the
raconte repo (branch plan/structure-markers). Step 1 must already be committed —
Raconte/Library/StagedRemoval.swift exists and StagedRemovalTests is green. Read the plan's
§0 and Step 2 in full, then Raconte/Library/LibraryScreenModel.swift lines 81-105 and
241-315, Raconte/Library/TrashSweeper.swift (all), Raconte/Library/TrashSweep.swift lines
79-141, and RaconteTests/LibraryTrashTests.swift lines 185-293.

Background: two places still call FileManager.removeItem on a whole capture directory —
LibraryScreenModel.deleteEntryPermanently (line ~294) and TrashSweeper.apply (line ~80).
That recursive walk deletes children before the parent, so a mid-walk failure can destroy
entry.json (the trashedAt tombstone) while the audio survives, and the entry then reappears
in the library as live. Issue #25 names only the first; the second has the identical bug.
Both now go through StagedRemover: an atomic rename into trash-pending/, then a purge.

Task:
1. LibraryScreenModel: build a StagedRemover in init beside the TrashSweeper (line ~85),
   passing the containerRoot already computed at line ~83; pass that same containerRoot into
   TrashSweeper. Rewrite deleteEntryPermanently's body to stage-then-purge, KEEPING the
   existing sidecar guard verbatim. IMPORTANT SEMANTIC CHANGE: it returns true once the
   RENAME lands, even if the purge fails — the entry is gone from the library and cannot
   come back; a purge failure retries at the next launch. The alert on false must now mean
   exactly one thing: the entry is still there.
2. TrashSweeper: init gains `containerRoot: URL? = nil` defaulting to
   AppContainer.containerRoot(capturesRoot:) so existing construction sites keep compiling.
   apply()'s .deleteCaptureDirectory calls remover.stage instead of removeItem; a throw is
   still recorded as SkippedSweep(.deleteFailed(...)). run() ends with remover.purge().
3. TrashSweepResult gains `var pendingRemovalFailures: [String] = []` (staged names the
   purge could not remove) and includes it in isEmpty.
4. LibraryView's DEBUG sweepNote (line ~137-150) also fires on pendingRemovalFailures and
   appends ", N pending".
Do NOT touch TrashSweep.decide, TrashPolicy, TrashView, EntryDetailView, RecoveryPlanner,
RecoveryExecutor, or DirectorySnapshot.

TDD, in this order:
1. Add the tests named in the plan's Step 2 to RaconteTests/LibraryTrashTests.swift and
   RaconteTests/TrashSweeperTests.swift. Note 2.4 REWRITES the existing
   testDeleteNowReturnsFalseWhenRemovalFails (line ~240): its fixture must now seal
   capturesRoot, not the capture directory, because the rename needs write permission on the
   PARENT. Update that test's long comment block (lines ~225-239) to record that the staged
   removal it asked for has landed. Every chmod test needs a `defer` unseal AND
   `try XCTSkipIf(FileManager.default.isWritableFile(atPath:), "running as root — permissions cannot be made to bite")`.
   A SKIPPED test measured nothing.
   Write testDeleteNowSurvivesAnUnwritableCaptureDirectory LAST. If it fails, that is
   probably APFS enforcing the POSIX rule that moving a directory to a new parent needs
   write permission on the directory itself (its `..` must be updated). In that case DELETE
   the test and report the measured behaviour — do NOT weaken it and do NOT change
   production code to make it pass.
2. Before changing any source, run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryTrashTests -only-testing:RaconteTests/TrashSweeperTests`
   and CAPTURE the failing output. testDeleteNowSucceedsWhenTheStagedPurgeFails,
   testDeleteNowReturnsFalseWhenStagingFails, testExpiredCaptureIsStagedNotWalked and
   testSweepOverAnUnwritableCapturesRootLosesNoSidecar must all be seen failing.
3. Implement, re-run focused to green, then the FULL suite:
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
   testSweepIsIdempotent and testUnreadableSidecarIsSkippedAndLeftByteForByte must still
   pass unchanged — the sweep never touching an unreadable sidecar is a standing invariant.
4. Mutation checks (run each, observe the failure, revert each):
   (a) delete the purge() call from deleteEntryPermanently -> testDeleteNowLeavesNothingStaged
       must fail;
   (b) delete the purge() call from TrashSweeper.run() ->
       testSweepPurgesWhatItStagedInTheSameRun must fail.

Swift 6 strict concurrency is on. XCTest only. Do not commit. Report: diff, red output,
green output, mutation results.
```

---

## Step 3 — a trashed capture is trash, whatever else the directory holds (fixes #25)

Staged removal makes the *destroy* path atomic. This step makes the *read* path refuse to
be fooled by a directory that has been half-destroyed or half-recreated — which is what
actually closes the resurrection the issue describes. See §0.4 for what it does and does not
close relative to T6.

### Files

**Edit: `Raconte/Library/LibraryScanner.swift`**

`build` (`:81-99`) currently gates on `holdsSomethingToShow` *before* anything reads the
sidecar, and `item(for:)` (`:109-142`) reads it afterwards. Hoist the sidecar read out of
`item(for:)` into a small `metadata(for:)` returning `(EntryMetadata, EntryDegradation)`,
call it first, and gate on it:

```swift
for capture in snapshot.captures {
    let (metadata, metadataDegradation) = Self.metadata(for: capture)
    // A tombstone outranks the durable-content gate (#25). An entry the owner deleted
    // must stay reachable in the Trash view — to restore or to delete now — whatever
    // state its files are in, including the half-destroyed directories a pre-staging
    // permanent delete could leave behind. An UNREADABLE sidecar is not a tombstone and
    // is not the absence of one: it falls through to the gate exactly as before, because
    // answering "trashed" or "live" from a read that failed is the one thing
    // `SidecarState`'s three answers exist to prevent.
    guard metadata.isTrashed || holdsSomethingToShow(capture) else {
        result.skipped.append(SkippedCapture(captureID: capture.captureID,
                                             reason: .noDurableContent))
        continue
    }
    items.append(item(for: capture, metadata: metadata,
                      metadataDegradation: metadataDegradation, registry: registry))
}
```

`item(for:…)` takes the metadata it no longer reads. No new degradation flag (§0.3.13). No
change to `holdsSomethingToShow`, to `EntryListFilter`, or to the three derived lists in
`LibraryScreenModel` (`:148-152`) — a trashed row already goes only to `trashed`.

**Edit: `Raconte/Library/EntryMetadataStore.swift`**

```swift
enum EntryMetadataError: Error, Equatable {
    case unreadable(String)
    /// There is no `captures/<id>/` to write into. `write` creates intermediate
    /// directories, so without this an edit could *recreate* a capture directory that a
    /// staged removal had just moved away — resurrecting a deleted entry from a restore
    /// tap that lost a race (#25, and T6 §4.6's A2.3).
    case captureMissing
}
```

`update` (`:47-54`) gains the guard as its first statement. Only `update` — the static
`write(_:url:)` keeps `createDirectory` (`:85-88`), because the capture path legitimately
writes the journal/backdate sidecar right after `SegmentStore.begin()` creates the directory
(`CaptureView.swift:239-245`) and the low-level primitive is not where this rule belongs.
State the residual honestly in the doc comment: the guard closes the ordinary ordering (a
restore tapped after the stage), not a true race between the guard and the write — §0.3.12
records why the fuller answer was rejected.

**Edit: `docs/plans/2026-08-03-t6-revision-chain-design.md`** — append one paragraph to §6,
immediately after the A2.3 discussion at `:549-558`, recording that the read-side half
landed with #25, that `EntryMetadataStore.update` now refuses to create a capture directory,
and that **the writer-side skip is still owed by T6** for every path that writes into
`transcript/` — because the failure A2.3 describes has *no `entry.json` left to read*, so no
read-side rule can reach it. Do not edit any other section.

Not touched: `TrashSweep.decide` — it already decides on `trashedAt` alone
(`TrashSweep.swift:126-140`, header at `:95-101`). Step 3 pins it with a test, not an edit.

### Tests — write first

**Edit: `RaconteTests/LibraryScannerTests.swift`**:

- **3.1 `testTrashedCaptureWithNothingDurableIsStillListed` — RED.** A directory holding
  only `entry.json` with `trashedAt` set: assert one item, `skipped.isEmpty`, and that the
  `trashedOnly` filter finds it. Today it is skipped as `noDurableContent` and is invisible
  in both the library *and* the Trash view — the mirror-image outcome of the same #25 walk
  (the tombstone survived and the audio died).
- **3.2 `testTrashedCaptureWithNothingDurableIsNeverInTheLiveList` — GUARD.** Same fixture,
  `excludeTrashed` filter → empty. **Mutation:** make the new guard emit the row into
  `items` unconditionally without the trash filter applying → must fail. Pins that the rule
  changes trash membership only, never live visibility.
- **3.3 `testUnreadableSidecarWithNothingDurableIsStillSkipped` — GUARD.** A directory with
  an undecodable `entry.json` and nothing else: still skipped, still `noDurableContent`.
  **Mutation:** treat an unreadable sidecar as trashed (`catch { metadata.trashedAt = … }`)
  → must fail. This is owner answer 5's "never fabricate an answer from a failed read", and
  it is the test that stops the next person from collapsing the three answers into two.
- **3.4 `testEmptyCaptureDirectoryIsSkippedWithAReason`** — existing (`:159`), must stay
  green: no sidecar at all is still `noDurableContent`.
- **3.5 `testTrashedEntryIsHiddenByDefaultAndFoundByTheTrashScope`** — existing (`:274`),
  must stay green unchanged.
- **3.6 `testSidecarSuppliesJournalBackdateAndTrashState` / `3.7
  testUnreadableSidecarDegradesAndStaysVisible`** — existing (`:233`, `:262`), must stay
  green: the sidecar read moved, its results did not.

**Edit: `RaconteTests/EntryMetadataStoreTests.swift`**:

- **3.8 `testUpdateOnAMissingCaptureDirectoryThrowsRatherThanCreatingIt` — RED.** `update`
  against an id with no directory → throws `.captureMissing`, and `captures/<id>` still does
  not exist afterwards. Today it succeeds and creates the tree.
- **3.9 `testUpdateStillWritesWhenTheDirectoryExistsWithNoSidecar` — GUARD.** The normal
  first-write path (an absent `entry.json` is `defaults`, not an error —
  `EntryMetadataStore.swift:33-39`). **Mutation:** make the guard require `entry.json`
  rather than the directory → must fail. Every capture starts without a sidecar, so getting
  this wrong breaks journal filing on the capture path.

**Edit: `RaconteTests/LibraryTrashTests.swift`**:

- **3.10 `testRestoreOfAnEntryWhoseDirectoryVanishedReportsFailure` — RED.** Trash an entry,
  stage it away with a `StagedRemover`, then `restoreEntry` → `false` (which the Trash
  view already alerts on, `TrashView.swift:72-76`) and no directory is recreated in
  `captures/`. This is the resurrection vector in §0.3.6, pinned.

**Edit: `RaconteTests/TrashSweepTests.swift`**:

- **3.11 `testSweepDecidesOnTheTombstoneAloneWhateverElseTheDirectoryHolds` — GUARD.**
  `TrashSweep.decide` over an expired `.present` sidecar → `.delete`, and the same over a
  fresh one → `.skip(.withinRetention)`, with the test comment stating that no manifest,
  segment, `.m4a` or transcript fact is an input. **Mutation:** none available at the pure
  layer without inventing a parameter — instead assert it structurally: `decide` takes only
  `(SidecarState, Date)`, so the mutation is *adding* a `CaptureSnapshot` parameter and
  gating on `holdsIrreplaceableArtifacts`, which must break this test and the five existing
  `decide` tests (`TrashSweepTests.swift:16-45`). Run it, paste the failure, revert. If that
  reads as too artificial, drop 3.11 and say so — it documents an invariant that is already
  enforced by the function's signature.

### Red/green evidence

Focused run:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryScannerTests -only-testing:RaconteTests/EntryMetadataStoreTests -only-testing:RaconteTests/TrashSweepTests
```

plus `-only-testing:RaconteTests/LibraryTrashTests` for 3.10. 3.1, 3.8 and 3.10 must be seen
failing before any source change. Paste that output. Implement, re-run focused to green,
then run the named mutations (3.2, 3.3, 3.9, and 3.11's structural one) and paste each
failure, reverting after each.

Green gate: full `-scheme Raconte` suite. `LibraryScannerTests` carries the largest existing
surface over `build`, and **every one of its existing tests must pass unchanged** — the
sidecar read moved earlier in the function, and nothing about its results may have changed.

Commit:

```
library: a trashed capture is trash whatever the directory holds (fixes #25)
```

### Subagent prompt — step 3

```
You are implementing step 3 of docs/plans/2026-08-05-staged-removal-build-prompts.md in the
raconte repo (branch plan/structure-markers). Steps 1 and 2 must already be committed. Read
the plan's §0 (especially §0.3.11, §0.3.12, §0.3.13 and §0.4) and Step 3 in full, then
Raconte/Library/LibraryScanner.swift lines 81-142, Raconte/Library/EntryMetadataStore.swift
(all), Raconte/Library/TrashSweep.swift lines 93-141, and
docs/plans/2026-08-03-t6-revision-chain-design.md lines 540-560.

Background: staged removal (steps 1-2) made permanent deletion atomic, but a directory can
still be found in a half-destroyed state — from a pre-fix partial delete on device, or from
an edit that recreates a directory after it was staged away. The rule the owner asked for:
a capture whose sidecar reads trashedAt != nil is TRASH, regardless of what else the
directory holds. An UNREADABLE sidecar keeps today's behaviour exactly — never fabricate an
answer from a failed read.

Task:
1. LibraryScanner.build: hoist the entry.json read out of item(for:) into a
   `metadata(for:)` helper returning (EntryMetadata, EntryDegradation), call it BEFORE the
   holdsSomethingToShow gate, and change the gate to
   `guard metadata.isTrashed || holdsSomethingToShow(capture)`. item(for:) takes the
   metadata it no longer reads. Do NOT add an EntryDegradation flag (its bit-count tripwire
   in EntryDegradationTableTests would need updating and the plan explicitly rejected it).
   Do NOT change holdsSomethingToShow, EntryListFilter, or LibraryScreenModel's derived
   lists.
2. EntryMetadataStore: add `case captureMissing` to EntryMetadataError and guard it as the
   first statement of the ACTOR's update(captureID:_:) — the capture directory must exist.
   Leave the static write(_:url:)'s createDirectory alone: the capture path legitimately
   writes the sidecar right after SegmentStore.begin() creates the directory.
3. TrashSweep.decide: NO CHANGE. It already decides on trashedAt alone. Step 3 pins that
   with a test, not an edit.
4. Append ONE paragraph to §6 of docs/plans/2026-08-03-t6-revision-chain-design.md, right
   after the A2.3 discussion around line 549-558: record that the read-side half of the
   trashed-skip rule landed early with #25, that EntryMetadataStore.update now refuses to
   create a capture directory, and that T6 STILL OWES the writer-side skip for every path
   that writes into transcript/ — because the A2.3 failure leaves no entry.json to read, so
   no read-side rule can reach it. Edit no other section of that doc.

TDD, in this order:
1. Add the tests named in the plan's Step 3 across RaconteTests/LibraryScannerTests.swift,
   RaconteTests/EntryMetadataStoreTests.swift, RaconteTests/LibraryTrashTests.swift and
   RaconteTests/TrashSweepTests.swift.
2. Before changing any source, run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/LibraryScannerTests -only-testing:RaconteTests/EntryMetadataStoreTests -only-testing:RaconteTests/TrashSweepTests -only-testing:RaconteTests/LibraryTrashTests`
   and CAPTURE the failing output. testTrashedCaptureWithNothingDurableIsStillListed,
   testUpdateOnAMissingCaptureDirectoryThrowsRatherThanCreatingIt and
   testRestoreOfAnEntryWhoseDirectoryVanishedReportsFailure must all be seen failing.
3. Implement, re-run focused to green, then the FULL suite:
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
   EVERY existing LibraryScannerTests test must pass unchanged — the sidecar read moved
   earlier in the function and none of its results may have changed.
4. Mutation checks (run each, observe the failure, revert each):
   (a) emit the row unconditionally without the trash filter applying ->
       testTrashedCaptureWithNothingDurableIsNeverInTheLiveList must fail;
   (b) treat an unreadable sidecar as trashed ->
       testUnreadableSidecarWithNothingDurableIsStillSkipped must fail;
   (c) make the update guard require entry.json rather than the directory ->
       testUpdateStillWritesWhenTheDirectoryExistsWithNoSidecar must fail;
   (d) structural: add a CaptureSnapshot parameter to TrashSweep.decide and gate on
       holdsIrreplaceableArtifacts -> testSweepDecidesOnTheTombstoneAloneWhateverElseThe-
       DirectoryHolds and the five existing decide tests must fail. If this mutation reads
       as too artificial to be worth the churn, skip 3.11 entirely and say so in the report.

Swift 6 strict concurrency is on. XCTest only. Do not commit. Report: diff, red output,
green output, mutation results, and whether
testDeleteNowSurvivesAnUnwritableCaptureDirectory from step 2 survived (it may have been
dropped as FS-dependent).
```
