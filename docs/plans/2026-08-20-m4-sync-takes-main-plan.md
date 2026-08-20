# m4/sync Takes Main Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `main` into `m4/sync` (46 behind, 8 ahead) and wire the new `span` journal field through the sync layer, enforced by a round-trip tripwire written *before* the merge so the suite stays red until every sync site carries `span`.

**Architecture:** Three phases plus an Opus gate. Phase 1 writes a `Journal` sync round-trip tripwire on `m4/sync` (green today, designed to go red at the merge). Phase 2 performs the merge — 5 mechanical hunks in `Journal.swift`, 1 in `JournalStoreTests.swift`, 1 judgment hunk in `ContentView.swift` — ending in a *deliberately red* suite (exactly one failing test: the tripwire). Phase 3 wires `span` through the six sync sites plus the `modified["span"]` stamp, turning the suite green. The gate adversarially reviews the whole merge and re-runs both suites.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, CKSyncEngine (existing `Raconte/Sync/` layer on `m4/sync`).

**Spec:** `docs/plans/2026-08-17-m4-sync-design.md` (sync design, per-field LWW), CLAUDE.md session 2026-08-20 (merge dry-run: 3 files, 7 hunks), issue #70 (the ~9-site / ~3-compiler-enforced hazard this plan closes). All file:line cites below were re-verified against `main` @ `980a4d8e` and `m4/sync` @ `63651ac3` on 2026-08-20.

## Global Constraints

- **Workspace:** ALL work happens in the worktree `/Users/nico/src/raconte-m4`, branch `m4/sync`. Never touch the main checkout at `/Users/nico/src/raconte`.
- **Models (owner cost ruling 2026-08-17):** Sonnet implementers AND Sonnet task reviews; Opus for the gate (Task 4) only.
- **Run every test suite in the FOREGROUND.** Never background a build or test run you intend to wait on — 8 prior implementers stalled waiting for notifications subagents never receive.
- **macOS test command on this branch** needs `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements` and must NEVER gain `CODE_SIGNING_ALLOWED=NO` (unsandboxes the app-hosted runner onto the real iCloud data path). iOS-simulator runs need neither.
- **After creating any new test file:** run `xcodegen generate` or `-only-testing` reports "Executed 0 tests" and exits 0 — a silent pass.
- **UI tests:** `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test` (simulator only).
- **Unit tests:** `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=iOS Simulator,name=iPhone 17' test` (or macOS with the entitlements override above).
- **Known baseline red:** `BuildStampTests.testLoadedImageUUIDFindsARealLoadedMachOImage` fails intermittently laptop-local only. It is not caused by this work; report it, don't chase it.
- Commit messages must never contain a close-verb + issue number (`fixes #N`) unless auto-close on merge-to-main is intended. Reference as "for #70".

---

### Task 0: Preserve the uncommitted SyncCoordinator diff (parent session, no subagent)

`/Users/nico/src/raconte-m4/Raconte/Sync/SyncCoordinator.swift` carries an 18-line uncommitted hunk (verified 2026-08-20): `import os`, three unused stored members (`now`, `log`, `lastFetchAt`), an unused `foregroundFetchDebounce = 30` constant, widened `init`. Nothing consumes any of it; `launch()` is unchanged. It is inert scaffolding for a future Task-12 fetch debounce, not a working fix.

- [ ] **Step 1: Stash it with a descriptive message** (non-destructive; the merge needs a clean tree):

```bash
git -C /Users/nico/src/raconte-m4 stash push -m "inert fetch-debounce scaffolding (now/log/lastFetchAt, unused) — recover with git stash pop if Task 12 wants it" Raconte/Sync/SyncCoordinator.swift
git -C /Users/nico/src/raconte-m4 status --short   # must be clean
```

Decision deliberately deferred to the owner: drop the stash later, or pop it when Task 12 (fetch-on-launch) is actually built. Nothing in this plan depends on it.

---

### Task 1: Journal sync round-trip tripwire (Sonnet implementer, Sonnet review)

The missing adversary #70 names: today, a `Journal` field skipped by the sync builders/ingest fails nothing. This test makes that structurally loud — and it must land BEFORE the merge, so the merge itself turns it red.

