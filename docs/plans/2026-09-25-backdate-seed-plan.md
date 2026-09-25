# Backdate seed (2026-09-25) Implementation Plan — toggle-on seeds from the journal's last backdated entry (#175)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main` so that turning the backdate toggle on, with nothing carried this
session, pre-fills the day after the journal's most recently captured backdated entry instead
of today.

**Architecture:** A pure `BackdateSeed.seed(from:journalID:now:calendar:)` in a new
`Raconte/Library/BackdateSeed.swift` picks the journal's most recently CAPTURED, untrashed,
backdated `EntryListItem` and applies the advance rule (`.day` → next day, clamped to today;
`.yearMonth`/`.year` → unchanged). `CaptureScreenModel.setBackdateEnabled(true)` and `resolveBackdateForJournalChange()` (the
toggle-stays-on journal switch) both consult it only when `carriedBackdate()` is nil, so the
in-session carry (which #47 already advances after each commit) keeps precedence. The toggle is still never flipped on automatically. Nothing on
disk changes; the seed reads `library.allEntries`, which `bootstrap()` already fills.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest.

**Spec:** Issue #175 (`gh issue view 175`) — the four rulings there are restated under Global
Constraints. Precedent: `CaptureScreenModel.advanceBackdateForNextEntry()`
(`Raconte/Capture/UI/CaptureScreenModel.swift:626-639`) and its tests in
`RaconteTests/BackdateCarryOverTests.swift:190-282`.

## Global Constraints

- Branch `feat/175-backdate-seed` from `main` at or after `6b2c7100`. Work in a worktree
  (`../raconte-wt-175`); the main checkout stays on `main`. Run `xcodegen generate` in the
  worktree before the first build.
- **Do not run `xcodebuild test` until the orchestrator has said the owner's Mac app is
  quit.** The macOS unit suite launches `Raconte.app` as its test host under the same bundle
  id, which kills a running smoke build. Compile checks (`build`) are always fine.
- **Rulings (owner, 2026-09-25; do not re-open):**
  1. "Previous backdate" = the backdate of the journal's most recently CAPTURED entry that has
     one (`max` by `capturedAt`), never the latest backdate. Entries with `originalDate == nil`
     and trashed entries are ignored.
  2. `.day` precision seeds the NEXT day. `.yearMonth` and `.year` seed the same value,
     unchanged (`PartialDate.nextDay` already returns nil below `.day`).
  3. Never later than today: if the next day is in the future, seed today at `.day`.
  4. In-session carry outranks the seed. The seed is read only when `carriedBackdate()` is nil,
     at the two moments the picker is pre-filled: the toggle going from off to on, and a
     journal switch while the toggle stays on. The toggle is never auto-enabled.
- The seed is per journal (`selectedJournalID`); with no selected journal there is no seed.
- Straggler greps run over all three targets (`Raconte RaconteTests RaconteUITests`), never one.
- Test-count baseline (main run 34497525407, the #174 merge, last green CODE run):
  **unit 2229, 1 skipped; UI 67.** Every task reports the executed count. Bash
  `timeout: 600000` on every xcodebuild.
- macOS unit test command (sandbox kept; never `CODE_SIGNING_ALLOWED=NO`). Narrow with
  `-only-testing:RaconteTests/<Class>` for the fast loop; run the whole unit suite once in
  Task 3:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- iOS compile check (must pass on every task):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- No UI test in this plan: the behaviour is a model rule with no new control, and
  `BackdateCarryOverTests` already drives the real capture pipeline with fakes.
- Commit after each task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

## Review Focus

1. Two backdated entries where the OLDER backdate was captured LAST (a gap being back-filled):
   the seed follows capture order, so it is the older date plus one. Pinned in Task 1
   (`testFollowsCaptureOrderNotDateOrder`).
2. A non-backdated entry captured after the last backdated one must not push the seed to
   today. Pinned in Task 1 (`testIgnoresEntriesWithoutABackdate`) and end to end in Task 2
   (`testASeedSurvivesAnUndatedCaptureInBetween`).
3. A trashed backdated entry is not a seed source. Pinned in Task 1
   (`testIgnoresTrashedEntries`).
4. A carried value from this session must win over the disk seed, even when the disk holds a
   newer entry. Pinned in Task 2 (`testInSessionCarryOutranksTheDiskSeed`).
5. The seed must read the SELECTED journal, not another journal's newest entry. Pinned in
   Task 1 (`testSeedIsPerJournal`) and Task 2 (`testSeedDoesNotCrossJournalsAfterRelaunch`).

---

### Task 1: `BackdateSeed`, pure and unit-pinned

**Files:**
- Create: `Raconte/Library/BackdateSeed.swift`
- Create: `RaconteTests/BackdateSeedTests.swift`
- Modify: none (then `xcodegen generate` — both files are new)

**Interfaces:**
- Consumes: `EntryListItem` (`Raconte/Library/EntryListItem.swift:171` init
  `(captureID:capturedAt:…)`; `.journalID: String?` get/set, `.originalDate: PartialDate?`
  get/set, `.isTrashed: Bool`, `.capturedAt: Date`), `EntryMetadata.trashedAt`,
  `PartialDate` (`Raconte/Library/PartialDate.swift`: `init(year:month:day:)`,
  `init(from:precision:calendar:)`, `.precision`, `nextDay(calendar:) -> PartialDate?`,
  `isFuture(now:calendar:) -> Bool`), `Calendar.gregorianCurrent`.
- Produces, used by Task 2:

```swift
enum BackdateSeed {
    /// Ruling 1–3 of #175. `nil` when the journal has no untrashed backdated entry.
    static func seed(from entries: [EntryListItem], journalID: String,
                     now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> PartialDate?
}
```

- [ ] **Step 1: Write the failing tests**

Create `RaconteTests/BackdateSeedTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #175: the pre-fill for a backdate toggle turned on with nothing carried this session.
/// Pure — every rule about which entry counts and how its date advances is reachable
/// with no disk, no model and no clock beyond the injected `now`.
final class BackdateSeedTests: XCTestCase {

    private let calendar = Calendar.gregorianCurrent

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func item(journal: String?, capturedAt: Date, backdate: PartialDate?,
                      trashed: Bool = false) -> EntryListItem {
        var item = EntryListItem(captureID: ULID.make(), capturedAt: capturedAt)
        item.journalID = journal
        item.originalDate = backdate
        if trashed { item.metadata.trashedAt = capturedAt }
        return item
    }

    /// The plain case: one day-precision backdated entry seeds the day after.
    func testDayPrecisionSeedsTheNextDay() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1),
                            backdate: PartialDate(year: 1987, month: 6, day: 12))]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Ruling 2: month and year precision carry unchanged — a 1998 journal does not turn a
    /// page per year.
    func testCoarserPrecisionSeedsTheSameValue() {
        let month = [item(journal: "A", capturedAt: date(2026, 9, 1),
                          backdate: PartialDate(year: 1987, month: 6))]
        XCTAssertEqual(BackdateSeed.seed(from: month, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6))
        let year = [item(journal: "A", capturedAt: date(2026, 9, 1),
                         backdate: PartialDate(year: 1987))]
        XCTAssertEqual(BackdateSeed.seed(from: year, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987))
    }

    /// Ruling 3: never later than today. Yesterday seeds today; today seeds today.
    func testNextDayIsClampedToToday() {
        let now = date(2026, 9, 25)
        let today = PartialDate(from: now, precision: .day, calendar: calendar)
        let yesterday = [item(journal: "A", capturedAt: now,
                              backdate: PartialDate(year: 2026, month: 9, day: 24))]
        XCTAssertEqual(BackdateSeed.seed(from: yesterday, journalID: "A", now: now), today)
        let sameDay = [item(journal: "A", capturedAt: now, backdate: today)]
        XCTAssertEqual(BackdateSeed.seed(from: sameDay, journalID: "A", now: now), today,
                       "tomorrow would be refused at the sidecar — keep today")
    }

    /// Ruling 1: capture order, not date order. Back-filling an older gap after newer
    /// pages means "continue from the gap", so the older date plus one wins.
    func testFollowsCaptureOrderNotDateOrder() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1990, month: 1, day: 1)),
            item(journal: "A", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
        // Order of the array is not the order of capture.
        XCTAssertEqual(BackdateSeed.seed(from: entries.reversed(), journalID: "A",
                                         now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// A newer entry with no backdate is not "backdated to its capture day"; it is
    /// skipped, and the last backdated entry still seeds.
    func testIgnoresEntriesWithoutABackdate() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2), backdate: nil),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// A trashed entry is on its way out; it must not steer the next capture.
    func testIgnoresTrashedEntries() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "A", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1999, month: 1, day: 1), trashed: true),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Per journal: journal B's newer entry is invisible to journal A's seed, and an
    /// unfiled entry belongs to neither.
    func testSeedIsPerJournal() {
        let entries = [
            item(journal: "A", capturedAt: date(2026, 9, 1),
                 backdate: PartialDate(year: 1987, month: 6, day: 12)),
            item(journal: "B", capturedAt: date(2026, 9, 2),
                 backdate: PartialDate(year: 1999, month: 1, day: 1)),
            item(journal: nil, capturedAt: date(2026, 9, 3),
                 backdate: PartialDate(year: 2001, month: 1, day: 1)),
        ]
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(BackdateSeed.seed(from: entries, journalID: "B", now: date(2026, 9, 25)),
                       PartialDate(year: 1999, month: 1, day: 2))
        XCTAssertNil(BackdateSeed.seed(from: entries, journalID: "C", now: date(2026, 9, 25)))
    }

    /// Nothing backdated in the journal: no seed, so the caller falls back to today.
    func testNoBackdatedEntryMeansNoSeed() {
        let entries = [item(journal: "A", capturedAt: date(2026, 9, 1), backdate: nil)]
        XCTAssertNil(BackdateSeed.seed(from: entries, journalID: "A", now: date(2026, 9, 25)))
        XCTAssertNil(BackdateSeed.seed(from: [], journalID: "A", now: date(2026, 9, 25)))
    }
}
```

- [ ] **Step 2: Create the source file with a stub so the tests compile, then verify RED**

Create `Raconte/Library/BackdateSeed.swift`:

```swift
import Foundation

enum BackdateSeed {
    static func seed(from entries: [EntryListItem], journalID: String,
                     now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> PartialDate? {
        nil
    }
}
```

Run `xcodegen generate`, then:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/BackdateSeedTests test 2>&1 | grep -E "Executed|error:|failed" | tail -12
```

Expected: `Executed 8 tests` with 7 failures. Only `testNoBackdatedEntryMeansNoSeed` passes
against the stub; every other test fails on an `XCTAssertEqual` against nil. If a test does
not fail here, it cannot fail later — fix the test before moving on.

- [ ] **Step 3: Implement the rule**

Replace the body of `Raconte/Library/BackdateSeed.swift`:

```swift
import Foundation

/// #175: the pre-fill for the backdate toggle when nothing has been carried this session.
///
/// `CaptureScreenModel.carriedBackdates` is in-memory by design (a sitting's convenience,
/// not a preference), so the first backdated entry after a relaunch used to open at today.
/// This reads the journal's own history instead. Rulings, all owner's (issue #175):
/// - the source is the most recently CAPTURED backdated entry, never the latest backdate —
///   "continue where I left off", which also does the right thing when an older gap is
///   being back-filled after newer pages;
/// - untrashed only, and an entry with no backdate is skipped, not read as its capture day;
/// - `.day` advances one day (`PartialDate.nextDay`), coarser precisions carry unchanged;
/// - never past today: the sidecar would refuse it (`EntryMetadata.setOriginalDate`), so a
///   next day in the future becomes today at `.day`.
///
/// Pure: `now` is injected so the clamp is testable on a fixed date.
enum BackdateSeed {
    static func seed(from entries: [EntryListItem], journalID: String,
                     now: Date = Date(), calendar: Calendar = .gregorianCurrent) -> PartialDate? {
        let source = entries
            .filter { $0.journalID == journalID && !$0.isTrashed && $0.originalDate != nil }
            .max { $0.capturedAt < $1.capturedAt }
        guard let previous = source?.originalDate else { return nil }
        guard let next = previous.nextDay(calendar: calendar) else { return previous }
        if next.isFuture(now: now, calendar: calendar) {
            return PartialDate(from: now, precision: .day, calendar: calendar)
        }
        return next
    }
}
```

- [ ] **Step 4: Run the class again and verify GREEN**

Same command as Step 2. Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: iOS compile check, then commit**

Run the iOS compile check from Global Constraints. Expected `BUILD SUCCEEDED`.

```bash
git add Raconte/Library/BackdateSeed.swift RaconteTests/BackdateSeedTests.swift
git commit -m "feat(#175): BackdateSeed — the journal's last backdated capture, advanced a day

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `setBackdateEnabled(true)` seeds from the library when nothing is carried

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift:146-155` (doc comment on
  `carriedBackdates`), `:552-576` (`setBackdateEnabled`), `:592-594` (next to
  `carriedBackdate()`), `:596-616` (`resolveBackdateForJournalChange`)
- Test: `RaconteTests/BackdateCarryOverTests.swift` (append to the existing class; its
  private `date(_:_:_:)`, `makeModel()`, `waitUntil`, `CarryOverFakeRecorder` and
  `CarryOverFakeSession` are reused as-is)

**Interfaces:**
- Consumes: `BackdateSeed.seed(from:journalID:now:calendar:)` from Task 1;
  `library.allEntries: [EntryListItem]` (`Raconte/Library/LibraryScreenModel.swift:78`,
  filled by `library.rescan()` at the end of `performBootstrap()` and after every commit).
- Produces (read by the view only through the existing pre-fill; exposed for tests):

```swift
/// The #175 seed for the selected journal, or nil. Reads `library.allEntries`.
func seededBackdate(now: Date = Date()) -> PartialDate?
```

- [ ] **Step 1: Write the failing tests**

Append inside `final class BackdateCarryOverTests` in
`RaconteTests/BackdateCarryOverTests.swift`, before the closing brace:

```swift
    // MARK: seed from the journal's last backdated entry (#175)

    /// Drives one backdated capture to commit on `model`, exactly as the #47 tests do.
    private func commitBackdatedCapture(_ model: CaptureScreenModel,
                                        recorder: CarryOverFakeRecorder,
                                        _ backdate: Date, precision: DatePrecision = .day) async {
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(precision)
        model.setBackdateDate(backdate)
        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")
    }

    private func makeModel(recorder: CarryOverFakeRecorder) -> CaptureScreenModel {
        CaptureScreenModel(capturesRoot: root,
                           makeSession: { CarryOverFakeSession() },
                           makeRecorder: { recorder },
                           encoder: FakeAudioEncoder())
    }

    /// The gap #175 closes: a relaunch (a fresh model on the same root) has no in-memory
    /// carry, so turning the toggle on used to open at today. It now opens at the day
    /// after the last backdated capture in this journal.
    func testAfterRelaunchTheToggleSeedsTheDayAfterTheLastBackdatedCapture() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let journal = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.selectedJournalID, journal)
        XCTAssertNil(relaunched.carriedBackdate(), "sanity: a fresh model carries nothing")
        XCTAssertFalse(relaunched.backdateEnabled, "the seed never flips the toggle on")

        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(relaunched.backdatePrecision, .day)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(relaunched.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 13),
                       "the seed becomes this session's carry, so off/on repeats it")
    }

    /// Coarser precision seeds unchanged, precision included — a 1987-06 sitting must not
    /// come back as a day-precision picker.
    func testAfterRelaunchAYearMonthBackdateSeedsTheSameMonth() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12),
                                     precision: .yearMonth)

        let relaunched = makeModel()
        await relaunched.bootstrap()
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(relaunched.backdatePrecision, .yearMonth)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .yearMonth,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6))
    }

    /// An undated capture after the backdated one does not reset the seed to today.
    func testASeedSurvivesAnUndatedCaptureInBetween() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        first.setBackdateEnabled(false)
        let live = first.coordinator
        await first.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await first.done()
        await waitUntil({ first.coordinator !== live }, timeout: 10, "capture never finished")

        let relaunched = makeModel()
        await relaunched.bootstrap()
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// Ruling 4: what was dialled this session outranks what is on disk, even when the
    /// disk holds a NEWER capture from another session on the same root.
    func testInSessionCarryOutranksTheDiskSeed() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))

        let second = makeModel()
        await second.bootstrap()
        second.setBackdateEnabled(true)
        second.setBackdateDate(date(1991, 2, 3))   // dialled by hand this session
        second.setBackdateEnabled(false)
        // Another session writes a newer backdated capture to the same root meanwhile.
        let other = makeModel(recorder: recorder)
        await other.bootstrap()
        await commitBackdatedCapture(other, recorder: recorder, date(2001, 1, 1))
        await second.library.rescan()

        second.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: second.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1991, month: 2, day: 3),
                       "the carried 1991 wins over the seed's 2001-01-02")
    }

    /// Journal B's newest entry is invisible when journal A is selected after a relaunch.
    func testSeedDoesNotCrossJournalsAfterRelaunch() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let a = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        let created = await first.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        await commitBackdatedCapture(first, recorder: recorder, date(1999, 1, 1))
        XCTAssertEqual(first.selectedJournalID, b.id, "sanity: the 1999 capture filed into B")

        let relaunched = makeModel()
        await relaunched.bootstrap()
        relaunched.selectJournal(a)
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        // The toggle stays on across the switch: B is pre-filled from B's own history.
        relaunched.selectJournal(b.id)
        XCTAssertTrue(relaunched.backdateEnabled)
        XCTAssertEqual(relaunched.seededBackdate(), PartialDate(year: 1999, month: 1, day: 2),
                       "B's own seed is B's last capture plus one")
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1999, month: 1, day: 2),
                       "a journal switch with the toggle on pre-fills from the seed too")
        XCTAssertNil(relaunched.carriedBackdate(),
                     "the switch path never invents a carry for B (existing rule)")
    }

    /// A journal with no backdated entry still opens at today: no seed, no surprise.
    func testAJournalWithNoBackdatedEntrySeedsNothing() async throws {
        let model = makeModel()
        await model.bootstrap()
        XCTAssertNil(model.seededBackdate())
        model.setBackdateEnabled(true)
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()))
        XCTAssertEqual(model.backdatePrecision, .day)
    }
