# Journal Editing IA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move journal editing off the capture screen into a purpose-built editor reached from the journals list, give journals a stored date span, and structurally kill #69 along the way.

**Architecture:** The capture screen's journal picker becomes selection-only (journals + New Journal), which removes the `Image` from inside a macOS `Menu` label and fixes #69 by construction. A journal gains an optional `JournalSpan` of two `PartialDate`s, stored in `journals.json`, which outranks the derived `JournalDateRange` for display. Selecting a journal in the sidebar now shows a journal header above its entries; tapping that header pushes a `JournalEditorView` carrying name, cover, span and voice labels.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI multiplatform (iOS 26 + macOS 26), XCTest. Xcode project is generated — `project.yml` is source of truth.

**Spec:** `docs/plans/2026-08-18-journal-editing-ia-design.md` — read it before Task 1. It carries the nine owner rulings this plan implements.

---

## Global Constraints

- **Branch:** cut from `main`. Do NOT build this on `m4/sync`. `main` has no `Raconte/Sync/` and `Journal` on main has no `modified` field — the sync half is a separate, tripwire-enforced task on `m4/sync` (spec §"Branch split"). Never add a `modified` key in this plan.
- **`xcodegen generate` after adding ANY new file.** Omitting it makes `-only-testing` report "Executed 0 tests" and **exit 0** — a silent pass (CLAUDE.md:545).
- **macOS unit tests:** `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test`
- **iOS UI tests:** `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test`
- **Never pipe `xcodebuild` through `head`** — it wedges the simulator's accessibility service and fails unrelated UI tests afterwards. **Run every suite in the FOREGROUND**; do not background a build you intend to wait on.
- **Baseline (verified 2026-08-18 on `main` at `c7b3b22c`): 1319 unit tests, 1 failure.** That failure is `BuildStampTests.testLoadedImageUUIDFindsARealLoadedMachOImage`, a known laptop-local intermittent. Any OTHER failure is yours.
- **Source-scanning tests MUST call `strippingComments(_:)`** from `RaconteTests/SourceScanning.swift`. This repo documents itself heavily; a raw grep is satisfied by the comment explaining the fix.
- **Never write a close-verb + issue number** ("fixes #69", "close #69") in a commit message or PR body, including in prose. GitHub closes the issue on merge. Write "for #69" / "part of #69".
- **Call shared primitives, never copy them.** If a helper is `private` and you need it, lift it — do not duplicate.
- **UI tests reach places through `openPlace(app, "sidebar.…")`** in `RaconteUITests/UITestNavigation.swift`. Never hard-code a navigation tap.
- **TDD with verified RED.** A compile error is NOT acceptable RED evidence. For SwiftUI view wiring (unit-untestable by this repo's convention), verify RED by `git stash push` on just the production files, running the new UI test against the stashed-out code, then popping.

---

## File Structure

**Created:**
- `Raconte/Library/JournalSpan.swift` — the span value type, its validation, and precision-aware containment. Pure, no SwiftUI.
- `Raconte/Library/UI/JournalHeaderCard.swift` — the journal identity header shown above a journal's entry list.
- `Raconte/Library/UI/JournalEditorView.swift` — the pushed editor screen.
- `Raconte/Library/UI/JournalSpanEditor.swift` — the two-endpoint span control used by the editor.
- `RaconteTests/JournalSpanTests.swift`, `RaconteTests/JournalDateLineTests.swift`, `RaconteTests/JournalHeaderSourceTests.swift`
- `RaconteUITests/JournalEditorUITests.swift`

**Modified:**
- `Raconte/Capture/UI/CaptureView.swift` — `JournalHeaderView` (Task 1 only).
- `Raconte/Library/Journal.swift` — `span` field, decoder, encoder, `CodingKeys`, `JournalRegistry.setSpan`, `JournalError.invalidSpan`.
- `Raconte/Library/JournalStore.swift` — `setSpan(id:span:)`.
- `Raconte/Library/JournalDateRange.swift` — lift `coarser` off `private`.
- `Raconte/Library/LibraryScreenModel.swift` — `dateLine(forJournal:)`, `setJournalSpan`.
- `Raconte/Library/UI/LibraryView.swift` — `LibraryDestination.journalEditor`, journal header mount.
- `Raconte/App/ContentView.swift` — thread journal identity into `LibraryView`, add the editor destination.
- `Raconte/App/SidebarView.swift` — `+` toolbar button.

---

### Task 1: Capture picker becomes selection-only

Kills #69 structurally. Also folds in #65.

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`JournalHeaderView`, ~397-520)
- Test: `RaconteTests/JournalHeaderSourceTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. `JournalHeaderView` keeps `Menu`/`selectJournal`/`createJournal`; loses `showingRenamePrompt`, `showingCoverPicker`, `showingVoiceLabels`, and their `.sheet`/`.alert` modifiers.

- [ ] **Step 1: Write the failing source-scan test**

```swift
import XCTest