**Files:**
- Create: `RaconteTests/SyncJournalRoundTripTests.swift`
- Read for fixture patterns (do not modify): `RaconteTests/SyncJournalRecordTests.swift`, `RaconteTests/SyncJournalIngestTests.swift` (both already construct `CKRecord`s and zone IDs — copy their fixture style)
- Pattern sources: `Raconte/Sync/SyncRecordBuilders.swift:62` (`journalRecord(journal:coverFileURL:deviceID:zoneID:base:)`), `Raconte/Sync/SyncIngest.swift:34` (`RemoteJournal.init?(record:)`), `Raconte/Sync/SyncIngest.swift:154` (`JournalMerge.adopted(remote:)`)

**Interfaces:**
- Consumes: the three sync functions above, `Journal`'s synthesized `Equatable` (all 5 stored fields on this branch: `id`, `name`, `createdAt`, `voiceLabels`, `modified` — `Journal.swift:12-30`).
- Produces: two tests later tasks rely on by name — `testJournalFieldCountMatchesTheSyncFixture` (Mirror pin, count 5 pre-merge) and `testEveryJournalFieldSurvivesTheSyncRoundTrip` (whole-value equality through builder → ingest → adopt).

- [ ] **Step 1: Write the two tests.** Shape (adjust fixture construction to match the existing sync tests' `CKRecordZone.ID` style — read them first; exact argument spellings for `journalRecord` are at `SyncRecordBuilders.swift:62`):

```swift
import XCTest
import CloudKit
@testable import Raconte

/// Tripwire for #70: every stored field of `Journal` must survive the full
/// sync round trip (journalRecord → RemoteJournal(record:) → adopted(remote:)).
/// When `Journal` gains a field, the Mirror pin fails FIRST — bump the count,
/// give the new field a NON-DEFAULT value in `fullyPopulatedJournal`, and the
/// equality test below stays red until SyncRecordBuilders and SyncIngest both
/// carry the field. Bumping the count alone must never be enough.
final class SyncJournalRoundTripTests: XCTestCase {

    static let fullyPopulatedJournal = Journal(
        id: "01JTESTROUNDTRIP0000000000",
        name: "Round Trip",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        voiceLabels: ["bn": "Big Nico", "ln": "Little Nico"],
        modified: ["name": Date(timeIntervalSince1970: 1_700_000_100),
                   "voiceLabels": Date(timeIntervalSince1970: 1_700_000_200)]
    )

    func testJournalFieldCountMatchesTheSyncFixture() {
        XCTAssertEqual(
            Mirror(reflecting: Self.fullyPopulatedJournal).children.count, 5,
            "Journal gained or lost a field. Bump this count, add a NON-DEFAULT value for the field to fullyPopulatedJournal, then wire the field through SyncRecordBuilders.journalRecord, RemoteJournal, JournalMerge.merge, and JournalMerge.adopted until testEveryJournalFieldSurvivesTheSyncRoundTrip passes."
        )
    }

    func testEveryJournalFieldSurvivesTheSyncRoundTrip() throws {
        let journal = Self.fullyPopulatedJournal
        let record = SyncRecordBuilders.journalRecord(
            journal: journal, coverFileURL: nil,
            deviceID: "device-a", zoneID: /* copy zone fixture from SyncJournalRecordTests */, base: nil)
        let remote = try XCTUnwrap(RemoteJournal(record: record),
            "a record this build just wrote must be ingestible by the same build")
        let adopted = JournalMerge.adopted(remote: remote)
        XCTAssertEqual(adopted, journal,
            "a field was dropped somewhere in journalRecord → RemoteJournal → adopted")
    }
}
```

If `adopted(remote:)` deliberately normalizes some field (read `SyncIngest.swift:154-158` before assuming), replace whole-value equality with per-field assertions covering ALL stored fields and document why — a reviewer must be able to see no field is silently exempted.

- [ ] **Step 2: `xcodegen generate`** (new test file), then run the new test class only and confirm it executes **2 tests, both green**:

```bash
cd /Users/nico/src/raconte-m4 && xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteTests/SyncJournalRoundTripTests test
```

"Executed 0 tests" = the xcodegen step was skipped; fix before proceeding.

- [ ] **Step 3: Mutation check (the honest red — this test is green on the current tree, so prove it can fail).** Temporarily comment out the `voiceLabels` assignment at `SyncRecordBuilders.swift:72`, re-run: `testEveryJournalFieldSurvivesTheSyncRoundTrip` must FAIL. Then temporarily revert that and comment out the `modified`-carrying line in `adopted(remote:)` (`SyncIngest.swift:154-158`): must FAIL again. Restore both, re-run: green. Paste the verbatim failure messages in the task report.

- [ ] **Step 4: Run the full unit suite in the foreground** (iOS simulator command above). Expected: green (plus the known laptop-local BuildStampTests intermittent, if on macOS).

- [ ] **Step 5: Commit:**

```bash
git add RaconteTests/SyncJournalRoundTripTests.swift project.yml
git commit -m "test: Journal sync round-trip tripwire — every field must survive builder→ingest→adopt (for #70)"
```

---

### Task 2: Merge main into m4/sync (Sonnet implementer, Sonnet review)

Mechanical for 6 of 7 hunks; one judgment hunk (`ContentView.swift`). **This task deliberately ends with the unit suite red on exactly one test** — `testEveryJournalFieldSurvivesTheSyncRoundTrip` — which is the tripwire doing its job. Anything else red is a merge mistake.

**Files:**
- Modify (conflict resolution): `Raconte/Library/Journal.swift` (5 hunks), `RaconteTests/JournalStoreTests.swift` (1 hunk), `Raconte/App/ContentView.swift` (1 hunk)
- Modify (post-merge follow-through): `Raconte/App/RaconteApp.swift` (AppServices gains sync), `RaconteTests/SyncJournalRoundTripTests.swift` (fixture + count 5→6)

**Interfaces:**
- Consumes: Task 1's two tests; main's `Journal.span: JournalSpan?` (`Journal.swift:24` on main) and `JournalStore.setSpan` (`JournalStore.swift:81-86` on main); m4's `SyncCoordinator.live(library:)` (see m4 `ContentView.swift:18-25` pre-merge for the exact construction).
- Produces: a merged tree where `Journal` has 6 stored fields (`id`, `name`, `createdAt`, `voiceLabels`, `span`, `modified`), both Mirror pins read 6, the #67 guard survives verbatim, and `AppServices` carries `sync: SyncCoordinator?`.

- [ ] **Step 1: Merge.** Confirm clean tree first (Task 0 stashed the stray diff), then:

```bash
cd /Users/nico/src/raconte-m4
git status --short          # must be empty
git fetch origin && git merge origin/main
```

Expect conflicts in exactly the 3 files above. A 4th conflicted file means the dry-run baseline moved — stop and report rather than improvising.

- [ ] **Step 2: Resolve `Raconte/Library/Journal.swift` — all 5 hunks are additive unions, keep BOTH sides:**
  1. Memberwise init signature: `init(id:name:createdAt:voiceLabels:span:modified:)` — both new params, each defaulted as its side had it.
  2. Init body: assign both `span` and `modified`.
  3. `init(from decoder:)`: both are lenient `decodeIfPresent` (main's `span` at `Journal.swift:43-60` main-side; m4's `modified` at `:49-62` m4-side). Keep both, same style.
  4. `encode(to:)`: `span` encoded only when non-nil (main `:78-80`), `modified` only when non-nil (m4 side). Keep both.
  5. `CodingKeys`: `case id, name, createdAt, voiceLabels, span, modified`.

  Property declaration order: `voiceLabels`, then `span`, then `modified` (matches each side's own comment placement; order is otherwise inert).

- [ ] **Step 3: Resolve `RaconteTests/JournalStoreTests.swift` — keep both adjacent test blocks**, and bump the Mirror pin at (main-side) `:360` from 5 to **6**, updating its message to mention both `Journal.encode(to:)` and the six sync sites.

- [ ] **Step 4: Resolve `Raconte/App/ContentView.swift` — take MAIN's file structure wholesale** (`let services: AppServices`, sidebar state, no `init()`), discarding m4's `init()` that built library/model/`SyncCoordinator` inline. Then re-home sync:
  - In `Raconte/App/RaconteApp.swift` (main-side `:8-26`), `AppServices` gains a `let sync: SyncCoordinator?` member, constructed exactly the way m4's pre-merge `ContentView.init()` did (`SyncCoordinator.live(library: library)` — read the pre-merge file at `git show 63651ac3:Raconte/App/ContentView.swift` lines 18-25 for the precise construction, including any transcription/model threading).
  - `ContentView` gains `.task { await services.sync?.launch() }` on its outer view, replacing m4's `:71` launch kick.
  - **The #67 guard at main's `ContentView.swift:108-113` (`.onChange(of: services.library.journals)` → `if resolved != router.place { router.select(resolved) }`) and its rationale comment `:93-107` must survive byte-for-byte.** Read the comment; do not re-derive the guard from any design doc.

- [ ] **Step 5: Non-conflicting files sanity check:** `CLAUDE.md` should have taken main's version cleanly (m4 never touched it — if it conflicted, stop and report). `git status` should show a normal in-progress merge with only your three resolutions.

- [ ] **Step 6: Extend the tripwire for the field `Journal` just gained:** in `RaconteTests/SyncJournalRoundTripTests.swift`, bump the Mirror count 5 → 6 and add a non-nil `span` to `fullyPopulatedJournal` (construct a `JournalSpan` the way main's `JournalStoreTests` span round-trip test does — read it in the merged tree). Do NOT touch the sync layer itself; that is Task 3.

- [ ] **Step 7: `xcodegen generate`, build both platforms, run the unit suite in the foreground.** Expected result, verbatim in your report: **exactly one failure — `SyncJournalRoundTripTests.testEveryJournalFieldSurvivesTheSyncRoundTrip`** (span not yet wired). `testJournalFieldCountMatchesTheSyncFixture` and the JournalStore pin must both be green at 6. Any other red = fix your resolution before committing.

- [ ] **Step 8: Run `RaconteUITests` in the foreground** (43 tests at last count). All green — in particular `JournalEditorUITests.testRenamingFromTheOpenEditorDoesNotPopTheEditorItself`, the #67 pin, which is the proof the hand-resolved `ContentView` kept the guard.

- [ ] **Step 9: Commit the merge** (default merge-commit message plus a body noting the deliberate red):

```bash
git add -A
git commit -m "Merge main into m4/sync: journal span + nav/editor take the sync layer

Journal now has 6 fields; the sync round-trip tripwire is deliberately RED
until span reaches SyncRecordBuilders and SyncIngest (next commit, for #70).
ContentView takes main's AppServices structure; SyncCoordinator re-homed
into AppServices; #67 guard preserved and re-pinned by the UI suite."
```

---

### Task 3: Wire span through the sync layer (Sonnet implementer, Sonnet review)

The red tripwire from Task 2 is this task's failing test — classic TDD, red already exists. Follow `voiceLabels` verbatim at every site; it has an identical shape everywhere.

**Files:**
- Modify: `Raconte/Sync/SyncRecordBuilders.swift` (constant near `:18-19`, assignment near `:72-73`)
- Modify: `Raconte/Sync/SyncIngest.swift` (`RemoteJournal` property `:10-23`, `init?(record:)` `:34-47`, memberwise init `:51-60`, `JournalMerge.merge` resolve calls `:135-141`, `adopted(remote:)` `:154-158`)
- Modify: `Raconte/Library/JournalStore.swift` (`setSpan` — post-merge it exists without a stamp; add `modified["span"]` following the branch's existing `setName`/`setVoiceLabels` stamp pattern in the merged file)
- Test: extend `RaconteTests/SyncJournalRecordTests.swift` and `RaconteTests/SyncJournalIngestTests.swift`; `RaconteTests/JournalStoreTests.swift` for the stamp

**Interfaces:**
- Consumes: the red `testEveryJournalFieldSurvivesTheSyncRoundTrip`; `encodeJSON`/`decodeJSON` helpers at `SyncRecordBuilders.swift:87`/`:100`; `LWWResolve.winner` at `SyncIngest.swift:82`.
- Produces: a fully green suite; `span` synced with per-field LWW under the `"span"` stamp key.

- [ ] **Step 1: The failing test already exists** — run it once to record the pre-change failure message:

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteTests/SyncJournalRoundTripTests test
```

- [ ] **Step 2: Write the additional failing tests first** (they pin behavior the round-trip test can't see), mirroring each file's existing `voiceLabels` tests line-for-line:
  - `SyncJournalRecordTests`: a journal with a span writes a `span` field on the record (via `encodeJSON`); a journal with nil span writes **no** `span` field; building over a `base:` record that HAD a span clears the field when the journal's span is now nil (this is what propagates span deletion — check how `voiceLabels`/cover handle field clearing on `base:` and match it).
  - `SyncJournalIngestTests`: a record WITHOUT a span field (an old build's record) still ingests — `RemoteJournal.init?(record:)` must treat span as optional, never fail the init; `JournalMerge.merge` resolves span by LWW stamp in both directions (newer remote span wins; newer local span survives an older remote); a newer-stamped nil span defeats an older non-nil one (deletion propagates).
  - `JournalStoreTests`: `setSpan` stamps `modified["span"]` (both setting and clearing — a clear must ALSO stamp, or the deletion loses every LWW race, the exact bug the cover work hit on this branch).
- [ ] **Step 3: Run them, confirm each fails for the stated reason** (missing field / missing stamp), not with a compile error.
- [ ] **Step 4: Implement, following voiceLabels at every site:**
  1. `SyncJournalField.span = "span"` constant.
  2. `journalRecord`: `record[SyncJournalField.span] = journal.span.map(encodeJSON)` (assigning nil clears the field on a `base:` record — verify against the existing cover/voiceLabels clearing behavior before assuming this spelling).
  3. `RemoteJournal`: `let span: JournalSpan?`; decode in `init?(record:)` via `decodeJSON` if the field is present, `nil` otherwise — absence must not fail the init.
  4. Memberwise init gains `span:`.
  5. `JournalMerge.merge`: `resolve("span")` assigning span exactly as `resolve("voiceLabels")` at `:136` does.
  6. `adopted(remote:)`: carry `span`.
  7. `JournalStore.setSpan`: stamp `modified["span"]` with the same clock/pattern the merged file's other setters use.
- [ ] **Step 5: Run the full unit suite in the foreground. Expected: fully green** — the tripwire included. Then run `RaconteUITests` (should be untouched by this task; confirm 43/43).
- [ ] **Step 6: Commit:**

```bash
git add -A
git commit -m "feat: span syncs — six sites + modified stamp, tripwire green (for #70)"
```

- [ ] **Step 7: Push the branch:** `git push origin m4/sync`.

---

### Task 4: Gate — adversarial whole-merge review (OPUS)

Independent reviewer; trusts no task report. Re-derives everything from the committed tree in `/Users/nico/src/raconte-m4`.

- [ ] **Re-run both suites yourself, foreground** (unit on iOS simulator; `RaconteUITests`). Verbatim executed/failed counts in the verdict.
- [ ] **Probe 1 — tripwire is not vacuous:** delete the `span` carry from `adopted(remote:)`; the suite must go red on the round-trip test. Restore. Then delete the `record[...span]` assignment in `journalRecord`; red again. Restore.
- [ ] **Probe 2 — #67 guard discriminates:** revert the guard at the merged `ContentView`'s `.onChange` to an unconditional `router.select(resolved)`; `testRenamingFromTheOpenEditorDoesNotPopTheEditorItself` must fail. Restore.
- [ ] **Probe 3 — old-build compatibility:** construct a `CKRecord` with no `span` field and a journals payload an old build would write; ingest must succeed with `span == nil` and merge must not fabricate a stamp for it.
- [ ] **Probe 4 — deletion LWW:** local non-nil span with old stamp vs remote nil span with newer stamp → nil wins; and the reverse.
- [ ] **Probe 5 — main's behavior preserved:** the registry-bytes test (span absent from `journals.json` when cleared) and the JournalStore span round-trip tests from main still pass unmodified.
- [ ] **Audit the merge resolution itself:** `git diff 8799ccf0...m4/sync -- Raconte/App/` — confirm ContentView matches main's structure + only the sync re-homing delta; confirm the guard comment block survived; confirm `AppServices.sync` construction matches what m4's pre-merge `ContentView.init()` built (`git show 63651ac3:Raconte/App/ContentView.swift`).
- [ ] Verdict: READY / BLOCKED with findings. Fix waves go back to the Task-3 implementer via resume, per the SDD loop.

---

## After the gate (owner + parent session, not subagent tasks)

1. Build a fresh signed `Raconte-m4sync.app` (real signing: `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`; iCloud entitlements CANNOT be ad-hoc signed), `ditto` to `~/Desktop`, verify the debug dylib UUID, and hand to Nico for the amended m4 Gate A smoke: cover phone→laptop, rename laptop→phone — never yet completed.
2. Owner decisions parked by this plan: drop or keep the Task-0 stash; delete merged remote branch `origin/feat/journal-editing`.

## Self-review notes

- Every CLAUDE.md claim this plan argues from was re-verified 2026-08-20 by two read-only agents (main @ `980a4d8e`, m4/sync @ `63651ac3`); the one correction: the uncommitted SyncCoordinator diff is inert scaffolding, not a fetch fix.
- The deliberate red between Tasks 2 and 3 is the design, not an oversight: writing the tripwire after the merge would mean it never demonstrably fired.
- `zoneID` fixture spelling and `adopted(remote:)` normalization are the two places implementers must read neighboring code rather than trust this plan's sketch; both are flagged inline at their steps.