```

Note `makeModel(recorder:)` is a NEW overload next to the existing no-argument `makeModel()`;
both stay.

- [ ] **Step 2: Add the accessor stub so the file compiles, then verify RED**

In `Raconte/Capture/UI/CaptureScreenModel.swift`, directly after `carriedBackdate()`
(line 594), add:

```swift
    /// #175: the pre-fill when nothing has been carried this session — the day after the
    /// selected journal's most recently captured backdated entry (see `BackdateSeed`).
    /// Exposed for the tests that pin the seed rule; the view reads it only through the
    /// pre-fill in `setBackdateEnabled`.
    func seededBackdate(now: Date = Date()) -> PartialDate? {
        guard let journalID = selectedJournalID else { return nil }
        return BackdateSeed.seed(from: library.allEntries, journalID: journalID, now: now)
    }
```

Run:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/BackdateCarryOverTests test 2>&1 | grep -E "Executed|error:|failed" | tail -14
```

Expected: `Executed 15 tests` (9 existing + 6 new). The four relaunch/seed tests
(`testAfterRelaunchTheToggleSeedsTheDayAfterTheLastBackdatedCapture`,
`testAfterRelaunchAYearMonthBackdateSeedsTheSameMonth`,
`testASeedSurvivesAnUndatedCaptureInBetween`, `testSeedDoesNotCrossJournalsAfterRelaunch`)
FAIL on the `PartialDate` equality (the dial still reads today).
`testInSessionCarryOutranksTheDiskSeed` and `testAJournalWithNoBackdatedEntrySeedsNothing`
pass already (they pin behaviour the change must NOT break). The 9 existing tests stay green.

