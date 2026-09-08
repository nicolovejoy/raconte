# Export scope (2026-09-08) Implementation Plan — confirmation sheet + journal-scoped export (#157)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main` that puts a confirmation sheet between the folder picker and the
first written byte, and lets the owner export a chosen set of journals (plus or minus the
unfiled entries) through the same exporter and the same verifier.

**Architecture:** A pure `ExportScope` value (`.all`, or a set of journal ids plus an
include-unfiled flag) and a pure `ExportInventory` (journal rows with names and entry counts,
an unfiled count, a total) live in a new `Raconte/Export/ExportScope.swift`.
`ArchiveExporter.export(into:scope:)` filters the walker's listing by scope BEFORE copying; the
package format does not change, so `ArchiveVerifier` is untouched and a partial package verifies
as-is. `ExportRunner` gains `inventory()` and a `scope:` parameter. `AboutView` presents one
`ExportConfirmationSheet` (attached to the `List`, never a `Section`) after the picker returns:
destination folder name, one `Toggle` per journal with its entry count, an `Unfiled entries`
toggle when there are any, a live `Export N entries` button, and Cancel. Nothing is written
until that button. A DEBUG-only launch environment variable lets the UI test reach the sheet
without the system picker.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest + XCUITest.

**Spec:** Issue #157 (`gh issue view 157`) plus the rulings in Global Constraints below.
Format reference: `docs/export-format.md`. Precedent for the picker/runner shape:
`Raconte/App/AboutView.swift` (T13, #154) and `Raconte/Export/ExportRunner.swift`.

## Global Constraints

- Branch `feat/157-export-scope` from `main` at or after `fef9a83a`. Work in a worktree; the
  main checkout stays on `main` (`git checkout` of a worktree'd branch fails silently in a
  chain).
- **Do not run `xcodebuild test` until the orchestrator has said the owner's Mac app is
  quit.** The macOS unit suite launches `Raconte.app` as its test host under the same bundle
  id, which kills a running smoke build. Compile checks (`build`) are always fine.
- **Rulings (do not re-open):**
  1. One screen: the confirmation sheet IS the scope selector. Full export stays the default
     (every toggle starts on).
  2. `journals.json` is copied WHOLE in every scoped export. It is a byte copy by format
     contract (`docs/export-format.md` "journals.json — the journals registry, byte copy") and
     the verifier never decodes it. Covers are copied only for INCLUDED journals.
  3. "Unfiled" = an entry whose sidecar (`entry.json`) is missing, unreadable, has
     `journalID == nil`, OR names a journal id that is not in `journals.json`. All four are one
     bucket; the sheet shows it as `Unfiled entries` and it is absent when its count is 0.
  4. `counts.journals` in the manifest = number of INCLUDED journals from the registry (0 for
     an unfiled-only export). `counts.entries` = included captures. Warnings for excluded
     captures (`"entries/<id>: …"`) are dropped from the manifest; every other warning stays.
  5. The exporter's container root must be the SAME root the library scans.
     `RaconteApp.swift:33` currently passes `AppContainer.root()`, which ignores the
     `RACONTE_UITEST_ID` harness redirect; Task 3 derives it from `library.capturesRoot`.
- Paper screens take a `TypeRole`, never a bare text style or size literal (CLAUDE.md; the
  scan test `TypeScaleTests.testPaperScreensCarryNoBareTextStyleOrSizeLiteral` covers a fixed
  file list — the new sheet file is NOT on that list, but follow the rule anyway and use
  `TypeRole.body.font` / `TypeRole.label.font`).
- Text colour: use `InkTone.inkSecondary.color` for secondary lines, never bare `.secondary`
  (batch 2 of the design spec will sweep any straggler; do not add one).
- Accessibility identifiers go on the control itself (`Button`, `Toggle`), never on a nested
  `Text`. A `Toggle` inside a `Form` must be tapped at `dx: 0.92` in XCUITest (see
  `RaconteUITests/JournalEditorUITests.swift:32-38`).
- New SOURCE files and new TEST files both need `xcodegen generate` before they compile; a
  suite that stays at the old count after adding a test file is the tell.
- Test-count baseline (PR #169 head run 34287217764, the last green CODE run before this
  branch): **unit 2209, 1 skipped; UI 65.** Every task reports the executed count. Bash
  `timeout: 600000` on every xcodebuild.
- macOS unit test command (sandbox kept; never `CODE_SIGNING_ALLOWED=NO`). Narrow with
  `-only-testing:RaconteTests/<Class>` for the fast loop; run the whole unit suite once in
  Task 5:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- iOS compile check (must pass on every task):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- UI tests run on the simulator only, one class per invocation (the whole suite exceeds the
  Bash 10-minute cap):

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/ExportConfirmationUITests test 2>&1 | grep -E "Executed|error:|failed|passed" | tail -8
```

- Commit after each task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BXCMRx6nRpbwBWspYouNWS
```

- Straggler greps run over all three targets (`Raconte RaconteTests RaconteUITests`), never one.

---

### Task 1: `ExportScope` and `ExportInventory`, unit-pinned

**Files:**
- Create: `Raconte/Export/ExportScope.swift`
- Create: `RaconteTests/ExportScopeTests.swift`
- Modify: none (then `xcodegen generate`)

**Interfaces:**
- Consumes: `ArchiveWalker.list(containerRoot:) -> ArchiveWalker.Listing`
  (`Raconte/Export/ArchiveWalker.swift:60`; `.captureIDs: [String]`, `.journalIDs: [String]`),
  `JournalStore.load(url:) throws -> JournalRegistry` (`Raconte/Library/JournalStore.swift:329`;
  `.journals: [Journal]`, `Journal.id`, `Journal.name`),
  `AppContainer.journalsURL(containerRoot:)`, `AppContainer.capturesRoot(containerRoot:)`
  (`Raconte/Library/AppContainer.swift:85-89`),
  `SegmentLayout.captureDirectory(capturesRoot:captureID:)`,
  `SegmentLayout.entryMetadataURL(captureDirectory:)`,
  `EntryMetadataStore.read(url:) throws -> EntryMetadata` (`.journalID: String?`).
- Produces, used by Tasks 2–4:

```swift
enum ExportScope: Equatable, Sendable {
    case all
    case selected(journalIDs: Set<String>, includeUnfiled: Bool)
    /// `journalID` is a RESOLVED bucket (see `ExportInventory.bucket`): a known journal id, or
    /// nil for the unfiled bucket.
    func includes(bucket journalID: String?) -> Bool
}

struct ExportInventory: Equatable, Sendable {
    struct JournalRow: Equatable, Sendable, Identifiable {
        var id: String      // journal id
        var name: String
        var entryCount: Int
    }
    var journals: [JournalRow]   // registry order
    var unfiledCount: Int
    var totalEntries: Int        // == journals.map(\.entryCount).sum + unfiledCount

    /// Ruling 3: a missing/unreadable sidecar, a nil journalID, and a journalID absent from
    /// `known` all resolve to nil (the unfiled bucket).
    static func bucket(journalID: String?, known: Set<String>) -> String?
    /// Reads the sidecar for one capture directory and resolves its bucket.
    static func bucket(captureDirectory: URL, known: Set<String>) -> String?
    /// Walks the container once. Throws only what `ArchiveWalker.list` throws.
    static func read(containerRoot: URL) throws -> ExportInventory
    func entryCount(for scope: ExportScope) -> Int
}
```

- [ ] **Step 1: Write the failing tests**

Create `RaconteTests/ExportScopeTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #157: the pure scope value and the inventory the confirmation sheet renders.
final class ExportScopeTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        containerRoot = base.appendingPathComponent("RaconteExportScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: Fixture helpers (shape copied from ArchiveExporterTests — do not import across files)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func writeCapture(_ id: String, journalID: String?) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try EntryMetadataStore.encode(EntryMetadata(journalID: journalID))
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeCaptureWithoutSidecar(_ id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
    }

    private func writeCaptureWithGarbageSidecar(_ id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    private func writeJournals(_ journals: [Journal]) throws {
        try JournalStore.encode(JournalRegistry(journals: journals))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    // MARK: ExportScope.includes

    func testAllIncludesEveryBucket() {
        let a = ULID.make()
        XCTAssertTrue(ExportScope.all.includes(bucket: a))
        XCTAssertTrue(ExportScope.all.includes(bucket: nil))
    }

    func testSelectedIncludesOnlyChosenJournalsAndTheUnfiledFlagDecidesNil() {
        let a = ULID.make(), b = ULID.make()
        let withoutUnfiled = ExportScope.selected(journalIDs: [a], includeUnfiled: false)
        XCTAssertTrue(withoutUnfiled.includes(bucket: a))
        XCTAssertFalse(withoutUnfiled.includes(bucket: b))
        XCTAssertFalse(withoutUnfiled.includes(bucket: nil))

        // Mutation proof: flipping ONLY the flag flips ONLY the nil bucket.
        let withUnfiled = ExportScope.selected(journalIDs: [a], includeUnfiled: true)
        XCTAssertTrue(withUnfiled.includes(bucket: a))
        XCTAssertFalse(withUnfiled.includes(bucket: b))
        XCTAssertTrue(withUnfiled.includes(bucket: nil))
    }

    // MARK: ExportInventory.bucket (ruling 3)

    func testBucketResolvesUnknownAndNilJournalsToUnfiled() {
        let a = ULID.make(), orphan = ULID.make()
        XCTAssertEqual(ExportInventory.bucket(journalID: a, known: [a]), a)
        XCTAssertNil(ExportInventory.bucket(journalID: orphan, known: [a]))
        XCTAssertNil(ExportInventory.bucket(journalID: nil, known: [a]))
    }

    // MARK: ExportInventory.read

    func testInventoryCountsPerJournalAndUnfiledInRegistryOrder() throws {
        let alpha = Journal(id: ULID.make(), name: "Alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let beta = Journal(id: ULID.make(), name: "Beta", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        try writeJournals([alpha, beta])
        try writeCapture(ULID.make(), journalID: alpha.id)
        try writeCapture(ULID.make(), journalID: alpha.id)
        try writeCapture(ULID.make(), journalID: beta.id)
        try writeCapture(ULID.make(), journalID: nil)              // unfiled: nil
        try writeCapture(ULID.make(), journalID: ULID.make())      // unfiled: orphan journal
        try writeCaptureWithoutSidecar(ULID.make())                // unfiled: no sidecar
        try writeCaptureWithGarbageSidecar(ULID.make())            // unfiled: unreadable

        let inventory = try ExportInventory.read(containerRoot: containerRoot)

        XCTAssertEqual(inventory.journals, [
            ExportInventory.JournalRow(id: alpha.id, name: "Alpha", entryCount: 2),
            ExportInventory.JournalRow(id: beta.id, name: "Beta", entryCount: 1),
        ])
        XCTAssertEqual(inventory.unfiledCount, 4)
        XCTAssertEqual(inventory.totalEntries, 7)

        XCTAssertEqual(inventory.entryCount(for: .all), 7)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [alpha.id], includeUnfiled: false)), 2)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [beta.id], includeUnfiled: true)), 5)
        XCTAssertEqual(inventory.entryCount(for: .selected(journalIDs: [], includeUnfiled: false)), 0)
    }

    func testInventoryWithNoJournalsFileHasNoRowsAndEverythingUnfiled() throws {
        try writeCapture(ULID.make(), journalID: ULID.make())
        try writeCaptureWithoutSidecar(ULID.make())

        let inventory = try ExportInventory.read(containerRoot: containerRoot)

        XCTAssertEqual(inventory.journals, [])
        XCTAssertEqual(inventory.unfiledCount, 2)
        XCTAssertEqual(inventory.totalEntries, 2)
    }

    func testInventoryOnAMissingContainerRootThrows() {
        let missing = containerRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try ExportInventory.read(containerRoot: missing))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run: `xcodegen generate`

Then the unit command from Global Constraints with `-only-testing:RaconteTests/ExportScopeTests`.

Expected: compile FAILURE — `cannot find 'ExportScope' in scope`, `cannot find 'ExportInventory' in scope`. (A compile failure IS the red step for a type that does not exist yet.)

- [ ] **Step 3: Write the implementation**

Create `Raconte/Export/ExportScope.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the unit command with `-only-testing:RaconteTests/ExportScopeTests`.
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: iOS compile check** (Global Constraints command). Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Export/ExportScope.swift RaconteTests/ExportScopeTests.swift
git commit -m "feat(#157): ExportScope and ExportInventory — pure scope value and per-journal counts"
```

---

### Task 2: `ArchiveExporter` takes a scope; a partial package verifies unchanged

**Files:**
- Modify: `Raconte/Export/ArchiveExporter.swift:37-114` (`export(into:)`)
- Modify: `RaconteTests/ArchiveExporterTests.swift` (append tests after line 395, before the `ExportRunner` tests)
- Modify: `docs/export-format.md` (add a "Scoped exports" section after "Fields")

**Interfaces:**
- Consumes: `ExportScope`, `ExportInventory.bucket(captureDirectory:known:)` from Task 1.
- Produces, used by Task 3: `func export(into destination: URL, scope: ExportScope = .all) async throws -> Report`.
  The default keeps every existing call site and test compiling unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/ArchiveExporterTests.swift` directly after
`testStalePartDirectoryIsClearedBeforeExport` (line ~395), inside the class:

```swift
    // MARK: #157 — scoped exports

    /// A second journal WITH a cover and a third capture filed into it, on top of
    /// `buildFixture()`'s one journal + two captures. Returns the new journal and capture id.
    private func addSecondJournalAndCapture() throws -> (journal: Journal, captureID: String) {
        let second = Journal(id: ULID.make(), name: "Second", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        let id = ULID.make()
        try writeManifest(id, verifiedAt: Date(timeIntervalSince1970: 1_700_000_004))
        try writeFinalM4A(id, bytes: Data(repeating: 0xCD, count: 512))
        try writeEntryMetadata(EntryMetadata(journalID: second.id), id: id)
        let registry = try JournalStore.load(url: AppContainer.journalsURL(containerRoot: containerRoot))
        try writeJournals(registry.journals + [second])
        try writeCover(journalID: second.id, bytes: Data(repeating: 0x43, count: 8))
        return (second, id)
    }

    private func readManifest(at packageURL: URL) throws -> ExportManifest {
        try CaptureCoding.decoder().decode(
            ExportManifest.self,
            from: try Data(contentsOf: packageURL.appendingPathComponent("raconte-export.json")))
    }

    func testSelectedJournalExportCopiesOnlyItsEntriesAndCoverAndVerifiesClean() async throws {
        let fixture = try buildFixture()
        let (second, secondCaptureID) = try addSecondJournalAndCapture()

        let report = try await exporter().export(
            into: destinationRoot,
            scope: .selected(journalIDs: [fixture.journal.id], includeUnfiled: false))

        let paths = try packageFileRelativePaths(under: report.packageURL)
        XCTAssertTrue(paths.contains("entries/\(fixture.idAudio)/audio.m4a"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("entries/\(fixture.idNoAudio)/") },
                       "the garbage-sidecar capture is unfiled and was not asked for")
        XCTAssertFalse(paths.contains { $0.hasPrefix("entries/\(secondCaptureID)/") })
        XCTAssertTrue(paths.contains("journals.json"), "ruling 2: registry is copied whole")
        XCTAssertTrue(paths.contains("journals/\(fixture.journal.id)/cover.jpg"))
        XCTAssertFalse(paths.contains("journals/\(second.id)/cover.jpg"),
                       "covers travel only for included journals")

        let manifest = try readManifest(at: report.packageURL)
        XCTAssertEqual(manifest.counts.entries, 1)
        XCTAssertEqual(manifest.counts.journals, 1)
        XCTAssertEqual(Set(manifest.entries.keys), [fixture.idAudio])
        XCTAssertEqual(manifest.counts.files, manifest.files.count)
        XCTAssertFalse(manifest.warnings.contains { $0.hasPrefix("entries/\(fixture.idNoAudio)") },
                       "ruling 4: warnings for excluded captures are dropped")

        // The whole point of #157's "same verifier": a partial package is a valid package.
        let verification = ArchiveVerifier.verify(packageURL: report.packageURL)
        XCTAssertTrue(verification.ok, "\(verification.problems)")
        XCTAssertEqual(verification.checkedFiles, manifest.files.count)
    }

    func testUnfiledOnlyExportCarriesTheGarbageSidecarCaptureAndNoCovers() async throws {
        let fixture = try buildFixture()
        _ = try addSecondJournalAndCapture()

        let report = try await exporter().export(
            into: destinationRoot,
            scope: .selected(journalIDs: [], includeUnfiled: true))

        let manifest = try readManifest(at: report.packageURL)
        XCTAssertEqual(Set(manifest.entries.keys), [fixture.idNoAudio])
        XCTAssertEqual(manifest.counts.entries, 1)
        XCTAssertEqual(manifest.counts.journals, 0)
        let paths = try packageFileRelativePaths(under: report.packageURL)
        XCTAssertFalse(paths.contains { $0.hasPrefix("journals/") }, "no journal included, no covers")
        XCTAssertTrue(paths.contains("journals.json"))
        XCTAssertTrue(manifest.warnings.contains("entries/\(fixture.idNoAudio): sidecar unreadable"))
        XCTAssertTrue(ArchiveVerifier.verify(packageURL: report.packageURL).ok)
    }

    func testAllScopeWritesTheSamePackageAsTheUnscopedCall() async throws {
        try buildFixture()
        let otherDestination = destinationRoot.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDestination, withIntermediateDirectories: true)

        let unscoped = try await exporter().export(into: destinationRoot)
        let scoped = try await exporter().export(into: otherDestination, scope: .all)

        let a = try readManifest(at: unscoped.packageURL)
        let b = try readManifest(at: scoped.packageURL)
        XCTAssertEqual(a.files, b.files)
        XCTAssertEqual(a.counts, b.counts)
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertEqual(a.warnings, b.warnings)
    }

    func testSelectedScopeExcludingEveryJournalStillExportsWhenNothingMatches() async throws {
        try buildFixture()
        let report = try await exporter().export(
            into: destinationRoot,
            scope: .selected(journalIDs: [], includeUnfiled: false))
        let manifest = try readManifest(at: report.packageURL)
        XCTAssertEqual(manifest.counts.entries, 0)
        XCTAssertEqual(manifest.counts.journals, 0)
        XCTAssertTrue(ArchiveVerifier.verify(packageURL: report.packageURL).ok,
                      "an empty-but-well-formed package verifies; the SHEET disables the button at 0, the exporter stays honest")
    }
```

Note `readManifest(at:)` is new to this file (the verifier tests have their own private copy —
that is the convention, do not import across test files).

- [ ] **Step 2: Run the tests to verify they fail**

Run the unit command with `-only-testing:RaconteTests/ArchiveExporterTests`.
Expected: compile FAILURE — `extra argument 'scope' in call`.

- [ ] **Step 3: Implement the scope filter in `ArchiveExporter.export`**

Change the signature at `Raconte/Export/ArchiveExporter.swift:37`:

```swift
    /// `scope` (#157) decides which captures and covers land; `.all` is the T13 behaviour.
    /// `journals.json` is copied whole in every scope (ruling 2 — byte-copy contract, and the
    /// verifier never decodes it).
    func export(into destination: URL, scope: ExportScope = .all) async throws -> Report {
        let fullListing = try ArchiveWalker.list(containerRoot: containerRoot)
        let listing = Self.apply(scope, to: fullListing, containerRoot: containerRoot)
```

Everything below that line keeps using `listing` unchanged (`listing.files`,
`listing.captureIDs`, `listing.journalIDs.count`, `listing.warnings`). Add the pure filter as a
static method in the same struct, after `stampFormatter()`:

```swift
    // MARK: #157 scope filter — pure over the listing plus one sidecar read per capture

    /// Narrows the walker's listing to `scope`. Resolution of each capture's bucket goes
    /// through `ExportInventory.bucket(captureDirectory:known:)` — the SAME rule the
    /// confirmation sheet counted with, so "Export 3 entries" writes exactly 3.
    static func apply(_ scope: ExportScope, to listing: ArchiveWalker.Listing,
                      containerRoot: URL) -> ArchiveWalker.Listing {
        if case .all = scope { return listing }

        let known = Set(listing.journalIDs)
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let includedCaptures = Set(listing.captureIDs.filter { captureID in
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            return scope.includes(bucket: ExportInventory.bucket(captureDirectory: directory, known: known))
        })
        let includedJournals = listing.journalIDs.filter { scope.includes(bucket: $0) }
        let includedJournalSet = Set(includedJournals)

        let files = listing.files.filter { file in
            if let captureID = Self.captureID(ofEntryPath: file.relativePath) {
                return includedCaptures.contains(captureID)
            }
            if let journalID = Self.journalID(ofCoverPath: file.relativePath) {
                return includedJournalSet.contains(journalID)
            }
            return true // journals.json (ruling 2)
        }
        let warnings = listing.warnings.filter { warning in
            guard let captureID = Self.captureID(ofEntryPath: warning) else { return true }
            return includedCaptures.contains(captureID)
        }
        return ArchiveWalker.Listing(
            files: files,
            captureIDs: listing.captureIDs.filter { includedCaptures.contains($0) },
            journalIDs: includedJournals,
            warnings: warnings)
    }

    /// `entries/<id>/…` or `entries/<id>: …` → `<id>`; nil for anything else.
    private static func captureID(ofEntryPath path: String) -> String? {
        let prefix = "entries/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        let end = rest.firstIndex { $0 == "/" || $0 == ":" } ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    /// `journals/<id>/cover.jpg` → `<id>`; nil for anything else (including `journals.json`,
    /// which has no slash after the directory name).
    private static func journalID(ofCoverPath path: String) -> String? {
        let prefix = AppContainer.journalCoversDirectoryName + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[rest.startIndex..<slash])
    }
```

Ruling 4's warning filter relies on the walker's warning format `"entries/<id>: …"`
(`ArchiveWalker.swift:105,138,146,192,225,251`) — `captureID(ofEntryPath:)` stops at `:` for
exactly that reason. A warning that names no capture (`journals.json: unreadable`) is kept.

- [ ] **Step 4: Run the tests to verify they pass**

Run the unit command with `-only-testing:RaconteTests/ArchiveExporterTests`.
Expected: `Executed 18 tests, with 0 failures` (14 existing + 4 new).

- [ ] **Step 5: Document the format consequence**

In `docs/export-format.md`, after the "Fields (`ExportManifest`)" list and before
"## Skipped on purpose", add:

```markdown
## Scoped exports (#157)

About → Archive → **Export archive…** confirms before writing and lets you leave journals out.
A scoped package has the same layout and manifest; only its contents differ:

- `journals.json` is always copied whole (it is a byte copy; the verifier never decodes it),
  so the names of journals you left out still travel. Covers (`journals/<id>/cover.jpg`) are
  copied only for the journals you included.
- `counts.journals` is the number of INCLUDED journals; `counts.entries` the included
  captures. Warnings about excluded captures are dropped.
- "Unfiled entries" means a capture whose `entry.json` is missing, unreadable, has no
  `journalID`, or names a journal not in `journals.json`.
- The verifier does not know or care about scope: a partial package verifies exactly like a
  full one, because every check is against the package's own manifest and files.
```

- [ ] **Step 6: iOS compile check.** Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Raconte/Export/ArchiveExporter.swift RaconteTests/ArchiveExporterTests.swift docs/export-format.md
git commit -m "feat(#157): ArchiveExporter.export(into:scope:) — journal-scoped packages verify unchanged"
```

---

### Task 3: `ExportRunner.inventory()` + `run(into:scope:)`; exporter root follows the library

**Files:**
- Modify: `Raconte/Export/ExportRunner.swift:48-64`
- Modify: `Raconte/App/RaconteApp.swift:33-36`
- Modify: `RaconteTests/ArchiveExporterTests.swift` (append one test to the `ExportRunner` group, after `testExportRunnerVerifyOnAFolderWithoutAManifestReportsManifestUnreadable`, line ~443)

**Interfaces:**
- Consumes: `ExportScope`, `ExportInventory.read(containerRoot:)` (Task 1);
  `ArchiveExporter.export(into:scope:)` (Task 2); `ArchiveExporter.containerRoot` (already `let`);
  `LibraryScreenModel.capturesRoot` (`Raconte/Library/LibraryScreenModel.swift:45`, `nonisolated let`);
  `AppContainer.containerRoot(capturesRoot:)` (`Raconte/Library/AppContainer.swift:209`).
- Produces, used by Task 4:
  - `func run(into destination: URL, scope: ExportScope = .all) async`
  - `func inventory() async -> ExportInventory?` — nil after publishing `.failed(reason)`.

- [ ] **Step 1: Write the failing test**

Append inside `ArchiveExporterTests`, after `testExportRunnerVerifyOnAFolderWithoutAManifestReportsManifestUnreadable`:

```swift
    // MARK: #157 — the runner reads the inventory the sheet renders, off-main, from the
    // exporter's own container root.

    @MainActor
    func testExportRunnerInventoryReflectsTheFixture() async throws {
        let fixture = try buildFixture()
        let runner = ExportRunner(exporter: exporter())

        let inventory = try XCTUnwrap(await runner.inventory())

        XCTAssertEqual(inventory.journals,
                       [ExportInventory.JournalRow(id: fixture.journal.id, name: "1987 Journal", entryCount: 1)])
        XCTAssertEqual(inventory.unfiledCount, 1, "the garbage-sidecar capture is unfiled")
        XCTAssertEqual(inventory.totalEntries, 2)
        XCTAssertEqual(runner.state, .idle, "reading the inventory is not a run")
    }

    @MainActor
    func testExportRunnerInventoryOnAMissingContainerPublishesFailedAndReturnsNil() async {
        let missing = containerRoot.appendingPathComponent("gone", isDirectory: true)
        let runner = ExportRunner(exporter: ArchiveExporter(containerRoot: missing, appVersion: "9.9", build: "t"))

        let inventory = await runner.inventory()

        XCTAssertNil(inventory)
        guard case .failed = runner.state else { return XCTFail("expected .failed, got \(runner.state)") }
    }

    @MainActor
    func testExportRunnerRunWithScopeWritesOnlyThatScope() async throws {
        let fixture = try buildFixture()
        let runner = ExportRunner(exporter: exporter())

        await runner.run(into: destinationRoot, scope: .selected(journalIDs: [fixture.journal.id], includeUnfiled: false))

        guard case let .finished(report, verification) = runner.state else {
            return XCTFail("expected .finished, got \(runner.state)")
        }
        XCTAssertEqual(report.counts.entries, 1)
        XCTAssertTrue(verification.ok)
    }
```

(Check how the existing runner tests in this file are isolated — `testExportRunnerCancelledReturnsToIdle`
at line ~397 — and match their `@MainActor` placement exactly.)

- [ ] **Step 2: Run the tests to verify they fail**

Run the unit command with `-only-testing:RaconteTests/ArchiveExporterTests`.
Expected: compile FAILURE — `value of type 'ExportRunner' has no member 'inventory'`,
`extra argument 'scope' in call`.

- [ ] **Step 3: Implement**

In `Raconte/Export/ExportRunner.swift`, replace `run(into:)` (lines 48-64) with:

```swift
    /// `destination` is the folder the owner picked via `.fileImporter` — the exporter
    /// creates its own timestamped package directory inside it, so this never writes
    /// directly into a folder the owner did not choose. `scope` (#157) is what the
    /// confirmation sheet resolved; `.all` is the pre-#157 behaviour.
    func run(into destination: URL, scope: ExportScope = .all) async {
        state = .running(verifying: false)
        let exporter = self.exporter
        do {
            let (report, verification) = try await Task.detached(priority: .utility) {
                let report = try await exporter.export(into: destination, scope: scope)
                let verification = ArchiveVerifier.verify(packageURL: report.packageURL)
                return (report, verification)
            }.value
            state = .finished(report, verification)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// #157: what the confirmation sheet renders. One walk of the container, off the main
    /// actor (a large archive is thousands of directory reads). Not a "run": `state` is left
    /// alone on success so a stale result row from a previous export stays visible behind
    /// the sheet. On failure — realistically only a missing container root — publishes
    /// `.failed` and returns nil so the caller shows nothing.
    func inventory() async -> ExportInventory? {
        let containerRoot = exporter.containerRoot
        do {
            return try await Task.detached(priority: .utility) {
                try ExportInventory.read(containerRoot: containerRoot)
            }.value
        } catch {
            state = .failed(String(describing: error))
            return nil
        }
    }
```

In `Raconte/App/RaconteApp.swift:33-36`, change the exporter's root (ruling 5):

```swift
        // #157: the exporter reads the SAME container the library scans — derived from the
        // library's captures root, never `AppContainer.root()` on its own, which ignores the
        // `RACONTE_UITEST_ID` harness redirect and would export an empty sandbox under UI
        // test while the sheet counted the seeded entries. In production the two are the
        // same directory.
        self.exportRunner = ExportRunner(exporter: ArchiveExporter(
            containerRoot: AppContainer.containerRoot(capturesRoot: library.capturesRoot),
            appVersion: AppVersion.shortVersion(),
            build: AppVersion.displayString(short: nil, build: BuildInfo.buildNumber)))
```

Read `AppContainer.containerRoot(capturesRoot:)` at `AppContainer.swift:209` first and confirm it
is the inverse of `capturesRoot(containerRoot:)` (one `deletingLastPathComponent()`); if its
doc comment says anything else, stop and report.

- [ ] **Step 4: Run the tests to verify they pass**

Run the unit command with `-only-testing:RaconteTests/ArchiveExporterTests`.
Expected: `Executed 21 tests, with 0 failures`.

- [ ] **Step 5: iOS compile check.** Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Export/ExportRunner.swift Raconte/App/RaconteApp.swift RaconteTests/ArchiveExporterTests.swift
git commit -m "feat(#157): ExportRunner.inventory() and run(into:scope:); exporter root follows the library's"
```

---

### Task 4: `ExportConfirmationSheet`, About wiring, harness destination, UI tests

**Files:**
- Create: `Raconte/App/ExportConfirmationSheet.swift`
- Modify: `Raconte/App/AboutView.swift:38-40` (state), `:90-96` (export button), `:137-170` (picker callback), add `.sheet(item:)` after `.fileImporter`
- Create: `RaconteUITests/ExportConfirmationUITests.swift`
- Then `xcodegen generate` (two new files)

**Interfaces:**
- Consumes: `ExportInventory`, `ExportScope` (Task 1); `ExportRunner.inventory()`,
  `ExportRunner.run(into:scope:)` (Task 3); `TypeRole.body.font`, `TypeRole.label.font`
  (`Raconte/App/TypeScale.swift`); `InkTone.inkSecondary.color`; `openPlace(app, "sidebar.about")`
  and the `RACONTE_UITEST_ID` / `RACONTE_UITEST_SEED_ENTRY` environment (`RaconteUITests/UITestNavigation.swift`,
  `Raconte/Capture/Debug/UITestSupport.swift:46-70`).
- Produces (accessibility identifiers, all on the control itself):
  - `about.export.sheet` — the sheet's `Form`
  - `about.export.destination` — `LabeledContent("To", value: folderName)`
  - `about.export.journal.<journalID>` — one `Toggle` per journal row, label `"<name> · <n>"`
  - `about.export.unfiled` — `Toggle`, label `"Unfiled entries · <n>"`, present only when `unfiledCount > 0`
  - `about.export.confirm` — `Button`, label `"Export N entries"` / `"Export 1 entry"`, disabled at 0
  - `about.export.cancel` — `Button("Cancel")`
  - Launch environment `RACONTE_UITEST_EXPORT_DESTINATION=tmp` (DEBUG only): the Export
    button skips the system picker and opens the sheet for `FileManager.default.temporaryDirectory`
    without security scoping.

- [ ] **Step 1: Write the failing UI tests**

Create `RaconteUITests/ExportConfirmationUITests.swift`:

```swift
import XCTest

/// #157: the confirmation sheet between the folder picker and the first written byte.
///
/// The system folder picker cannot be driven from XCUITest, so the harness build accepts
/// `RACONTE_UITEST_EXPORT_DESTINATION=tmp` and opens the sheet for the app's own temporary
/// directory instead — same DEBUG-gated env-var pattern as the seeds in `UITestSupport`.
/// `RACONTE_UITEST_SEED_ENTRY` seeds exactly one capture (a revision chain, no `entry.json`),
/// which the sheet must count under `Unfiled entries · 1`.
final class ExportConfirmationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_ENTRY"] = "1"
        app.launchEnvironment["RACONTE_UITEST_EXPORT_DESTINATION"] = "tmp"
        app.launch()
        return app
    }

    /// Same reason and shape as `AboutUITests.revealRow`: About's Archive section is below
    /// the fold and an offscreen List row is absent from the accessibility tree.
    private func revealRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<8 where !element.exists {
            app.swipeUp()
        }
        return element
    }

    /// `.tap()` on a Form Toggle lands on the label, not the switch (standing lesson);
    /// tap at the trailing edge where the switch renders.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func openSheet(_ app: XCUIApplication) -> XCUIElement {
        openPlace(app, "sidebar.about")
        revealRow(app, "about.export").tap()
        let sheet = app.descendants(matching: .any)["about.export.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "confirmation sheet did not present")
        return sheet
    }

    func testSheetShowsDestinationCountsAndCancelWritesNothing() {
        let app = launchApp()
        _ = openSheet(app)

        XCTAssertTrue(app.descendants(matching: .any)["about.export.destination"].exists)
        let unfiled = app.descendants(matching: .any)["about.export.unfiled"]
        XCTAssertTrue(unfiled.exists, "the seeded entry has no entry.json, so it is unfiled")
        XCTAssertEqual(unfiled.label, "Unfiled entries · 1")

        let confirm = app.buttons["about.export.confirm"]
        XCTAssertTrue(confirm.exists)
        XCTAssertEqual(confirm.label, "Export 1 entry")
        XCTAssertTrue(confirm.isEnabled)

        app.buttons["about.export.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["about.export.sheet"]
            .waitForNonExistence(withTimeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["about.export.progress"].exists,
                       "Cancel must not start an export")
        XCTAssertFalse(app.descendants(matching: .any)["about.export.result"].exists,
                       "Cancel must not produce a result row")
    }

    func testDeselectingUnfiledDropsTheCountToZeroAndDisablesExport() {
        let app = launchApp()
        _ = openSheet(app)
        let confirm = app.buttons["about.export.confirm"]
        let unfiled = app.descendants(matching: .any)["about.export.unfiled"]

        flip(unfiled)
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertEqual(confirm.label, "Export 0 entries")
        XCTAssertFalse(confirm.isEnabled)

        flip(unfiled)
        XCTAssertEqual(confirm.label, "Export 1 entry")
        XCTAssertTrue(confirm.isEnabled)
    }

    func testConfirmExportsToTheHarnessDestinationAndReportsVerified() {
        let app = launchApp()
        _ = openSheet(app)

        app.buttons["about.export.confirm"].tap()

        let result = app.descendants(matching: .any)["about.export.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("Exported 1 "), result.label)
        XCTAssertTrue(result.label.hasSuffix("— verified"), result.label)
    }
}
```

The label in the third test keeps the EXISTING result wording (`"Exported \(n) entries to
\(folder) — verified"`, `AboutView.swift:186`) — the singular/plural of that row is not this
issue's scope; `hasPrefix("Exported 1 ")` is deliberately agnostic.

- [ ] **Step 2: Regenerate and run the new class to verify it fails for the right reason**

Run: `xcodegen generate`, then the UI command from Global Constraints
(`-only-testing:RaconteUITests/ExportConfirmationUITests`).

Expected: 3 failures, each at `confirmation sheet did not present` — the harness env var is not
honoured yet, so the tap opens the real system picker and no `about.export.sheet` ever exists.
Any OTHER failure message (e.g. `sidebar.about` not found) means the test is broken, not red.

- [ ] **Step 3: Create the sheet**

Create `Raconte/App/ExportConfirmationSheet.swift`:

```swift
import SwiftUI

/// #157: the moment between "pick a folder" and "write my whole private journal into it".
/// Names the destination, lists every journal with its entry count, offers the unfiled bucket
/// when there is one, and commits with a button that says exactly how many entries will land.
/// Every toggle starts ON — a full export is still the default path, this is a scope
/// selector in front of it. Nothing is written until `onExport` fires.
struct ExportConfirmationSheet: View {
    let destinationName: String
    let inventory: ExportInventory
    let onCancel: () -> Void
    let onExport: (ExportScope) -> Void

    @State private var selectedJournalIDs: Set<String>
    @State private var includeUnfiled: Bool

    init(destinationName: String, inventory: ExportInventory,
         onCancel: @escaping () -> Void, onExport: @escaping (ExportScope) -> Void) {
        self.destinationName = destinationName
        self.inventory = inventory
        self.onCancel = onCancel
        self.onExport = onExport
        _selectedJournalIDs = State(initialValue: Set(inventory.journals.map(\.id)))
        _includeUnfiled = State(initialValue: inventory.unfiledCount > 0)
    }

    /// `.all` when nothing was deselected, so a default confirm is byte-identical to the
    /// pre-#157 export (`testAllScopeWritesTheSamePackageAsTheUnscopedCall`).
    private var scope: ExportScope {
        let everyJournal = selectedJournalIDs.count == inventory.journals.count
        let everyUnfiled = includeUnfiled || inventory.unfiledCount == 0
        if everyJournal && everyUnfiled { return .all }
        return .selected(journalIDs: selectedJournalIDs, includeUnfiled: includeUnfiled)
    }

    private var entryCount: Int { inventory.entryCount(for: scope) }

    private var confirmTitle: String {
        entryCount == 1 ? "Export 1 entry" : "Export \(entryCount) entries"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: destinationName)
                        .accessibilityIdentifier("about.export.destination")
                } footer: {
                    Text("The package is plain files: transcripts are readable text and audio plays anywhere. Choose the destination with that in mind.")
                        .font(TypeRole.footnote.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                }

                Section("Journals") {
                    ForEach(inventory.journals) { row in
                        Toggle("\(row.name) · \(row.entryCount)", isOn: Binding(
                            get: { selectedJournalIDs.contains(row.id) },
                            set: { on in
                                if on { selectedJournalIDs.insert(row.id) } else { selectedJournalIDs.remove(row.id) }
                            }))
                        .accessibilityIdentifier("about.export.journal.\(row.id)")
                    }
                    if inventory.unfiledCount > 0 {
                        Toggle("Unfiled entries · \(inventory.unfiledCount)", isOn: $includeUnfiled)
                            .accessibilityIdentifier("about.export.unfiled")
                    }
                }
            }
            .font(TypeRole.body.font)
            .navigationTitle("Export archive")
            .accessibilityIdentifier("about.export.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("about.export.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onExport(scope) }
                        .disabled(entryCount == 0)
                        .accessibilityIdentifier("about.export.confirm")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

#Preview {
    ExportConfirmationSheet(
        destinationName: "Archive 2026",
        inventory: ExportInventory(
            journals: [.init(id: "a", name: "1987 Journal", entryCount: 12),
                       .init(id: "b", name: "Trip to France", entryCount: 3)],
            unfiledCount: 2, totalEntries: 17),
        onCancel: {}, onExport: { _ in })
}
```

- [ ] **Step 4: Wire About**

In `Raconte/App/AboutView.swift`:

(a) After the `showingArchivePicker` state (line 40), add:

```swift
    /// #157: the export the owner has picked a folder for but not yet confirmed. Set only
    /// after the inventory has been read; the `.sheet(item:)` below presents while non-nil.
    /// `requiresSecurityScope` is false only for the UI-test harness destination (the app's
    /// own temp dir), which `startAccessingSecurityScopedResource()` would refuse.
    private struct PendingExport: Identifiable {
        let id = UUID()
        var destination: URL
        var inventory: ExportInventory
        var requiresSecurityScope: Bool
    }
    @State private var pendingExport: PendingExport?
```

(b) Replace the Export button action (lines 91-94):

```swift
                Button("Export archive…") {
                    #if DEBUG
                    // #157 UI test path: the system picker cannot be driven from XCUITest.
                    if ProcessInfo.processInfo.environment["RACONTE_UITEST_EXPORT_DESTINATION"] == "tmp" {
                        Task { await stageExport(to: FileManager.default.temporaryDirectory, requiresSecurityScope: false) }
                        return
                    }
                    #endif
                    archivePickerMode = .export
                    showingArchivePicker = true
                }
```

(c) In the picker callback's `.success` branch (lines 153-168), route `.export` to staging instead
of running:

```swift
            case .success(let urls):
                guard let url = urls.first else { return }
                let mode = archivePickerMode
                Task {
                    switch mode {
                    case .export:
                        // #157: nothing is written yet — read the inventory and confirm.
                        await stageExport(to: url, requiresSecurityScope: true)
                    case .verify:
                        guard url.startAccessingSecurityScopedResource() else {
                            exportRunner.fail("could not access the selected package")
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        await exportRunner.verify(package: url)
                    }
                }
```

(d) Directly after the `.fileImporter { … }` modifier, add the sheet — on the `List`, never a
`Section`:

```swift
        // #157: attached to the LIST for the same reason `.fileImporter` is.
        .sheet(item: $pendingExport) { pending in
            ExportConfirmationSheet(
                destinationName: pending.destination.lastPathComponent,
                inventory: pending.inventory,
                onCancel: { pendingExport = nil },
                onExport: { scope in
                    pendingExport = nil
                    Task { await performExport(pending, scope: scope) }
                })
        }
```

(e) Add two private methods to `AboutView` (after `exportResultText`):

```swift
    /// #157 step 1 of 2: read what WOULD be exported and present the sheet. Reads the
    /// container (not the destination), so no security scope is needed here.
    private func stageExport(to destination: URL, requiresSecurityScope: Bool) async {
        guard let inventory = await exportRunner.inventory() else { return } // runner published .failed
        pendingExport = PendingExport(destination: destination, inventory: inventory,
                                      requiresSecurityScope: requiresSecurityScope)
    }

    /// #157 step 2 of 2: the owner confirmed. Security scope is opened HERE, around the
    /// write, exactly as the pre-#157 callback did — the picked URL keeps its scope until
    /// accessed, so deferring the start past the sheet is fine.
    private func performExport(_ pending: PendingExport, scope: ExportScope) async {
        let url = pending.destination
        if pending.requiresSecurityScope {
            guard url.startAccessingSecurityScopedResource() else {
                exportRunner.fail("could not access the selected folder")
                return
            }
        }
        defer { if pending.requiresSecurityScope { url.stopAccessingSecurityScopedResource() } }
        await exportRunner.run(into: url, scope: scope)
    }
```

Update the `AboutView` doc comment's export sentence (line 7-9) to: "…the T13 export action,
which writes only to a folder the owner explicitly picks AND confirms (#157) — never anywhere
else, and never anything under the app's own container."

- [ ] **Step 5: Run the new UI class to verify it passes**

Run the UI command with `-only-testing:RaconteUITests/ExportConfirmationUITests`.
Expected: `Executed 3 tests, with 0 failures`.

If `testDeselectingUnfiled…` fails because the label did not update, the `Toggle` tap missed the
switch: confirm the identifier is on the `Toggle` (not a wrapping row) and the dx offset matches
`JournalEditorUITests.toggle`.

- [ ] **Step 6: Run `AboutUITests` to prove the existing About test still passes**

Run the UI command with `-only-testing:RaconteUITests/AboutUITests`. Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 7: iOS compile check and macOS build**

iOS compile check from Global Constraints: `BUILD SUCCEEDED`. Then a plain macOS build (no
`test`) to prove the `#if os(macOS)` frame compiles:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- [ ] **Step 8: Commit**

```bash
git add Raconte/App/ExportConfirmationSheet.swift Raconte/App/AboutView.swift RaconteUITests/ExportConfirmationUITests.swift
git commit -m "feat(#157): export confirmation sheet with journal scope; harness destination for the UI test"
```

---

### Task 5: Full suites, stragglers, PR

**Files:**
- Modify: none expected (fix-ups only)

- [ ] **Step 1: Whole unit suite** (Global Constraints command, no `-only-testing`).

Expected: `Executed 2222 tests, with 1 test skipped and 0 failures` — baseline 2209 + 6 (Task 1)
+ 4 (Task 2) + 3 (Task 3). If the count differs, find out which test did not run before touching
anything else (a new file that `xcodegen generate` never picked up runs at the OLD count).

- [ ] **Step 2: UI suite, split by class**, three foreground invocations with `timeout: 600000`:

```
-only-testing:RaconteUITests/ExportConfirmationUITests -only-testing:RaconteUITests/AboutUITests -only-testing:RaconteUITests/NavigationUITests -only-testing:RaconteUITests/HomeUITests
```
```
-only-testing:RaconteUITests/CaptureUITests -only-testing:RaconteUITests/CaptureControlsUITests -only-testing:RaconteUITests/JournalEditorUITests -only-testing:RaconteUITests/BulkSelectUITests -only-testing:RaconteUITests/TrashRepairUITests
```
```
-only-testing:RaconteUITests/EntryDetailSheetUITests -only-testing:RaconteUITests/EntryPagingUITests -only-testing:RaconteUITests/ImageCaptureUITests -only-testing:RaconteUITests/TranscriptEditorUITests -only-testing:RaconteUITests/VoiceMarkingUITests
```

Expected: the three `Executed N tests` lines sum to **68** (65 + 3). List every UI test class with
`grep -l 'XCTestCase' RaconteUITests/*.swift` first and make sure the three invocations cover all
of them.

- [ ] **Step 3: Straggler greps** (all three targets):

```
grep -rn 'export(into: [a-zA-Z]*)' Raconte RaconteTests RaconteUITests
```
Every hit is either a deliberate `.all` default (fine) or a call site that should pass a scope
(there should be none besides `ExportRunner.run` which now forwards `scope`).

```
grep -rn 'AppContainer.root()' Raconte
```
Expected: no hit in `RaconteApp.swift`'s exporter construction (ruling 5). Other hits are
pre-existing and out of scope.

```
grep -rn 'foregroundStyle(.secondary)' Raconte/App/ExportConfirmationSheet.swift Raconte/App/AboutView.swift
```
Expected: zero.

- [ ] **Step 4: Push and open the PR** with `--body-file` (never a heredoc body), title
`feat(#157): export confirmation sheet + journal-scoped export`. Body must contain:

- What changed, per task, one line each.
- Rulings 1–5 restated (a reviewer must not have to open this plan).
- Executed counts: unit and UI, against the baseline `unit 2209 (1 skipped), UI 65` from run 34287217764.
- The trade-off in ruling 2 (`journals.json` whole → names of excluded journals travel), flagged
  for the owner explicitly.
- The smoke list below, verbatim.
- `Closes #157`.

```markdown
## Smoke (Mac, one at a time)

1. About → Archive → Export archive… → pick a folder on the Desktop. A sheet appears BEFORE
   anything is written: `To: <folder>`, one row per journal with its count, `Unfiled entries · N`
   only if you have any, and a button reading `Export N entries` where N equals the sum shown.
2. Cancel. The folder is still empty (Finder), About shows no `Exporting…` and no result row.
3. Export again, turn OFF every journal but one. The button's N drops to that journal's count.
   Confirm. Result row: `Exported N entries to <folder> — verified`. Open the package: `entries/`
   has N directories, `journals/` has only that journal's cover, `journals.json` is present.
4. About → Verify archive… on that package: `Verified …: M files, no problems`.
5. Export once more with everything on; the result row's N equals the total the sheet showed.
```

End at the open PR. Merging is the owner's.

---

## Self-review

- **Spec coverage.** #157 §1 confirmation naming destination + count → Task 4 (sheet:
  `about.export.destination`, `Export N entries`). §2 selection by journal → Tasks 1–2
  (`ExportScope`, filter) and Task 4 (toggles); "ideally by entry" is deferred (out of scope,
  stated in the PR). "Same exporter and same verifier" → Task 2's verify assertions on partial
  packages. "Full export stays default" → sheet starts all-on and resolves to `.all`
  (`testAllScopeWritesTheSamePackageAsTheUnscopedCall`). "Confirmation and selector are one
  screen" → ruling 1.
- **Placeholder scan.** No TBD/TODO; every code step has code; every test has a RED step with
  the expected failure text.
- **Type consistency.** `ExportScope.includes(bucket:)` (Tasks 1, 2); `ExportInventory.bucket(journalID:known:)`
  and `bucket(captureDirectory:known:)` (Tasks 1, 2); `ExportInventory.read(containerRoot:)`
  (Tasks 1, 3); `entryCount(for:)` (Tasks 1, 4); `ArchiveExporter.export(into:scope:)` (Tasks 2, 3);
  `ExportRunner.run(into:scope:)`, `inventory()` (Tasks 3, 4). `ExportInventory.JournalRow(id:name:entryCount:)`
  memberwise init used in Tasks 1, 3, 4 with the same argument order.
- **Counts.** Task 1 +6, Task 2 +4, Task 3 +3 → unit 2222; Task 4 +3 → UI 68.
