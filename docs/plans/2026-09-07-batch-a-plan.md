# Batch A (2026-09-07) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the four small follow-ups the owner approved on 2026-09-07 as two independent
PRs from `main`: a Verify archive… row on About (#154) with the parked-record count on the
Sync section (#156), and the capture screen's per-tick containment (#155) with a journal link
on the entry detail screen (#148).

**Architecture:** PR A extends `ExportRunner` with a verify-only run and one new state, adds a
second mode to About's single folder picker, and adds a `parked` list to `SyncStatus` that the
shared `SyncStatusSectionView` renders on both Debug and About. PR B moves the one
once-per-second read on the capture screen into a leaf view (the shape PR #153 used for the
sidebar), pinned by a comment-stripped source test, and gives `EntryDetailView` a journal
row that navigates through a closure wired in `ContentView`, matching its existing `onPage`.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency,
XcodeGen project, XCTest + XCUITest.

**Spec:** Issue bodies #154, #155, #156, #148 (read each with `gh issue view N` before
starting its task); owner rulings from the 2026-09-07 afternoon session, restated here:

1. Slate: exactly these four issues, two PRs. Nothing else rides along.
2. "Use cheaper models a lot": implementers and per-task reviewers run on Sonnet; only the
   whole-branch reviews run on Opus.
3. #148 placement, in the owner's absence: its own row at the top of the detail body,
   above the out-of-span sentence. If the owner has answered otherwise by the time Task 4
   starts, the dispatch will say so.
4. T8 is NOT in this slate. Do not touch transcription or revision code.

## Global Constraints

- **Branch per PR, from `main` at or after `2192f5db`.** Two branches:
  `feat/154-156-verify-archive-parked-count` (Tasks 1, 2) and
  `feat/155-148-capture-tick-journal-link` (Tasks 3, 4). Each PR body uses `Closes #N` for
  the two issues it fully resolves. PR bodies via `--body-file`, never a heredoc. **Merges
  are the owner's.**
- **Worktrees:** one per PR, under `.worktrees/<branch>` (gitignored), created with
  `git worktree add .worktrees/<branch> -b <branch> main`. Run `xcodegen generate` in every
  fresh worktree before the first build.
- Xcode project is GENERATED: after adding, renaming or deleting a Swift file, run
  `xcodegen generate`. **A new test file that is not regenerated runs green at the OLD
  count** — check the executed count moved, not the exit code.
- macOS unit-test command (sandbox is NOT optional — never `CODE_SIGNING_ALLOWED=NO`,
  the test host would sweep the owner's real archive):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

  To run one class: append `-only-testing:RaconteTests/<Class>`.
- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only). **The whole `RaconteUI` suite exceeds the Bash tool's
  10-minute cap**: run FOREGROUND `-only-testing:RaconteUITests/<Class>` invocations,
  one class at a time, each with the Bash tool's `timeout` set to `600000`. A run past the
  120 s default is silently backgrounded and its completion never arrives. Never
  background a test run.
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<Class> test`
- **Baseline from main's latest code-carrying CI run** (run `34086540448`, the #151
  merge, 2026-09-07): unit **2184** (1 skipped), UI **63**. Each task states its expected
  delta. Two PRs branched from the same base can both be green and still merge red; the
  owner's "Update branch" between merges is the guard.
- **Straggler grep covers all three targets**: `grep -rn <token> Raconte RaconteTests
  RaconteUITests docs CLAUDE.md` for every deleted or renamed symbol, and drive present-tense
  hits to zero. For prose, grep a single word that cannot wrap.
- Source-scanning tests strip comments before matching (`RaconteTests/SourceScanning.swift`,
  `strippingComments(_:)`).
- Every test written here must be shown RED first (run it before the production change, or
  with the production change stashed) and the failure reason must be the one the plan
  names. A test that cannot fail is a plan defect — report it, do not ship it.
- Accessibility identifiers go on the leaf control, never on a container that would
  overwrite its children's identifiers (`Raconte/Capture/UI/CaptureView.swift:213-217`).
- `.fileImporter`, `.sheet` and `.alert` attach to a screen's OUTER view (the `List` /
  `Form` / `ScrollView` itself), never to a `Section` — on a `Section` they silently
  never present on iOS 26.
- `Logger` lines the owner may read back must be `.notice`, not `.info`.
- Commit after each green step with a conventional message; the reviewer reads the diff,
  not the transcript.

---

## PR A — `feat/154-156-verify-archive-parked-count`

### Task 1: Verify archive… row on About (#154)

**Files:**
- Modify: `Raconte/Export/ExportRunner.swift` (whole file is 60 lines; `State` enum at
  lines 18-23, `run(into:)` at 34-48)
- Modify: `Raconte/Export/ArchiveVerifier.swift:22-29` (`Problem` enum)
- Modify: `Raconte/App/AboutView.swift:35` (`showingExportPicker`), `:85-104` (Archive
  section), `:118-142` (`.fileImporter`), `:150-164` (`exportResultText`)
- Modify: `RaconteTests/ArchiveExporterTests.swift` (append after
  `testExportRunnerCancelledReturnsToIdle`, line ~397; uses the file's existing
  `containerRoot`, `destinationRoot`, `buildFixture()` at line 172 and `exporter()` at 208)
- Modify: `RaconteUITests/AboutUITests.swift:52-72`
  (`testAboutScreenShowsVersionEnvironmentAndSyncRows`)
- Modify: `docs/export-format.md:117-121` ("Verifying a package by hand" intro)

**Interfaces:**
- Consumes: `ArchiveVerifier.verify(packageURL:) -> Report` (sync, non-throwing;
  `Report.checkedFiles: Int`, `Report.problems: [Problem]`, `Report.ok`);
  `ExportRunner.State` (`.idle/.running/.finished/.failed`); `ExportRunner.fail(_:)`,
  `.cancelled()`.
- Produces: `ExportRunner.State.verified(packageName: String, ArchiveVerifier.Report)`;
  `ExportRunner.verify(package: URL) async`; `ArchiveVerifier.Problem.summary: String`;
  About identifiers `about.verify` (button) — `about.export`, `about.export.progress`,
  `about.export.result` keep their names and now also carry the verify flow's progress
  and result.

- [ ] **Step 1: Write the failing unit tests**

Append to `RaconteTests/ArchiveExporterTests.swift`, inside the class, after
`testExportRunnerCancelledReturnsToIdle`:

```swift
    // MARK: (k) #154 — ExportRunner.verify(package:) runs the verifier alone on an
    // existing package and publishes `.verified`, so About's "Verify archive…" row can
    // check a years-old package without re-exporting.

    @MainActor
    func testExportRunnerVerifyPublishesVerifiedForACleanPackage() async throws {
        try buildFixture()
        let written = try await exporter().export(into: destinationRoot)
        let runner = ExportRunner(exporter: exporter())

        await runner.verify(package: written.packageURL)

        guard case let .verified(packageName, verification) = runner.state else {
            return XCTFail("expected .verified, got \(runner.state)")
        }
        XCTAssertEqual(packageName, written.packageURL.lastPathComponent)
        XCTAssertTrue(verification.ok, "clean package must verify: \(verification.problems)")
        XCTAssertGreaterThan(verification.checkedFiles, 0)
    }

    @MainActor
    func testExportRunnerVerifyOnAFolderWithoutAManifestReportsManifestUnreadable() async throws {
        let notAPackage = destinationRoot.appendingPathComponent("not-a-package", isDirectory: true)
        try FileManager.default.createDirectory(at: notAPackage, withIntermediateDirectories: true)
        let runner = ExportRunner(exporter: exporter())

        await runner.verify(package: notAPackage)

        guard case let .verified(packageName, verification) = runner.state else {
            return XCTFail("expected .verified, got \(runner.state)")
        }
        XCTAssertEqual(packageName, "not-a-package")
        XCTAssertFalse(verification.ok)
        guard case .manifestUnreadable = verification.problems.first else {
            return XCTFail("expected .manifestUnreadable first, got \(verification.problems)")
        }
    }

    func testProblemSummaryNamesTheFileOrFieldForEveryCase() {
        XCTAssertEqual(ArchiveVerifier.Problem.manifestUnreadable("no such file").summary,
                       "manifest unreadable: no such file")
        XCTAssertEqual(ArchiveVerifier.Problem.missingFile("entries/x/audio.m4a").summary,
                       "missing entries/x/audio.m4a")
        XCTAssertEqual(ArchiveVerifier.Problem.checksumMismatch("entries/x/audio.m4a").summary,
                       "checksum mismatch entries/x/audio.m4a")
        XCTAssertEqual(ArchiveVerifier.Problem.unlistedFile("stray.txt").summary,
                       "unlisted stray.txt")
        XCTAssertEqual(ArchiveVerifier.Problem.transcriptMismatch(captureID: "01X").summary,
                       "transcript mismatch for 01X")
        XCTAssertEqual(ArchiveVerifier.Problem.countMismatch(field: "entries", manifest: 3, found: 2).summary,
                       "entries: manifest says 3, found 2")
    }
```

If `buildFixture()` in this file is `@discardableResult`-less and returns a value, bind
it to `_`. Do not copy fixture helpers from `ArchiveVerifierTests` — this file has its own.

- [ ] **Step 2: Run the class to verify it fails to compile for the right reason**

Run the macOS unit command with `-only-testing:RaconteTests/ArchiveExporterTests`.
Expected: compile errors naming `verify(package:)`, `.verified`, and `.summary` — nothing
else. If a different error appears, fix the test, not the plan.

- [ ] **Step 3: Add `Problem.summary` and the runner's verify-only run**

In `Raconte/Export/ArchiveVerifier.swift`, after the `Problem` enum's cases (inside the
enum):

```swift
        /// One line the About screen can show for the FIRST problem — enough to know
        /// which file or count to go look at; the full list stays in the `Report`.
        var summary: String {
            switch self {
            case .manifestUnreadable(let why): return "manifest unreadable: \(why)"
            case .missingFile(let path): return "missing \(path)"
            case .checksumMismatch(let path): return "checksum mismatch \(path)"
            case .unlistedFile(let path): return "unlisted \(path)"
            case .transcriptMismatch(let captureID): return "transcript mismatch for \(captureID)"
            case .countMismatch(let field, let manifest, let found):
                return "\(field): manifest says \(manifest), found \(found)"
            }
        }
```

In `Raconte/Export/ExportRunner.swift`, add the state case and the method:

```swift
    enum State: Equatable {
        case idle
        case running
        case finished(ArchiveExporter.Report, ArchiveVerifier.Report)
        /// #154: a verify-only run over a package the owner picked — nothing was
        /// written. `packageName` is the picked folder's last path component.
        case verified(packageName: String, ArchiveVerifier.Report)
        case failed(String)
    }
```

```swift
    /// #154: verify an EXISTING package without exporting. Same detached utility task
    /// as `run(into:)` — a package can be gigabytes and every byte is re-hashed.
    /// `ArchiveVerifier.verify` never throws: a folder that is not a package comes back
    /// as a report whose first problem is `.manifestUnreadable`, which is the honest
    /// answer for "I picked the wrong folder".
    func verify(package: URL) async {
        state = .running
        let report = await Task.detached(priority: .utility) {
            ArchiveVerifier.verify(packageURL: package)
        }.value
        state = .verified(packageName: package.lastPathComponent, report)
    }
```

Update the type's doc comment (lines 3-5) so it reads: drives one "Export archive…" OR
"Verify archive…" run for `AboutView`.

- [ ] **Step 4: Run the class to verify it passes**

Same command as Step 2. Expected: PASS, executed count for the class up by 3.

- [ ] **Step 5: Add the About row, sharing the one folder picker**

In `Raconte/App/AboutView.swift`:

Replace the `showingExportPicker` state (line 35) with a mode plus a flag. The mode is
set by the button that opens the picker and is never cleared, so the picker's completion
closure can read it after the sheet has already dismissed (a `Binding` derived from an
optional mode would race that dismissal):

```swift
    /// #154: one `.fileImporter` serves both Archive buttons. The MODE is set by whichever
    /// button opens the picker and never cleared, so the completion closure can read it
    /// after the picker has dismissed; only the flag flips.
    private enum ArchivePickerMode { case export, verify }
    @State private var archivePickerMode: ArchivePickerMode = .export
    @State private var showingArchivePicker = false
```

Replace the Archive section (lines 85-104) with:

```swift
            Section("Archive") {
                Button("Export archive…") {
                    archivePickerMode = .export
                    showingArchivePicker = true
                }
                .accessibilityIdentifier("about.export")
                .disabled(exportRunner.state == .running)

                // #154: the same verifier the export runs, over a package picked from
                // anywhere — a years-old copy on a USB stick, or the M4 gate's fresh
                // export from a reinstalled Mac.
                Button("Verify archive…") {
                    archivePickerMode = .verify
                    showingArchivePicker = true
                }
                .accessibilityIdentifier("about.verify")
                .disabled(exportRunner.state == .running)

                if exportRunner.state == .running {
                    HStack {
                        ProgressView()
                        Text(archivePickerMode == .verify ? "Verifying…" : "Exporting…")
                            .font(.body)
                    }
                    .accessibilityIdentifier("about.export.progress")
                }
                if let resultText = exportResultText {
                    Text(resultText)
                        .font(.body)
                        .accessibilityIdentifier("about.export.result")
                }
            }
```

Change the `.fileImporter` (lines 118-142): `isPresented: $showingArchivePicker`, keep the
`.failure` branch exactly as it is, and replace the `.success` branch with:

```swift
            case .success(let urls):
                guard let url = urls.first else { return }
                let mode = archivePickerMode
                Task {
                    guard url.startAccessingSecurityScopedResource() else {
                        exportRunner.fail(mode == .verify
                                          ? "could not access the selected package"
                                          : "could not access the selected folder")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    switch mode {
                    case .export: await exportRunner.run(into: url)
                    case .verify: await exportRunner.verify(package: url)
                    }
                }
```

Add the new case to `exportResultText` (before `case let .failed(reason)`):

```swift
        case let .verified(packageName, verification):
            if verification.ok {
                return "Verified \(packageName): \(verification.checkedFiles) files, no problems"
            } else {
                let count = verification.problems.count
                let noun = count == 1 ? "problem" : "problems"
                let first = verification.problems[0].summary
                return "Verification of \(packageName) found \(count) \(noun) — first: \(first)"
            }
```

Update the `exportResultText` doc comment to say four shapes, and rename the `.failed`
text only if it still reads "Export failed" — change it to `"Failed: \(reason)"` so a
verify failure is not labelled an export failure.

- [ ] **Step 6: Extend the About UI test**

In `RaconteUITests/AboutUITests.swift`, after the `about.export` assertion (line 71):

```swift
        // #154: Verify archive… sits directly under Export in the same section. The
        // picker itself cannot be driven from XCUITest, so presence is the whole claim.
        XCTAssertTrue(revealRow(app, "about.verify").exists, "verify archive row missing")
```

Grep `about.export.result` and `about.export.progress` across `RaconteUITests` — if any
test asserts on the export copy ("Exported …"), it is unaffected; if a test asserts
"Export failed", update it to "Failed:".

- [ ] **Step 7: Build for iOS, run the About UI class, run the full unit suite**

Run the iOS compile check. Then run
`-only-testing:RaconteUITests/AboutUITests` (foreground, `timeout: 600000`). Expected:
green, 1 test executed. Then the full macOS unit suite. Expected: `Executed 2187 tests`
(2184 + 3), 1 skipped, 0 failures.

- [ ] **Step 8: Document the in-app path**

In `docs/export-format.md`, replace the first paragraph of "Verifying a package by hand"
(the one starting "No app is required…") with:

```
In the app: About → Archive → **Verify archive…** → pick the package folder. The row under
the buttons reads `Verified <package>: N files, no problems`, or names the count and the
first problem found. It runs the same `ArchiveVerifier` the export runs, so a package
copied to a USB stick years ago can be checked on any Mac or iPhone with the app.

No app is required, though — the manifest is plain JSON, and `jq`+`shasum` on any Unix
machine reproduces exactly what `ArchiveVerifier` does for the file-level checks. Run this
from inside the package directory itself:
```

- [ ] **Step 9: Commit**

```bash
git add Raconte/Export/ExportRunner.swift Raconte/Export/ArchiveVerifier.swift \
  Raconte/App/AboutView.swift RaconteTests/ArchiveExporterTests.swift \
  RaconteUITests/AboutUITests.swift docs/export-format.md
git commit -m "feat(export): Verify archive… row runs ArchiveVerifier on a picked package (#154)"
```

### Task 2: Parked-record count on the Sync section (#156)

**Files:**
- Modify: `Raconte/Sync/SyncCoordinator.swift:196-204` (`status()`), `:280-287`
  (`SyncStatus`)
- Modify: `Raconte/App/SyncStatusSectionView.swift:26-33` (the `LabeledContent` rows)
- Modify: `RaconteTests/SyncCoordinatorTests.swift` (`testStatusDefaultsBeforeAnyActivity`
  at ~line 335; append one test after it)

**Interfaces:**
- Consumes: `SyncBookkeepingStore.parkedRecords() -> [String: ParkedRecord]` (actor
  method; `ParkedRecord.reason: String`, `.attempts: Int`); `park(_:reason:)`,
  `noteRetryAttempt(_:)`; the test file's `makeCoordinator()` factory (returns
  `(SyncCoordinator, FakeCloudEngine, SyncBookkeepingStore)`).
- Produces: `ParkedSummary { name, reason, attempts }`; `SyncStatus.parked: [ParkedSummary]`
  (defaulted `[]`, sorted by name); identifiers `<prefix>.sync.parked` (count row) and
  `<prefix>.sync.parked.<name>` (one per parked record), where `<prefix>` is `about` or
  `debug`.

- [ ] **Step 1: Write the failing test**

In `RaconteTests/SyncCoordinatorTests.swift`, extend `testStatusDefaultsBeforeAnyActivity`
by adding, after its existing `XCTAssertEqual`:

```swift
        XCTAssertEqual(status.parked, [], "a fresh store parks nothing")
```

and append this test directly after it:

```swift
    /// #156: `status()` surfaces every parked name with its reason and attempt count,
    /// sorted by name so the Debug/About rows are stable across refreshes. Two names,
    /// one retried once — cardinality ≥ 2 so a sort or a dropped element is visible.
    func testStatusListsParkedRecordsSortedByNameWithReasonAndAttempts() async throws {
        let (coordinator, _, store) = try await makeCoordinator()
        await store.park("entry:01ZZZZZZZZZZZZZZZZZZZZZZZZ", reason: "asset not yet arrived")
        await store.park("entry:01AAAAAAAAAAAAAAAAAAAAAAAA", reason: "unknown item")
        await store.noteRetryAttempt("entry:01AAAAAAAAAAAAAAAAAAAAAAAA")

        let status = await coordinator.status()

        XCTAssertEqual(status.parked, [
            ParkedSummary(name: "entry:01AAAAAAAAAAAAAAAAAAAAAAAA", reason: "unknown item", attempts: 1),
            ParkedSummary(name: "entry:01ZZZZZZZZZZZZZZZZZZZZZZZZ", reason: "asset not yet arrived", attempts: 0),
        ])
    }
```

If `park`/`noteRetryAttempt` are `throws` in the store, add `try`. The names never reach
`SyncRecordName.init?(rawValue:)` in this path, so the literal ULID-shaped strings are fine.

- [ ] **Step 2: Run the class to verify it fails**

`-only-testing:RaconteTests/SyncCoordinatorTests`. Expected: compile error — `parked` is
not a member of `SyncStatus`, `ParkedSummary` undefined.

- [ ] **Step 3: Add `ParkedSummary`, the field, and the read**

In `Raconte/Sync/SyncCoordinator.swift`, above `struct SyncStatus`:

```swift
/// #156: one parked record as the Debug/About screens show it. `name` is the
/// `SyncRecordName` raw value; `reason` is the free-text diagnostic `park` recorded.
struct ParkedSummary: Equatable, Sendable {
    var name: String
    var reason: String
    var attempts: Int
}
```

Add to `SyncStatus`, after `lastError`:

```swift
    /// #156: everything in `sync/parked.json`, sorted by name. Empty on a healthy
    /// install — a non-empty list is the one diagnostic #150 asks the owner to look at.
    var parked: [ParkedSummary] = []
```

In `status()`:

```swift
    func status() async -> SyncStatus {
        let snapshot = await engine.snapshot()
        let parked = await bookkeeping.parkedRecords()
            .map { ParkedSummary(name: $0.key, reason: $0.value.reason, attempts: $0.value.attempts) }
            .sorted { $0.name < $1.name }
        return SyncStatus(accountState: snapshot.accountState,
                          lastPushAt: lastPushAt,
                          lastFetchAt: lastFetchAt,
                          pendingSaveCount: snapshot.pendingSaveCount,
                          pendingDeleteCount: snapshot.pendingDeleteCount,
                          lastError: snapshot.lastError,
                          parked: parked)
    }
```

- [ ] **Step 4: Run the class to verify it passes**

Same command. Expected: PASS, class count up by 1.

- [ ] **Step 5: Render the rows on both screens**

In `Raconte/App/SyncStatusSectionView.swift`, after the `LabeledContent("Last error", …)`
row:

```swift
                    // #156: parked.json made visible. The count row is always present so
                    // "0" is a positive statement; the per-name rows appear only when
                    // there is something to look at.
                    LabeledContent("Parked", value: "\(syncStatus.parked.count)")
                        .accessibilityIdentifier("\(idPrefix).sync.parked")
                    ForEach(syncStatus.parked, id: \.name) { record in
                        LabeledContent(record.name) {
                            Text("\(record.reason) · \(record.attempts) "
                                 + (record.attempts == 1 ? "attempt" : "attempts"))
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.caption)
                        .accessibilityIdentifier("\(idPrefix).sync.parked.\(record.name)")
                    }
```

Update the file's header doc comment (lines 4-7) to list the parked rows among what the
section renders.

No UI test: `SyncCoordinator.live()` returns nil under `RACONTE_UITEST_ID`
(`SyncCoordinator.swift:427-438`), so every UI run shows the `sync.unavailable` row and the
populated section is unreachable from XCUITest. Do NOT add a fake coordinator to the
harness for this — the existing `testAboutScreenShowsVersionEnvironmentAndSyncRows` already
pins the degraded row, and the populated rows are covered at the `SyncStatus` level above.
Say this in the PR body.

- [ ] **Step 6: Build for iOS, run the full unit suite, run the About UI class**

iOS compile check, then the full macOS unit suite. Expected: `Executed 2188 tests`
(2187 + 1), 1 skipped, 0 failures. Then `-only-testing:RaconteUITests/AboutUITests`
(foreground, `timeout: 600000`): green.

- [ ] **Step 7: Commit**

```bash
git add Raconte/Sync/SyncCoordinator.swift Raconte/App/SyncStatusSectionView.swift \
  RaconteTests/SyncCoordinatorTests.swift
git commit -m "feat(sync): show parked records with reason and attempts on Debug and About (#156)"
```

### PR A wrap-up

- [ ] Full macOS unit suite: `Executed 2188 tests`, 1 skipped, 0 failures.
- [ ] UI classes touched: `AboutUITests` green (1 test). The count stays 63 — the only
  change is an assertion added to an existing test.
- [ ] Push and open the PR with `--body-file`. Body: `Closes #154`, `Closes #156`; the
  unit/UI counts; the note that #156 has no UI test and why; one line that
  `about.export.result` now carries verify results too.

---

## PR B — `feat/155-148-capture-tick-journal-link`

### Task 3: Contain the capture screen's per-tick read (#155)

**Files:**
- Create: `Raconte/Capture/UI/CaptureStatusReadout.swift`
- Modify: `Raconte/Capture/UI/CaptureView.swift:198-240` (`statusRow`)
- Modify: `RaconteTests/SidebarRowInsetTests.swift:24-46` (the existing source pin; add a
  sibling)

**Interfaces:**
- Consumes: `RecStatusLine(phase:canResume:elapsed:)` (`Raconte/Capture/UI/RecStatusLine.swift:45-93`,
  a dumb view whose clock `Text` carries `capture.elapsed`); `CaptureCoordinator`
  (`@Observable`, `elapsed`, `phase`, `canResume`); `model.coordinator` on
  `CaptureScreenModel`; `strippingComments(_:)` from `RaconteTests/SourceScanning.swift`.
- Produces: `CaptureStatusReadout(coordinator:)`, the only view under `Raconte/Capture/UI/`
  that reads `.elapsed`. Identifier `capture.elapsed` unchanged and still on the leaf
  `Text` inside `RecStatusLine`.

- [ ] **Step 1: Write the failing source pin**

In `RaconteTests/SidebarRowInsetTests.swift`, hoist the nested `source(_:)` helper out of
`testSidebarViewNoLongerReadsElapsedAndTheBadgeDoes` into a private method of the class:

```swift
    /// Repo-relative source, comments stripped, for the containment pins below.
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent(relativePath)
        return strippingComments(try String(contentsOf: url, encoding: .utf8))
    }
```

and delete the nested copy so the existing test calls the method. Then add:

```swift
    // MARK: - Capture screen containment (#155): the same read, moved out of CaptureView

    /// `CaptureStatusReadout` is the only view on the capture screen that may read
    /// `.elapsed`; `CaptureView` must no longer re-evaluate its whole body once per
    /// second while recording. Same shape as the sidebar pin above — a source pin,
    /// because `@Observable` invalidation granularity is not assertable from XCTest.
    func testCaptureViewNoLongerReadsElapsedAndTheReadoutDoes() throws {
        let captureView = try source("Raconte/Capture/UI/CaptureView.swift")
        XCTAssertFalse(captureView.contains(".elapsed"),
                       "CaptureView must not read .elapsed itself — CaptureStatusReadout owns that read")

        let readout = try source("Raconte/Capture/UI/CaptureStatusReadout.swift")
        XCTAssertTrue(readout.contains(".elapsed"),
                      "CaptureStatusReadout must be the view that reads .elapsed")
    }
```

- [ ] **Step 2: Run the class to verify it fails for the right reason**

`-only-testing:RaconteTests/SidebarRowInsetTests`. Expected: the new test FAILS on the
first assertion (CaptureView still contains `.elapsed`) — not on the file read. The
existing sidebar test must still pass.

- [ ] **Step 3: Create the readout and use it**

Create `Raconte/Capture/UI/CaptureStatusReadout.swift`:

```swift
import SwiftUI

/// #155: the one view on the capture screen that reads `coordinator.elapsed`.
///
/// `elapsed` moves once a second while recording. Reading it from `CaptureView.body`
/// (as `statusRow` did until #155) re-evaluated the entire screen — control bar, meter,
/// record row — every tick. Reading it here confines that invalidation to this leaf,
/// exactly as `CaptureLiveBadge` does for the sidebar (#67 item 3, PR #153). The
/// coordinator is passed by reference: the parent's body reads nothing tick-rate.
///
/// `RecStatusLine` stays the dumb renderer; the clock `Text` inside it keeps the
/// `capture.elapsed` identifier the UI tests anchor on.
struct CaptureStatusReadout: View {
    let coordinator: CaptureCoordinator

    var body: some View {
        RecStatusLine(phase: coordinator.phase,
                      canResume: coordinator.canResume,
                      elapsed: coordinator.elapsed)
    }
}
```

If `model.coordinator` is not of type `CaptureCoordinator` (check
`Raconte/Capture/CaptureScreenModel.swift`), use its actual type; it must be the
`@Observable` object that owns `elapsed`.

In `Raconte/Capture/UI/CaptureView.swift`, replace lines 229-231 (the `RecStatusLine(...)`
construction inside `statusRow`) with:

```swift
            CaptureStatusReadout(coordinator: model.coordinator)
```

and add one sentence to `statusRow`'s doc comment: the tick-rate read lives in
`CaptureStatusReadout`, not here (#155).

Run `xcodegen generate` (new source file).

- [ ] **Step 4: Run the class, then the full unit suite**

`-only-testing:RaconteTests/SidebarRowInsetTests`: PASS. Then the full macOS unit suite:
`Executed 2185 tests` (2184 + 1), 1 skipped, 0 failures. Grep the three targets for
`RecStatusLine(` — the only production construction must now be in
`CaptureStatusReadout.swift` (previews in `RecStatusLine.swift` may keep their own).

- [ ] **Step 5: iOS compile check, then the two UI classes that anchor on the clock**

iOS compile check. Then, foreground, `timeout: 600000` each:
`-only-testing:RaconteUITests/CaptureControlsUITests` and
`-only-testing:RaconteUITests/NavigationUITests`. Both green — `NavigationUITests.
testARecordingSurvivesNavigatingAwayAndComingBack` reads `capture.elapsed` twice to prove
the clock still advances, which is the behavioural half of this pin.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Capture/UI/CaptureStatusReadout.swift Raconte/Capture/UI/CaptureView.swift \
  RaconteTests/SidebarRowInsetTests.swift
git commit -m "perf(capture): CaptureStatusReadout owns the per-tick elapsed read (#155)"
```

### Task 4: Entry detail names its journal, tappable (#148)

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift:17-24` (stored properties), `:123-136`
  (top of the body `VStack`)
- Modify: `Raconte/App/ContentView.swift:38-43` (the `EntryDetailView(...)` call)
- Modify: `RaconteUITests/EntryDetailSheetUITests.swift` (append one test)

**Interfaces:**
- Consumes: `item.journal: Journal?` (resolved; `Journal.id`, `.name`),
  `item.hasDanglingJournal: Bool` (`Raconte/Library/EntryListItem.swift:108,265`);
  `services.router.select(.journal(id))` (`Raconte/App/Place.swift:237-240`, clears
  `detailPath` and lands on the journal — the existing call at `ContentView.swift:196`);
  identifiers `detail.moreButton`, `detail.infoSheet`, `detail.journalPicker`,
  `journalPicker.new`, `journal.header`; the alert text field is reached as
  `app.textFields.firstMatch` (#66: alert field identifiers do not bridge).
- Produces: `EntryDetailView.onOpenJournal: (String) -> Void` (defaulted no-op, like
  `LibraryView.onEditJournal`); identifiers `detail.journalLink` (filed),
  `detail.journalUnfiled` (no journal), `detail.journalMissing` (dangling id).

- [ ] **Step 1: Write the failing UI test**

Append to `RaconteUITests/EntryDetailSheetUITests.swift`:

```swift
    /// #148: the detail screen names its journal and the name opens that journal.
    /// The seed's entry starts unfiled, so the test files it first through the existing
    /// info-sheet → Move → New Journal… flow, then reads the link that appears.
    func testJournalRowNamesTheJournalAndOpensIt() {
        let app = launchApp()
        openFirstEntry(app)

        let unfiled = app.descendants(matching: .any).matching(identifier: "detail.journalUnfiled").firstMatch
        XCTAssertTrue(unfiled.waitForExistence(timeout: 15), "an unfiled entry must say so")

        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "detail.infoSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        app.descendants(matching: .any).matching(identifier: "detail.journalPicker").firstMatch.tap()

        let newJournal = app.descendants(matching: .any).matching(identifier: "journalPicker.new").firstMatch
        XCTAssertTrue(newJournal.waitForExistence(timeout: 15), "picker has no New Journal… row")
        newJournal.tap()
        // #66: a SwiftUI identifier on an `.alert` TextField does not bridge onto the
        // UIAlertController field; it is the only text field on screen here.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Blue rabbit 2027")
        app.buttons["Create"].firstMatch.tap()

        let link = app.descendants(matching: .any).matching(identifier: "detail.journalLink").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "a filed entry shows no journal link")
        XCTAssertTrue(link.label.contains("Blue rabbit 2027"), "link label was: \(link.label)")
        link.tap()

        let header = app.descendants(matching: .any).matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the link did not open the journal")
        XCTAssertTrue(header.label.contains("Blue rabbit 2027"), "header label was: \(header.label)")
    }
```

Read the three existing tests in this file first and match how they open the sheet and
press controls (`press(_:)` if the file uses it, plain `.tap()` if it does not).

- [ ] **Step 2: Run the class to verify it fails for the right reason**

`-only-testing:RaconteUITests/EntryDetailSheetUITests` (foreground, `timeout: 600000`).
Expected: the new test FAILS at "an unfiled entry must say so" — the three existing tests
stay green. If it fails earlier (seed missing, `openFirstEntry` timing out), fix the test.

- [ ] **Step 3: Add the closure and the row**

In `Raconte/Library/UI/EntryDetailView.swift`, after `let onPage: (String) -> Void`:

```swift
    /// #148: navigate to the entry's journal. Wired by `ContentView` to
    /// `router.select(.journal(id))`, which pops this screen — the same shape as
    /// `onPage`, and the same no-op default `LibraryView.onEditJournal` uses for previews.
    var onOpenJournal: (String) -> Void = { _ in }
```

At the top of the body `VStack` (before the `if item.isDatedOutsideJournalSpan` block):

```swift
                // #148: which journal this is. Coming from All Entries, search or a
                // receipt card there was nothing on screen that said. A Button, not a
                // NavigationLink — the destination is a sidebar PLACE, and `select`
                // clears the detail path on the way there.
                if let journal = item.journal {
                    Button {
                        onOpenJournal(journal.id)
                    } label: {
                        Label(journal.name, systemImage: "book.closed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("detail.journalLink")
                    .accessibilityLabel("In \(journal.name)")
                    .accessibilityHint("Opens the journal")
                } else if item.hasDanglingJournal {
                    Text("Journal missing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.journalMissing")
                } else {
                    Text("Unfiled")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.journalUnfiled")
                }
```

In `Raconte/App/ContentView.swift`, add to the `EntryDetailView(...)` call, after
`onPage:`:

```swift
                                                onOpenJournal: { services.router.select(.journal($0)) })
```

Grep `EntryDetailView(` across `Raconte` for previews or other call sites; the defaulted
parameter means none need changing, but confirm the build.

- [ ] **Step 4: iOS compile check, run the UI class**

iOS compile check. Then `-only-testing:RaconteUITests/EntryDetailSheetUITests`
(foreground, `timeout: 600000`). Expected: 4 tests, green.

- [ ] **Step 5: Full unit suite, macOS build**

Full macOS unit suite: `Executed 2185 tests`, 1 skipped, 0 failures (this task adds no
unit test — the rule is a two-state display with no arithmetic, and the UI test is the
proof). Also confirm the macOS app builds (the unit run's test host is it).

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/UI/EntryDetailView.swift Raconte/App/ContentView.swift \
  RaconteUITests/EntryDetailSheetUITests.swift
git commit -m "feat(detail): name the entry's journal and open it on tap (#148)"
```

### PR B wrap-up

- [ ] Full macOS unit suite: `Executed 2185 tests`, 1 skipped, 0 failures.
- [ ] UI classes touched: `CaptureControlsUITests`, `NavigationUITests`,
  `EntryDetailSheetUITests` all green; UI count on CI expected **64** (63 + 1).
- [ ] Push and open the PR with `--body-file`. Body: `Closes #155`, `Closes #148`; the
  counts; a line naming the placement ruling for #148 (own row at the top of the body).

---

## After both PRs are open

- Comment on #67 that item 3's capture-screen half (the part #153 deferred to #155) is
  done in PR B; do not close #67.
- Hand the owner ONE smoke at a time, starting with C (out-of-span glyph) from the
  2026-09-07 morning handoff; the new rows here need a build 17 before they can be smoked.