- [ ] **Step 3: Wire the seed into the toggle**

In `setBackdateEnabled(_:)` (`CaptureScreenModel.swift:559-576`), replace

```swift
        if enabled {
            if !wasEnabled, let carried = carriedBackdate() {
                backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
                backdatePrecision = carried.precision
            }
            rememberBackdate()
        } else {
```

with

```swift
        if enabled {
            // Off → on pre-fills: this session's carry first, else the journal's own
            // history (#175). Carry wins because it is what the owner dialled; the seed
            // is a guess from disk. Either way `rememberBackdate()` below turns the
            // pre-fill into the carry, so off/on again repeats it.
            if !wasEnabled, let prefill = carriedBackdate() ?? seededBackdate() {
                backdateDate = prefill.anchorDate(calendar: .gregorianCurrent)
                backdatePrecision = prefill.precision
            }
            rememberBackdate()
        } else {
```

In `resolveBackdateForJournalChange()` (`:607-616`), replace

```swift
        guard backdateEnabled else { return }
        if let carried = carriedBackdate() {
            backdateDate = carried.anchorDate(calendar: .gregorianCurrent)
            backdatePrecision = carried.precision
        } else {
```

with

```swift
        guard backdateEnabled else { return }
        // Same precedence as `setBackdateEnabled`: this session's carry, else the
        // journal's own history (#175), else today. Still no `rememberBackdate()`.
        if let prefill = carriedBackdate() ?? seededBackdate() {
            backdateDate = prefill.anchorDate(calendar: .gregorianCurrent)
            backdatePrecision = prefill.precision
        } else {
```