/// #69: on macOS a `Menu`'s label discards SwiftUI's sizing of a resizable `Image` and
/// paints it at intrinsic size. A 768x1024 cover therefore laid out at 768x1024 POINTS,
/// covering the whole setup region and pushing the picker's own name+chevron off the
/// right edge of the window — which is why the journal picker stopped working entirely.
///
/// Proven by a six-variant harness (spec appendix): no in-place clamp and no `.menuStyle`
/// fixes it; the image must leave the label. There is no UI-test pin available — the bug
/// is macOS-only and this project cannot run macOS UI tests — so this scan is the pin.
final class JournalHeaderSourceTests: XCTestCase {
    private var captureViewSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // RaconteTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Raconte/Capture/UI/CaptureView.swift")
            return strippingComments(try String(contentsOf: url))
        }
    }

    func testCaptureScreenRendersNoJournalCover() throws {
        XCTAssertFalse(try captureViewSource.contains("JournalCoverThumbnail"),
                       "#69: a cover inside this file's Menu label renders full-bleed on "
                       + "macOS and makes the journal picker unusable")
    }

    func testCapturePickerOffersNoJournalEditing() throws {
        let source = try captureViewSource
        for removed in ["Cover Photo", "Voice Labels", "Rename "] {
            XCTAssertFalse(source.contains(removed),
                           "journal editing moved to JournalEditorView (spec ruling 6); "
                           + "\(removed) must not be back on the capture screen")
        }
    }

    func testCapturePickerStillOffersSelectionAndCreation() throws {
        let source = try captureViewSource
        XCTAssertTrue(source.contains("selectJournal"))
        XCTAssertTrue(source.contains("New Journal"))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it fails**

```bash
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalHeaderSourceTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: `testCaptureScreenRendersNoJournalCover` and `testCapturePickerOffersNoJournalEditing` FAIL. `testCapturePickerStillOffersSelectionAndCreation` passes already — that is correct, it is a guard against over-deletion in step 3, not a red test.

Confirm the run reports a non-zero test count. "Executed 0 tests" with exit 0 means you skipped `xcodegen generate`.

- [ ] **Step 3: Strip editing out of `JournalHeaderView`**

In `Raconte/Capture/UI/CaptureView.swift`:

Delete the `@State` properties `showingRenamePrompt`, `showingCoverPicker`, `showingVoiceLabels`, and `draftName`'s rename usage (keep `draftName` — New Journal still needs it).

The `Menu` becomes:

```swift
Menu {
    ForEach(model.journals) { journal in
        Button {
            model.selectJournal(journal.id)
        } label: {
            if journal.id == model.selectedJournalID {
                Label(menuTitle(for: journal), systemImage: "checkmark")
            } else {
                Text(menuTitle(for: journal))
            }
        }
    }
    Divider()
    Button("New Journal…") {
        draftName = ""
        showingNewJournalPrompt = true
    }
} label: {
    HStack(spacing: 6) {
        Text(model.selectedJournalName)
            .captureLabel(.journalName)
            .fontWeight(.semibold)
        Image(systemName: "chevron.up.chevron.down")
            .captureLabel(.journalPickerChevron)
    }
    .foregroundStyle(.white)
}
// #65: the container identifier was overwriting its descendants', which made
// `capture.journalPicker` invisible to XCUITest (confirmed in a live AX dump).
// `.combine` flattens the label into ONE element that keeps both an explicit
// label and this identifier, instead of the identifier being swallowed.
.accessibilityElement(children: .combine)
.accessibilityLabel("Recording into \(model.selectedJournalName)")
.accessibilityIdentifier("capture.journalPicker")
.environment(\.colorScheme, .dark)
```

Delete the `.sheet(isPresented: $showingCoverPicker)`, the `.sheet(isPresented: $showingVoiceLabels)` and the `.alert("Rename Journal", …)` modifiers attached to the enclosing `VStack`. Keep the `.alert("New Journal", …)`.

Do NOT delete `JournalCoverPickerSheet` or `JournalVoiceLabelsSheet` themselves — Tasks 5 and 7 re-mount them from the editor.

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalHeaderSourceTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: 3 tests, PASS.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: 1322 tests, 1 failure (the known `BuildStampTests` local intermittent). Some `CaptureUITests` may reference the removed menu items — if a UI test fails, reroute it rather than deleting the assertion.

- [ ] **Step 6: Commit**

```bash
git add RaconteTests/JournalHeaderSourceTests.swift Raconte/Capture/UI/CaptureView.swift
git commit -m "fix: capture journal picker is selection-only, no cover in the Menu label

On macOS a Menu label discards a resizable Image's frame and paints it at
intrinsic size, so a 768x1024 cover covered the whole setup region and pushed
the picker's own label off-screen — the picker stopped working. Part of #69.
Rename/Cover/Voice Labels move to the journal editor (spec ruling 6). Also
gives the picker a combined AX element so its identifier survives, for #65."
```

---

### Task 2: `JournalSpan` — the stored date range

**Files:**
- Create: `Raconte/Library/JournalSpan.swift`
- Modify: `Raconte/Library/JournalDateRange.swift:70` (lift `coarser`)
- Test: `RaconteTests/JournalSpanTests.swift` (create)

**Interfaces:**
- Consumes: `PartialDate` (`Raconte/Library/PartialDate.swift`), `DatePrecision` (`Raconte/Library/EntryMetadata.swift:26`).
- Produces:
  - `struct JournalSpan: Codable, Sendable, Equatable, Hashable { var start: PartialDate; var end: PartialDate? }`
  - `init(start:end:) throws` — throws `JournalSpanError.inverted`
  - `func contains(_ date: Date, calendar: Calendar = .gregorianCurrent) -> Bool`
  - `func formatted(calendar: Calendar = .gregorianCurrent) -> String`
  - `static func coarser(_ a: DatePrecision, _ b: DatePrecision) -> DatePrecision` on `DatePrecision`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// Spec: "the span the PAPER journal covers, as its owner knows it".
///
/// THE TRAP THIS FILE EXISTS FOR: `PartialDate` is `Comparable` by `anchorDate`, which
/// fills absent components with the FIRST — "2001" anchors to 1 Jan 2001. So a naive
/// `start <= d && d <= end` would call every entry after 1 Jan 2001 out-of-range for a
/// journal spanning "1998 – 2001". Each endpoint must expand to its precision's UNIT:
/// start to the earliest instant of that unit, end to the LATEST.
final class JournalSpanTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Validation

    func testInvertedSpanIsRejected() {
        XCTAssertThrowsError(try JournalSpan(start: PartialDate(year: 2001),
                                             end: PartialDate(year: 1998))) { error in
            XCTAssertEqual(error as? JournalSpanError, .inverted)
        }
    }

    func testOpenEndedSpanIsAllowed() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertNil(span.end)
    }

    func testEqualEndpointsAreAllowed() throws {
        _ = try JournalSpan(start: PartialDate(year: 1998), end: PartialDate(year: 1998))
    }

    /// Inversion is judged at the COARSEST common precision: "Mar 1998" to "1998" is not
    /// inverted, because the end bound means "the end of 1998", which is after March.
    func testMixedPrecisionEndIsNotInvertedWhenItsUnitExtendsPastTheStart() throws {
        _ = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                            end: PartialDate(year: 1998))
    }

    // MARK: Containment — the whole point

    func testYearPrecisionEndBoundCoversTheWholeYear() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        XCTAssertTrue(span.contains(date(2001, 12, 31), calendar: cal),
                      "an end bound of \"2001\" means 31 Dec 2001, not 1 Jan")
        XCTAssertTrue(span.contains(date(1998, 1, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(2002, 1, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1997, 12, 31), calendar: cal))
    }

    func testMonthPrecisionEndBoundCoversTheWholeMonth() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 1998, month: 8))
        XCTAssertTrue(span.contains(date(1998, 8, 31), calendar: cal))
        XCTAssertTrue(span.contains(date(1998, 3, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 9, 1), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 2, 28), calendar: cal))
    }

    func testDayPrecisionBoundsAreInclusive() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3, day: 4),
                                   end: PartialDate(year: 1998, month: 3, day: 6))
        XCTAssertTrue(span.contains(date(1998, 3, 4), calendar: cal))
        XCTAssertTrue(span.contains(date(1998, 3, 6), calendar: cal))
        XCTAssertFalse(span.contains(date(1998, 3, 7), calendar: cal))
    }

    func testOpenEndedSpanContainsEverythingAfterItsStart() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertTrue(span.contains(date(2026, 8, 18), calendar: cal))
        XCTAssertFalse(span.contains(date(1997, 12, 31), calendar: cal))
    }

    func testLeapDayIsInsideAFebruaryMonthBound() throws {
        let span = try JournalSpan(start: PartialDate(year: 2024, month: 2),
                                   end: PartialDate(year: 2024, month: 2))
        XCTAssertTrue(span.contains(date(2024, 2, 29), calendar: cal),
                      "a month bound must expand to that month's real length")
    }

    // MARK: Codable

    func testCodableRoundTripsAsTwoPartialDateStrings() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998, month: 3),
                                   end: PartialDate(year: 2001))
        let data = try JSONEncoder().encode(span)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"end":"2001","start":"1998-03"}"#)
        XCTAssertEqual(try JSONDecoder().decode(JournalSpan.self, from: data), span)
    }

    func testOpenEndedSpanOmitsTheEndKey() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        let data = try JSONEncoder().encode(span)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"start":"1998"}"#)
    }

    func testDecodingAnInvertedSpanThrows() {
        let data = Data(#"{"start":"2001","end":"1998"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JournalSpan.self, from: data),
                             "the invariant must hold for values that arrive off disk too")
    }
}
```

Note: `JSONEncoder` sorts keys only with `.sortedKeys`. The two exact-string assertions above assume the repo's `CaptureCoding.lineEncoder()` shape (sorted keys). If a bare `JSONEncoder()` emits unsorted keys, set `encoder.outputFormatting = .sortedKeys` in the test rather than relaxing the assertion.

- [ ] **Step 2: Run to verify it fails**

```bash
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalSpanTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: FAIL — "cannot find 'JournalSpan' in scope". **That is a compile error, which this plan does not accept as RED.** Proceed to step 3, then after green, verify each containment test individually by mutation (step 5).

- [ ] **Step 3: Lift `coarser` out of `private`**

In `Raconte/Library/JournalDateRange.swift`, move the existing `private static func coarser` (line ~70) onto `DatePrecision` as a non-private static, and update `JournalDateRange.formatted` to call it:

```swift
extension DatePrecision {
    /// The coarser of two precisions. Lifted out of `JournalDateRange`'s private scope
    /// so `JournalSpan` can share it rather than carry a second rank table that would
    /// drift (standing branch rule: call the shared primitive, never copy it).
    static func coarser(_ a: DatePrecision, _ b: DatePrecision) -> DatePrecision {
        func rank(_ p: DatePrecision) -> Int {
            switch p {
            case .day: return 0
            case .yearMonth: return 1
            case .year: return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}
```

- [ ] **Step 4: Write `JournalSpan`**

Create `Raconte/Library/JournalSpan.swift`:

```swift
import Foundation

enum JournalSpanError: Error, Equatable {
    /// End is before start, judged at each endpoint's own unit (see `JournalSpan`).
    case inverted
}

/// The span the PAPER journal covers, as its owner knows it — independent of how much of
/// it has been read in so far (spec ruling 2). A half-transcribed 1998 journal must not
/// advertise itself as an Aug 2026 journal, which is what the DERIVED `JournalDateRange`
/// would say.
///
/// **Endpoints are units, not instants.** `PartialDate` is `Comparable` by `anchorDate`,
/// which fills absent components with the first — "2001" anchors to 1 Jan 2001. Comparing
/// against that raw anchor would put every entry after 1 Jan 2001 outside a "1998 – 2001"
/// journal. So `start` expands to the EARLIEST instant of its precision's unit and `end`
/// to the LATEST.
struct JournalSpan: Sendable, Equatable, Hashable {
    let start: PartialDate
    /// Nil means open-ended: a journal still being written.
    let end: PartialDate?

    init(start: PartialDate, end: PartialDate?) throws {
        if let end, Self.lowerBound(start, calendar: .gregorianCurrent)
                    > Self.upperBound(end, calendar: .gregorianCurrent) {
            throw JournalSpanError.inverted
        }
        self.start = start
        self.end = end
    }

    func contains(_ date: Date, calendar: Calendar = .gregorianCurrent) -> Bool {
        if date < Self.lowerBound(start, calendar: calendar) { return false }
        guard let end else { return true }
        return date <= Self.upperBound(end, calendar: calendar)
    }

    func formatted(calendar: Calendar = .gregorianCurrent) -> String {
        let startText = start.formatted(calendar: calendar)
        guard let end else { return "\(startText) –" }
        let endText = end.formatted(calendar: calendar)
        return startText == endText ? startText : "\(startText) – \(endText)"
    }

    // MARK: Unit expansion

    /// The first instant of the unit this partial date names.
    static func lowerBound(_ value: PartialDate, calendar: Calendar) -> Date {
        calendar.startOfDay(for: value.anchorDate(calendar: calendar))
    }

    /// The last instant of the unit this partial date names: end of that day, month or
    /// year. `calendar.range(of:in:for:)` gives the unit's real length, so February 2024
    /// correctly ends on the 29th.
    static func upperBound(_ value: PartialDate, calendar: Calendar) -> Date {
        let anchor = calendar.startOfDay(for: value.anchorDate(calendar: calendar))
        let unit: Calendar.Component
        switch value.precision {
        case .day: unit = .day
        case .yearMonth: unit = .month
        case .year: unit = .year
        }
        guard let interval = calendar.dateInterval(of: unit, for: anchor) else { return anchor }
        return interval.end - 1
    }
}

extension JournalSpan: Codable {
    private enum CodingKeys: String, CodingKey { case start, end }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Not `self.init(start:end:)`-bypassed: the invariant must hold for values that
        // arrive off disk, not only ones minted in the editor.
        try self.init(start: try container.decode(PartialDate.self, forKey: .start),
                      end: try container.decodeIfPresent(PartialDate.self, forKey: .end))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        // Only when present, so an open-ended span does not carry a null.
        try container.encodeIfPresent(end, forKey: .end)
    }
}
```

- [ ] **Step 5: Run the tests and mutation-verify containment**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalSpanTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: 12 tests PASS.

Then prove the tests are not vacuous. Temporarily replace `upperBound`'s body with `return calendar.startOfDay(for: value.anchorDate(calendar: calendar))` (i.e. the naive anchor). Re-run: `testYearPrecisionEndBoundCoversTheWholeYear`, `testMonthPrecisionEndBoundCoversTheWholeMonth` and `testLeapDayIsInsideAFebruaryMonthBound` MUST fail. Revert the mutation. If any of them still passes, its fixture is degenerate — fix the test, not the mutation.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/JournalSpan.swift Raconte/Library/JournalDateRange.swift \
        RaconteTests/JournalSpanTests.swift
git commit -m "feat: JournalSpan, the stored date range a paper journal covers

Endpoints are units, not instants: an end bound of \"2001\" means 31 Dec 2001.
PartialDate compares by anchorDate, which fills absent components with the
first, so the naive comparison put everything after 1 Jan 2001 out of range.
Mutation-verified. Lifts JournalDateRange.coarser out of private rather than
carrying a second rank table."
```

---

### Task 3: `Journal.span` on disk

**Files:**
- Modify: `Raconte/Library/Journal.swift`, `Raconte/Library/JournalStore.swift`
- Test: `RaconteTests/JournalStoreTests.swift`

**Interfaces:**
- Consumes: `JournalSpan` from Task 2.
- Produces:
  - `Journal.span: JournalSpan?`
  - `JournalRegistry.setSpan(id:span:) throws -> Journal`
  - `JournalStore.setSpan(id:span:) throws -> Journal`
  - `JournalError.invalidSpan`

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/JournalStoreTests.swift`:

```swift
// MARK: - span (spec ruling 2)

func testSpanIsAdditiveAndLenient() throws {
    // Every registry on disk predates this field. Absent -> nil, garbage -> nil, and
    // neither may take the journal's identity down with it.
    let absent = Data(#"{"id":"J1","name":"N","createdAt":"1998-03-04T00:00:00Z"}"#.utf8)
    XCTAssertNil(try JSONDecoder.raconte().decode(Journal.self, from: absent).span)

    let garbage = Data(#"{"id":"J1","name":"N","createdAt":"1998-03-04T00:00:00Z","span":7}"#.utf8)
    let decoded = try JSONDecoder.raconte().decode(Journal.self, from: garbage)
    XCTAssertNil(decoded.span)
    XCTAssertEqual(decoded.name, "N", "a damaged span must cost only the span")
}

func testAJournalWithoutASpanEncodesByteIdentically() throws {
    // The bytes of every registry already on disk must not change.
    let journal = Journal(id: "J1", name: "N",
                          createdAt: Date(timeIntervalSince1970: 0))
    let data = try JournalStore.encode(JournalRegistry(journals: [journal]))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("span"))
}

func testSetSpanPersistsAndReloads() async throws {
    let s = store(ids: ["J1"])
    let created = try await s.create(name: "1998 Journal")
    let span = try JournalSpan(start: PartialDate(year: 1998),
                               end: PartialDate(year: 2001))
    _ = try await s.setSpan(id: created.id, span: span)
    XCTAssertEqual(try await s.journal(id: created.id)?.span, span)
}

func testSetSpanOnAnUnknownJournalThrowsAndLeavesTheFileAlone() async throws {
    let s = store(ids: ["J1"])
    _ = try await s.create(name: "Keep me")
    let before = try Data(contentsOf: registryURL)
    let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
    do {
        _ = try await s.setSpan(id: "missing", span: span)
        XCTFail("expected unknownJournal")
    } catch {
        XCTAssertEqual(error as? JournalError, .unknownJournal("missing"))
    }
    XCTAssertEqual(try Data(contentsOf: registryURL), before)
}

func testClearingASpanRemovesTheKey() async throws {
    let s = store(ids: ["J1"])
    let created = try await s.create(name: "N")
    _ = try await s.setSpan(id: created.id,
                            span: try JournalSpan(start: PartialDate(year: 1998), end: nil))
    _ = try await s.setSpan(id: created.id, span: nil)
    XCTAssertNil(try await s.journal(id: created.id)?.span)
    XCTAssertFalse(String(decoding: try Data(contentsOf: registryURL), as: UTF8.self)
                    .contains("span"))
}

/// A tripwire, not a style check. `Journal.encode(to:)` enumerates fields by hand, so a
/// field added to `Journal` is dropped on every write by default and no existing test
/// notices. If this fails: carry the new field over in `encode(to:)` AND `init(from:)`,
/// assert it round-trips above, then bump the count.
///
/// The SYNC half of this enforcement lives on `m4/sync` (spec, "Branch split") — that
/// branch enumerates journal fields in six more places this branch cannot see.
func testJournalFieldCountIsPinnedSoNewFieldsGetEncoded() {
    let journal = Journal(id: "J1", name: "N", createdAt: Date())
    XCTAssertEqual(Mirror(reflecting: journal).children.count, 5,
                   "Journal gained or lost a field — see Journal.encode(to:)")
}
```

If `JSONDecoder.raconte()` does not exist in this suite, use whatever decoder the existing tests in this file use (check `testDecoderIsStrictAboutIdentityFields`, `JournalStoreTests.swift:155`) and match it exactly.

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalStoreTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: FAIL (no `span` member, no `setSpan`).

- [ ] **Step 3: Add `span` to `Journal`**

In `Raconte/Library/Journal.swift`:

```swift
    /// The span the PAPER journal covers (spec ruling 2). Additive and lenient, exactly
    /// like `voiceLabels` above: every registry on disk predates this field, and a damaged
    /// value must cost only the span, never the journal's id/name/createdAt.
    var span: JournalSpan?
```

Add to `init`: `span: JournalSpan? = nil` (last parameter, defaulted, so no existing call site changes).

Add to `init(from:)`, after `voiceLabels`:

```swift
        span = (try? container.decodeIfPresent(JournalSpan.self, forKey: .span)) ?? nil
```

Add to `encode(to:)`, after the `voiceLabels` block:

```swift
        // Only when set, same "an untouched record's bytes don't change" rule the two
        // fields above follow.
        if let span {
            try container.encode(span, forKey: .span)
        }
```

Add `span` to `CodingKeys`.

Add to `JournalError`: `case invalidSpan`.

Add to `JournalRegistry`, following `setVoiceLabels`'s exact shape:

```swift
    @discardableResult
    mutating func setSpan(id: String, span: JournalSpan?) throws -> Journal {
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        journals[index].span = span
        return journals[index]
    }
```

- [ ] **Step 4: Add `JournalStore.setSpan`**

In `Raconte/Library/JournalStore.swift`, following `setVoiceLabels`'s exact shape:

```swift
    @discardableResult
    func setSpan(id: String, span: JournalSpan?) throws -> Journal {
        var registry = try load()
        let updated = try registry.setSpan(id: id, span: span)
        try save(registry)
        return updated
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalStoreTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: PASS.

- [ ] **Step 6: Run the full suite and commit**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
git add Raconte/Library/Journal.swift Raconte/Library/JournalStore.swift \
        RaconteTests/JournalStoreTests.swift
git commit -m "feat: persist a journal's span in journals.json

Additive and lenient like voiceLabels; encoded only when set, so every registry
already on disk keeps byte-identical output. Adds a Mirror field-count tripwire
so the next field added to Journal cannot be silently dropped by the
hand-written encoder — the sync half of that enforcement lands on m4/sync."
```

---

### Task 4: Display precedence — span outranks derived

**Files:**
- Modify: `Raconte/Library/LibraryScreenModel.swift`, `Raconte/App/SidebarView.swift:82-97`
- Test: `RaconteTests/JournalDateLineTests.swift` (create)

**Interfaces:**
- Consumes: `Journal.span` (Task 3), `JournalDateRange` (existing).
- Produces: `JournalDateLine.text(span:derived:calendar:) -> String?` and `LibraryScreenModel.dateLine(forJournal:) -> String?`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Raconte

/// Spec ruling 3: stored wins when set; derived is the fallback. Never a union — a union
/// silently invents a span nobody typed and hides the disagreement.
final class JournalDateLineTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    func testStoredSpanWinsOverTheDerivedRange() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998),
                                   end: PartialDate(year: 2001))
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: derived, calendar: cal),
                       span.formatted(calendar: cal),
                       "a half-read 1998 journal must not advertise itself as Aug 2026")
    }

    func testDerivedRangeIsUsedWhenNoSpanIsSet() {
        let derived = JournalDateRange(minDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                       minPrecision: .day,
                                       maxDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 18))!,
                                       maxPrecision: .day)
        XCTAssertEqual(JournalDateLine.text(span: nil, derived: derived, calendar: cal),
                       derived.formatted(calendar: cal))
    }

    func testSpanWinsEvenWhenThereAreNoEntriesAtAll() throws {
        let span = try JournalSpan(start: PartialDate(year: 1998), end: nil)
        XCTAssertEqual(JournalDateLine.text(span: span, derived: nil, calendar: cal),
                       span.formatted(calendar: cal),
                       "an untranscribed journal still knows what it covers")
    }

    func testNothingToSayReturnsNil() {
        XCTAssertNil(JournalDateLine.text(span: nil, derived: nil, calendar: cal))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalDateLineTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: FAIL — `JournalDateLine` not in scope.

- [ ] **Step 3: Implement**

Add to `Raconte/Library/JournalSpan.swift`:

```swift
/// Which date line a journal shows (spec ruling 3): the stored span if it has one, else
/// what its entries imply, else nothing. One rule, one place, so the sidebar row, the
/// journal header and the editor cannot disagree.
enum JournalDateLine {
    static func text(span: JournalSpan?,
                     derived: JournalDateRange?,
                     calendar: Calendar = .gregorianCurrent) -> String? {
        if let span { return span.formatted(calendar: calendar) }
        return derived?.formatted(calendar: calendar)
    }
}
```

Add to `LibraryScreenModel`, beside `dateRange(forJournal:)`:

```swift
    /// The one date line for a journal, span-first. `SidebarView` and the journal header
    /// both read this rather than deciding for themselves.
    func dateLine(forJournal journalID: String) -> String? {
        JournalDateLine.text(span: journals.first { $0.id == journalID }?.span,
                             derived: dateRange(forJournal: journalID))
    }
```

In `Raconte/App/SidebarView.swift`, in `private var rows` (~:82-97), replace the `dateRange(forJournal:)` call that builds the `ranges` dictionary with `dateLine(forJournal:)`.

- [ ] **Step 4: Run to verify it passes, then run the full suite**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: 4 new tests PASS, suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/JournalSpan.swift Raconte/Library/LibraryScreenModel.swift \
        Raconte/App/SidebarView.swift RaconteTests/JournalDateLineTests.swift
git commit -m "feat: a journal's stored span outranks its derived range for display

One rule in one place, so the sidebar row, the journal header and the editor
cannot disagree about what a journal covers."
```

---

### Task 5: Thread journal identity into `LibraryView` and add the header

`LibraryView` is dual-purpose (All Entries + any single journal) and today receives only a `title: String`. The header needs the journal itself.

**Files:**
- Create: `Raconte/Library/UI/JournalHeaderCard.swift`
- Modify: `Raconte/App/ContentView.swift:97-98` and `:114-123`, `Raconte/Library/UI/LibraryView.swift:16-45`
- Test: `RaconteUITests/JournalEditorUITests.swift` (create)

**Interfaces:**
- Consumes: `LibraryScreenModel.dateLine(forJournal:)` (Task 4), `JournalCoverThumbnail` (existing).
- Produces:
  - `LibraryView(model:title:journal:)` — `journal: Journal?`, nil for All Entries, plus a stored `var onEditJournal: (String) -> Void = { _ in }` that Task 6 replaces.
  - `JournalHeaderCard(name: String, cover: Data?, dateLine: String?, entryCount: Int, onEdit: () -> Void)`

- [ ] **Step 1: Write the failing UI test**

```swift
import XCTest

final class JournalEditorUITests: XCTestCase {
    private var testID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launch()
        return app
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// A journal place shows the journal itself above its entries — All Entries does not.
    func testSelectingAJournalShowsItsHeader() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        openPlace(app, "sidebar.allEntries")
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "journal.header").firstMatch.exists,
                       "All Entries is not a journal and must show no journal header")

        let journalRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.journal.'"))
            .firstMatch
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(identifier: "journal.header").firstMatch
                        .waitForExistence(timeout: 15),
                      "selecting a journal did not show its header")
    }
}
```

- [ ] **Step 2: Verify RED against stashed-out production code**

Because SwiftUI view wiring is unit-untestable by this repo's convention, RED is verified by stash:

```bash
xcodegen generate
git stash push -- Raconte/App/ContentView.swift Raconte/Library/UI/LibraryView.swift
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:RaconteUITests/JournalEditorUITests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
git stash pop
```

Expected: FAIL on "selecting a journal did not show its header". If it fails on the earlier `capture.record` wait instead, the app did not launch — fix that before reading anything into the result.

- [ ] **Step 3: Write `JournalHeaderCard`**

Create `Raconte/Library/UI/JournalHeaderCard.swift`:

```swift
import SwiftUI

/// The journal itself, above its entries (spec ruling 5). Before this, selecting a journal
/// showed only a list with the journal's name as a navigation title — the journal had no
/// presence on its own screen, and its cover had nowhere to be seen at a size that lets
/// you recognise the photograph.
///
/// The whole card is the edit affordance. Cover, name and date line are one button, not a
/// row with an Edit button beside it.
struct JournalHeaderCard: View {
    let name: String
    let cover: Data?
    let dateLine: String?
    let entryCount: Int
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 14) {
                // A Button label, NOT a Menu label. #69: a macOS Menu label discards a
                // resizable Image's frame; a Button label honours it (harness variant D).
                JournalCoverThumbnail(data: cover, size: 72)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                    if let dateLine {
                        Text(dateLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(entryCount == 1 ? "1 entry" : "\(entryCount) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dateLine.map { "\(name), \($0)" } ?? name)
        .accessibilityHint("Edit this journal")
        .accessibilityIdentifier("journal.header")
    }
}
```

- [ ] **Step 4: Thread the journal through**

In `Raconte/App/ContentView.swift`, replace the `.allEntries, .journal` case in `detailRoot` (:97-98) with two cases:

```swift
case .allEntries:
    LibraryView(model: services.library, title: "All Entries", journal: nil)
case .journal(let id):
    LibraryView(model: services.library,
                title: libraryTitle,
                journal: services.library.journals.first { $0.id == id })
```

In `Raconte/Library/UI/LibraryView.swift`, add `let journal: Journal?` to the struct and mount the header above the list:

```swift
    @ViewBuilder
    private var journalHeader: some View {
        if let journal {
            JournalHeaderCard(name: journal.name,
                              cover: model.journalCovers[journal.id],
                              dateLine: model.dateLine(forJournal: journal.id),
                              entryCount: model.items.count,
                              onEdit: { onEditJournal(journal.id) })
        }
    }
```

Place `journalHeader` as the first element inside the existing `List`, in its own `Section` with no header, so it scrolls with the entries rather than pinning above them.

`onEditJournal` is supplied in Task 6; for THIS task make it a stored `var onEditJournal: (String) -> Void = { _ in }` so the header renders and the test passes without navigation existing yet.

- [ ] **Step 5: Run the UI test to verify it passes**

```bash
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:RaconteUITests/JournalEditorUITests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: PASS. If the simulator misbehaves after an interrupted run: `xcrun simctl shutdown all`, then boot explicitly and wait on `bootstatus` before relaunching — an immediate launch fails preflight.

- [ ] **Step 6: Run both suites and commit**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
git add Raconte/Library/UI/JournalHeaderCard.swift Raconte/App/ContentView.swift \
        Raconte/Library/UI/LibraryView.swift RaconteUITests/JournalEditorUITests.swift
git commit -m "feat: a journal's own header above its entries

LibraryView is dual-purpose and previously carried no journal identity at all —
only a title string. It now takes the Journal, and a journal place shows cover,
name, date line and entry count above the list. The whole card is the edit
affordance (spec ruling 5). All Entries shows no header."
```

---

### Task 6: The editor screen — name and voice labels

**Files:**
- Create: `Raconte/Library/UI/JournalEditorView.swift`
- Modify: `Raconte/Library/UI/LibraryView.swift:9` (`LibraryDestination`), `Raconte/App/ContentView.swift:29-48`
- Test: `RaconteUITests/JournalEditorUITests.swift`

**Interfaces:**
- Consumes: `JournalHeaderCard.onEdit` (Task 5), `JournalStore.rename`/`setVoiceLabels` via `LibraryScreenModel`.
- Produces: `LibraryDestination.journalEditor(String)`, `JournalEditorView(model:journalID:)`.

**A constraint this task must respect:** `PlaceRouting.detailPath(afterSelecting:from:path:)` **always returns `[]`**, so any sidebar click or ⌘1-4 pops an open editor with no warning. The editor therefore **writes through on commit of each field** — it must not hold a Done-button-shaped batch of unsaved edits. Same discipline `BackdateField` already uses.

- [ ] **Step 1: Write the failing UI test**

Append to `RaconteUITests/JournalEditorUITests.swift`:

```swift
    func testTappingTheHeaderOpensTheEditorAndRenameSticks() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))

        let journalRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.journal.'"))
            .firstMatch
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15),
                      "tapping the journal header did not open the editor")

        press(nameField)
        nameField.typeText(" Renamed")
        // Commit by moving focus, not by a Done button — the editor writes through.
        app.descendants(matching: .any).matching(identifier: "journalEditor.title")
            .firstMatch.tap()

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Renamed'")).firstMatch
            .waitForExistence(timeout: 15),
                      "the rename did not reach the registry")
    }
```

- [ ] **Step 2: Verify RED**

```bash
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:RaconteUITests/JournalEditorUITests/testTappingTheHeaderOpensTheEditorAndRenameSticks \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Expected: FAIL on "tapping the journal header did not open the editor".

- [ ] **Step 3: Add the destination case**

In `Raconte/Library/UI/LibraryView.swift`:

```swift
enum LibraryDestination: Hashable {
    case entry(String)
    /// The journal editor, pushed from `JournalHeaderCard`. Journal id.
    case journalEditor(String)
}
```

In `ContentView.swift`'s `.navigationDestination(for: LibraryDestination.self)`, add:

```swift
case .journalEditor(let journalID):
    JournalEditorView(model: services.library, journalID: journalID)
```

And wire `LibraryView`'s `onEditJournal` to `router.detailPath.append(.journalEditor(id))`.

- [ ] **Step 4: Write the editor**

First add to `LibraryScreenModel`, following `moveEntry`'s Bool-returning convention (the caller alerts on `false`):

```swift
    @discardableResult
    func renameJournal(_ journalID: String, to name: String) async -> Bool {
        guard (try? await journalStore.rename(id: journalID, to: name)) != nil else {
            return false
        }
        await rescan()
        return true
    }
```

Then create `Raconte/Library/UI/JournalEditorView.swift`:

```swift
import SwiftUI

/// Everything about a journal that is not its entries (spec, Surfaces item 3). Pushed,
/// not presented: it holds enough to make a sheet cramped, and this project has had
/// repeated trouble with sheets on macOS — #68's empty picker, the Debug modal trap, and
/// the backdate sheet that had to become a popover before Escape worked.
///
/// **Writes through on commit, never behind a Done button.**
/// `PlaceRouting.detailPath(afterSelecting:from:path:)` always returns `[]`, so any
/// sidebar click or Cmd-1..4 pops this screen with no warning. A batch of unsaved edits
/// would be silently lost. Same discipline `BackdateField` already uses.
struct JournalEditorView: View {
    let model: LibraryScreenModel
    let journalID: String

    @State private var draftName = ""
    @State private var renameFailed = false
    @FocusState private var nameFocused: Bool

    private var journal: Journal? { model.journals.first { $0.id == journalID } }
    private var entryCount: Int {
        model.allEntries.filter { $0.journalID == journalID }.count
    }

    var body: some View {
        if let journal {
            Form {
                Section("Name") {
                    TextField("Journal name", text: $draftName)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .accessibilityIdentifier("journalEditor.name")
                }

                // Task 7 inserts the span section here.
                // Task 8 inserts the cover section here.

                Section {
                    // The one place the stored span and what is ACTUALLY in the journal
                    // are visible together (spec, Display rules). Read-only on purpose:
                    // the derived range is a fact about the entries, not a setting.
                    Text(derivedSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("journalEditor.derived")
                }
            }
            .navigationTitle(journal.name)
            .accessibilityIdentifier("journalEditor.title")
            .onAppear { draftName = journal.name }
            // Focus loss is a commit, not a discard — see the type comment above.
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }
            .alert("Couldn’t rename this journal", isPresented: $renameFailed) {
                Button("OK", role: .cancel) {}
            }
        } else {
            // Deleted underneath us. Never a blank push — same treatment ContentView
            // gives a missing entry.
            ContentUnavailableView("Journal unavailable",
                                   systemImage: "books.vertical",
                                   description: Text("This journal is no longer in your library."))
                .accessibilityIdentifier("journalEditor.unavailable")
        }
    }

    private var derivedSummary: String {
        let count = entryCount == 1 ? "1 entry" : "\(entryCount) entries"
        guard let derived = model.dateRange(forJournal: journalID) else {
            return "\(count) recorded so far."
        }
        return "\(count) recorded so far, covering \(derived.formatted())."
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let journal, trimmed != journal.name else { return }
        Task {
            if await model.renameJournal(journalID, to: trimmed) == false {
                renameFailed = true
                draftName = journal.name
            }
        }
    }
}
```

Voice labels: extract `JournalVoiceLabelsSheet`'s body into a `JournalVoiceLabelsSection` view and mount that here, rather than copying its content — standing rule, call the shared primitive. The sheet keeps working for any remaining caller by wrapping the same section.

- [ ] **Step 5: Run to verify it passes, then both suites**

```bash
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/UI/JournalEditorView.swift Raconte/Library/UI/LibraryView.swift \
        Raconte/App/ContentView.swift Raconte/Library/LibraryScreenModel.swift \
        RaconteUITests/JournalEditorUITests.swift
git commit -m "feat: journal editor screen with name and voice labels

Pushed, not presented — this project has repeated trouble with sheets on macOS.
Writes through on field commit rather than batching behind a Done button,
because PlaceRouting always clears detailPath, so any sidebar click or Cmd-1
pops the editor without warning."
```

---

### Task 7: The span editor

**Files:**
- Create: `Raconte/Library/UI/JournalSpanEditor.swift`
- Modify: `Raconte/Library/UI/JournalEditorView.swift`, `Raconte/Library/LibraryScreenModel.swift`
- Test: `RaconteTests/JournalSpanEditorTests.swift` (create)

**Interfaces:**
- Consumes: `JournalSpan` (Task 2), `PrecisionDatePicker` (existing).
- Produces:
  - `JournalSpanEditorModel.span(startDate:startPrecision:endDate:endPrecision:isOpenEnded:calendar:) throws -> JournalSpan?`
  - `JournalSpanEditor(initial: JournalSpan?, onChange: (JournalSpan?) -> Void)`
  - `LibraryScreenModel.setJournalSpan(_ journalID: String, span: JournalSpan?) async -> Bool`

`PrecisionDatePicker` binds `Date` + `DatePrecision` separately, **not** a `PartialDate`. The editor wraps and unwraps via `PartialDate(from:precision:calendar:)`.

- [ ] **Step 1: Write the failing tests for the pure conversion layer**

```swift
import XCTest
@testable import Raconte

/// The span editor's pure half. `PrecisionDatePicker` speaks (Date, DatePrecision); the
/// registry speaks PartialDate. Getting that conversion wrong is invisible on screen and
/// wrong on disk, so it is pinned here rather than left inside the view.
final class JournalSpanEditorTests: XCTestCase {
    private let cal = Calendar.gregorianCurrent

    func testBuildingASpanFromPickerValuesRoundTrips() throws {
        let start = cal.date(from: DateComponents(year: 1998, month: 3, day: 4))!
        let end = cal.date(from: DateComponents(year: 2001, month: 7, day: 9))!
        let span = try JournalSpanEditorModel.span(startDate: start, startPrecision: .yearMonth,
                                                   endDate: end, endPrecision: .year,
                                                   isOpenEnded: false, calendar: cal)
        XCTAssertEqual(span?.start, PartialDate(year: 1998, month: 3))
        XCTAssertEqual(span?.end, PartialDate(year: 2001))
    }

    func testOpenEndedDropsTheEndEntirely() throws {
        let start = cal.date(from: DateComponents(year: 1998, month: 3, day: 4))!
        let span = try JournalSpanEditorModel.span(startDate: start, startPrecision: .year,
                                                   endDate: Date(), endPrecision: .year,
                                                   isOpenEnded: true, calendar: cal)
        XCTAssertEqual(span?.start, PartialDate(year: 1998))
        XCTAssertNil(span?.end)
    }

    func testAnInvertedPairSurfacesAsAnErrorNotACrash() {
        let start = cal.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: 1998, month: 1, day: 1))!
        XCTAssertThrowsError(try JournalSpanEditorModel.span(
            startDate: start, startPrecision: .year,
            endDate: end, endPrecision: .year,
            isOpenEnded: false, calendar: cal))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -only-testing:RaconteTests/JournalSpanEditorTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

- [ ] **Step 3: Implement `JournalSpanEditorModel` and the view**

The pure half, whose signature Task 7's tests already pin exactly:

```swift
/// `PrecisionDatePicker` speaks (`Date`, `DatePrecision`); the registry speaks
/// `PartialDate`. This is that conversion, kept out of the view so it can be tested —
/// getting it wrong looks right on screen and is wrong on disk.
enum JournalSpanEditorModel {
    static func span(startDate: Date, startPrecision: DatePrecision,
                     endDate: Date, endPrecision: DatePrecision,
                     isOpenEnded: Bool,
                     calendar: Calendar = .gregorianCurrent) throws -> JournalSpan? {
        let start = PartialDate(from: startDate, precision: startPrecision, calendar: calendar)
        guard !isOpenEnded else { return try JournalSpan(start: start, end: nil) }
        let end = PartialDate(from: endDate, precision: endPrecision, calendar: calendar)
        return try JournalSpan(start: start, end: end)
    }
}
```

`JournalSpanEditor` is a `View` with: a "This journal covers" toggle (off = no span, which clears it), two `PrecisionDatePicker`s labelled Start and End with `idPrefix: "journalSpanStart"` / `"journalSpanEnd"`, an "Still being written" toggle that disables the End picker, and an inline error line when the pair is inverted. **Inverted input is refused with a visible message, never silently swapped** — swapping would file entries under a range the owner did not choose.

Mount it in `JournalEditorView` above the voice labels section.

Add `LibraryScreenModel.setJournalSpan(_ journalID: String, span: JournalSpan?) async -> Bool`, calling `journalStore.setSpan` then `rescan()`, returning `false` on throw.

- [ ] **Step 4: Run to verify it passes, then both suites, then commit**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
git add Raconte/Library/UI/JournalSpanEditor.swift Raconte/Library/UI/JournalEditorView.swift \
        Raconte/Library/LibraryScreenModel.swift RaconteTests/JournalSpanEditorTests.swift
git commit -m "feat: edit a journal's span in the editor

Refuses an inverted pair with a visible message rather than swapping the
endpoints silently — a swap would file entries under a range nobody chose."
```

---

### Task 8: Cover in the editor

**Files:**
- Modify: `Raconte/Library/UI/JournalEditorView.swift`, `Raconte/Library/UI/JournalCoverPickerSheet.swift`

**Interfaces:**
- Consumes: `LibraryScreenModel.setJournalCover(_:imageData:)` and `removeJournalCover(_:)` (both exist).

**Known limitation, accepted by the owner (spec ruling 9):** `JournalCoverPickerSheet` renders empty on macOS — title + Cancel, no `PhotosPicker` row (#68). Once Task 1 removed the capture-screen route, this editor is the only cover path, so **macOS cannot set a cover until #68 is fixed.** Do not attempt to fix #68 in this task; it has its own issue. Do add the note below to the editor so the next reader is not confused.

- [ ] **Step 1: Mount the cover row**

In `JournalEditorView`, add a section above the span editor:

```swift
Section("Cover") {
    if let cover = model.journalCovers[journalID] {
        JournalCoverPreview(data: cover)
        Button("Replace…") { showingCoverPicker = true }
        Button("Remove", role: .destructive) {
            Task { await model.removeJournalCover(journalID) }
        }
    } else {
        Button("Add a cover photo…") { showingCoverPicker = true }
    }
}
// #68: this sheet renders EMPTY on macOS — the PhotosPicker row is absent, so the
// Mac currently has no way to set a cover at all now that the capture-screen route
// is gone. Accepted by the owner (spec ruling 9) and tracked separately; do not
// paper over it here.
.sheet(isPresented: $showingCoverPicker) {
    // Reset the inherited foreground — the sheet draws on system material.
    JournalCoverPickerSheet(
        currentCover: model.journalCovers[journalID],
        onPick: { data in
            Task { try? await model.setJournalCover(journalID, imageData: data) }
        })
        .foregroundStyle(Color.primary)
}
```

Read `JournalCoverPickerSheet`'s actual init before writing this — match its real parameter names exactly rather than the shape above, which is written from its call site on the capture screen as it stood at Task 1.

- [ ] **Step 2: Run both suites**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

- [ ] **Step 3: Commit**

```bash
git add Raconte/Library/UI/JournalEditorView.swift
git commit -m "feat: set, replace and remove a journal's cover from the editor

Note: #68 means this sheet is empty on macOS, so the Mac has no cover path until
that is fixed. Accepted trade for getting editing off the capture screen."
```

---

### Task 9: Sidebar `+` creates a journal and opens its editor

**Files:**
- Modify: `Raconte/App/SidebarView.swift:52`

**Interfaces:**
- Consumes: `CaptureScreenModel.createJournal(name:)` (existing, already the single creation path for both the capture menu and ⌘N), `LibraryDestination.journalEditor` (Task 6).

- [ ] **Step 1: Add the toolbar button**

`SidebarView` has no toolbar today — only `.navigationTitle("Raconte")`. Add:

```swift
.toolbar {
    ToolbarItem {
        Button {
            services.router.requestNewJournal()
        } label: {
            Label("New Journal", systemImage: "plus")
        }
        .accessibilityIdentifier("sidebar.newJournal")
    }
}
```

This is a **third caller** of the same path — `requestNewJournal()` raises the root alert, whose Create button already calls `services.capture.createJournal(name:)`. Do NOT add a second creation method.

- [ ] **Step 2: Push the editor after creation**

In `ContentView`'s New Journal alert Create button, after `createJournal` returns a non-nil `Journal`, select that journal's place and push its editor:

```swift
Button("Create") {
    let name = newJournalName
    Task {
        guard let created = await services.capture.createJournal(name: name) else { return }
        services.router.select(.journal(created.id))
        services.router.detailPath.append(.journalEditor(created.id))
    }
}
```

Order matters: `router.select` clears `detailPath` (`PlaceRouting.detailPath` always returns `[]`), so the append MUST come after the select or the editor never appears.

- [ ] **Step 3: Write a UI test, verify RED by stash, then green**

Append to `JournalEditorUITests`:

```swift
    func testSidebarPlusCreatesAJournalAndOpensItsEditor() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))

        // Reveal the sidebar on compact width before reaching for its toolbar.
        openPlace(app, "sidebar.allEntries")
        let plus = app.buttons["sidebar.newJournal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15),
                      "the sidebar has no New Journal button")
        press(plus)

        let field = app.textFields["root.newJournalNameField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.typeText("Blue rabbit 2027")
        app.buttons["Create"].firstMatch.tap()

        XCTAssertTrue(app.textFields["journalEditor.name"].firstMatch
                        .waitForExistence(timeout: 15),
                      "creating from the sidebar did not open the new journal's editor")
    }
```

Verify RED:

```bash
xcodegen generate
git stash push -- Raconte/App/SidebarView.swift Raconte/App/ContentView.swift
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:RaconteUITests/JournalEditorUITests/testSidebarPlusCreatesAJournalAndOpensItsEditor \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
git stash pop
```

Expected: FAIL on "the sidebar has no New Journal button". Then re-run after popping and confirm PASS.

- [ ] **Step 4: Run both suites and commit**

```bash
git add Raconte/App/SidebarView.swift Raconte/App/ContentView.swift \
        RaconteUITests/JournalEditorUITests.swift
git commit -m "feat: sidebar + creates a journal and opens its editor

Third caller of the one existing creation path, not a second method. The
detailPath append must follow router.select, which always clears the path."
```

---

### Task 10: Documentation

**Files:**
- Modify: `docs/plans/2026-08-18-journal-editing-ia-design.md` (as-built section), `docs/overview.md`, `CLAUDE.md`

- [ ] **Step 1: Record as-built deltas in the design doc.** Anything that differed from the spec, and why.
- [ ] **Step 2: Update `docs/overview.md`'s journals section** to describe spans and the editor in plain words.
- [ ] **Step 3: Add to `CLAUDE.md`'s conventions:** the macOS `Menu`-label trap ("never put an `Image` in a `Menu` label — it renders at intrinsic size and swallows the control; a `Button` label is fine"), and the `PartialDate`-endpoints-are-units rule.
- [ ] **Step 4: Commit.**

---

### Gate: adversarial whole-branch review

Dispatch an independent reviewer (Opus) that has NOT implemented any task.

- [ ] Re-run both suites **independently** on the committed tree and report verbatim counts. Do not trust the implementers' reported numbers — two implementer rounds on a previous branch both claimed green suites that had never been run.
- [ ] Verify #69 is dead by the source scan AND by reading `JournalHeaderView` directly.
- [ ] **Probe 1:** set a span, then check the sidebar row, journal header and editor all show the same string. Three call sites, one rule — prove they agree.
- [ ] **Probe 2:** a journal whose span is open-ended. Does the date line read sensibly? Does `contains` admit today?
- [ ] **Probe 3:** open the editor, then press ⌘2. The editor pops. Confirm the in-flight name edit was already written, not lost.
- [ ] **Probe 4:** delete a journal's registry entry underneath an open editor. Confirm `ContentUnavailableView`, not a blank push or a crash.
- [ ] **Probe 5:** mutation-check `JournalSpan.upperBound` per Task 2 step 5 and confirm the three containment tests fail.
- [ ] Confirm no `modified` key was added anywhere (this branch must stay sync-free).
- [ ] Triage any deferred minors into the ledger and file issues at branch finish.

---

## Deferred to a follow-up (NOT this plan)

- **#71 — flag entries dated outside their journal's span** (spec ruling 4). Cut from this
  branch by the owner on 2026-08-18 to keep it shorter. Everything it needs — `JournalSpan`,
  `Journal.span`, `contains(_:)` — ships here; #71 is purely the surfacing, on
  `LibraryEntryRow` and `EntryDetailView`. Note for the gate: the spec still describes this
  behaviour, so its absence is deliberate, not a coverage gap.

## Deferred to `m4/sync` (NOT this plan)

Recorded here so it cannot be forgotten. Spec §"Branch split":

- A `Mirror`-based field-count tripwire over `Journal`'s **sync** round-trip, written red-first, so picking up `span` at the `m4/sync` ← `main` merge fails the suite until `span` is wired through `SyncJournalField`, `SyncRecordBuilders.journalRecord`, `RemoteJournal`, `RemoteJournal.init?(record:)`, `JournalMerge.adopted(remote:)` and `JournalMerge.merge`, plus its `modified["span"]` key.
- The `ContentView.onChange(of: journals)` guard — re-select now pops the detail column, so a background CKSyncEngine journals pull would pop the reader out of an entry. See #67.
- #70, unknown-key preservation.