Update the method's doc comment (`:552-558`): replace the sentence
`Turning it *on* pre-fills from the last backdate set in this journal this session, if there is one — date and precision together, since carrying a 1987 day-precision picker over a year-precision sitting would re-invent the fabricated-day problem.`
with
`Turning it *on* pre-fills from the last backdate set in this journal this session if there is one, else from the journal's most recently captured backdated entry advanced a day (#175, `BackdateSeed`) — date and precision together, since carrying a 1987 day-precision picker over a year-precision sitting would re-invent the fabricated-day problem.`

Update the `carriedBackdates` doc comment (`:146-155`): after the sentence ending
`a relaunch a week later should not pre-fill 1987.` add
`(#175 softens that for the first toggle-on after a relaunch: with nothing carried, `seededBackdate()` reads the journal's own last backdated entry off the library instead of opening at today.)`

- [ ] **Step 4: Run the class and verify GREEN**

Same command as Step 2. Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Straggler grep, iOS compile check, commit**

```
grep -rn "pre-fills from the last backdate set in this journal this session" Raconte RaconteTests RaconteUITests
```

Expected: zero hits (the old sentence is gone). Then the iOS compile check from Global
Constraints: `BUILD SUCCEEDED`.

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/BackdateCarryOverTests.swift
git commit -m "feat(#175): backdate toggle-on seeds from the journal's last backdated capture when nothing is carried

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Whole unit suite, issue cross-reference, PR

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift:626-632` (doc comment on
  `advanceBackdateForNextEntry`, one sentence)

- [ ] **Step 1: Point the #47 rule at its sibling**

In the doc comment above `advanceBackdateForNextEntry` (`:626-632`), after the sentence
ending `consecutive pages of a paper journal are usually consecutive days.` add
`This is the in-sitting half; the first toggle-on after a relaunch gets the same day-after
rule from `BackdateSeed` (#175).`

- [ ] **Step 2: Run the whole macOS unit suite**

Run the full unit command from Global Constraints (no `-only-testing`).
Expected: `Executed 2243 tests, with 1 test skipped and 0 failures` — the baseline 2229 plus
8 (Task 1) plus 6 (Task 2). If the number is 2229, `xcodegen generate` was skipped and the
new test file never ran.

- [ ] **Step 3: iOS compile check, commit, push, open the PR**

iOS compile check from Global Constraints: `BUILD SUCCEEDED`.

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift
git commit -m "docs(#175): advanceBackdateForNextEntry names its relaunch sibling

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat/175-backdate-seed
```

Write the PR body to a file, then `gh pr create --title "feat(#175): backdate toggle-on seeds from the journal's last backdated capture" --body-file <file>`. The body states: the rulings 1–4, the executed counts (unit 2243 vs baseline 2229), that no UI test was added and why, and the owner smoke below. It ends with the line
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge; the merge is the owner's.

Owner smoke to put in the PR body (build number to be filled in by the orchestrator):

1. About → App → Build shows the new number.
2. Pick a journal that already has a backdated entry; note that entry's date D.
3. Quit and relaunch the app. On the capture screen turn Backdate on. Pass: the picker shows
   D plus one day (or D itself if D was a month or a year). Fail: it shows today.
4. Record one backdated entry, then check the picker again. Pass: it moved forward one more
   day (that part is #47, already shipped).
