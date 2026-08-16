> **Archived — shipped (PR #45).** #39/#40/#41 closed. The living spec is `../2026-08-03-t6-revision-chain-design.md` with its §15/§15b amendments.

# Revision Chain (T6a–T6e) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> Every task: red-first evidence or a mutation check is REQUIRED in the completion report.

**Goal:** Build the on-disk revision chain of `docs/plans/2026-08-03-t6-revision-chain-design.md`
(§11 tasks T6a–T6e): immutable `canonical-<n>.json` revisions, a serialized store with derived
attachment/current, promotion of `live.jsonl`, the splice engine + draft lifecycle, and
merge/accept/decline/revert semantics. T7 (editor UI + audit log) is a **separate plan**,
written after the format freezes at Gate A.

**Spec:** `docs/plans/2026-08-03-t6-revision-chain-design.md` (rev 2 — the authority on all
rules). **Citation authority:** `docs/plans/2026-08-08-revision-chain-code-maps.md` — the
design doc's `file:line` cites have drifted; when they disagree, the code-maps file wins.

**Architecture:** Pure value types + hand-written decoders (T1), file primitives (T2), one
`TranscriptRevisionStore` actor owning every write into the chain (T3), promotion wired at
finalize/launch/entry-open (T4), pure splice + draft rules (T5), pure merge minting (T6).
The read path never writes; `transcript/` is created only by a content-carrying write.

**Tech stack:** Swift 6 strict concurrency, XCTest, XcodeGen (run `xcodegen generate` after
adding files — sources are directory globs, no `project.yml` edit needed).

## Global constraints

- Test baseline 771 unit + 9 UI. Full suite green before every commit:
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
  with `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- New source files: `Raconte/Transcription/` for chain types/store, following that
  directory's conventions. Tests flat in `RaconteTests/`.
- Hand-written `init(from:)` everywhere (design §4.7): strict identity, lenient additive,
  the ONE unknown-enum rule (unknown raw value never throws).
- JSON via `CaptureCoding.encoder()` (whole documents) — sorted keys, ISO8601-ms.
- The read path never writes (design rule 9). The single most important test in this plan
  is Task 3's read-path-writes-nothing test.
- `transcript/` created only by a content-carrying write (A2b).
- All store write paths skip captures whose sidecar has `trashedAt != nil` (§4.6).
- Commit messages: never write "fixes #N" as prose (GitHub closes the issue on merge).

## Decisions locked here (implementers do not re-litigate)

1. **`TranscriptChainListing` is a deliberate fourth copy of the three-answer shape** —
   payloads differ from `LiveTranscriptSource`/`MarkerLogSource`; no generic abstraction.
2. **§4.6's writer census is amended**: `transcript/` writers are `LiveTranscriptWriter`
   (`live.jsonl`), `MarkerLogWriter` (`markers.jsonl`, landed after the design), and now
   `TranscriptRevisionStore` (everything else). No other writer, ever.
3. **Launch-pass promotion with no `TranscriptRef` is honest-nil**: recovered captures
   (launch path runs no `recordTranscriptRef` — code-maps finding 1) promote with
   `coverageFrames: nil` / `skippedRanges: nil` plus a code comment naming why. We do not
   fabricate coverage, and we do not add `recordTranscriptRef` to recovery in this plan
   (it needs the dead session's `TranscriptionSession`, which no longer exists).
4. **Owner decisions §12 are all settled** — 90 s/60 min/2 s batching, silent replacement
   with revert, queue-not-close on machine arrival, whole-revision accept for v1, decline
   recorded, detached revisions visible. Implement as specified; do not ask again.

---

### Task 1: T6a-types — revision format types, decoders, TranscriptText.join

**Files:**
- Create: `Raconte/Transcription/TranscriptRevision.swift`
- Create: `Raconte/Transcription/TranscriptText.swift`
- Modify: `Raconte/Transcription/TranscriptConsolidator.swift:127-129` (join delegates out)
- Test: `RaconteTests/TranscriptRevisionCodingTests.swift`, `RaconteTests/TranscriptTextTests.swift`

**Interfaces produced (later tasks rely on these exact names):**

```swift
// TranscriptText.swift
enum TranscriptText {
    /// The ONE join rule (design rule 8). Formerly TranscriptConsolidator.join.
    static func join(_ pieces: [String]) -> String {
        pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
```

`TranscriptConsolidator.committedText` and `.displayText` now call
`TranscriptText.join(results.map(\.text))`. Behaviour identical; existing consolidator
tests must stay green untouched.

```swift
// TranscriptRevision.swift — design §4.2 verbatim, plus the enums.
enum RevisionSource: Sendable, Equatable {
    case machineLive, machineRetranscribe, userEdit, merge, `import`
    case unknown(String)
    /// One predicate in one place (design §2.1). unknown counts as MACHINE lineage.
    var isHumanLineage: Bool {
        switch self {
        case .userEdit, .merge, .import: return true
        case .machineLive, .machineRetranscribe, .unknown: return false
        }
    }
}

enum SpanAnchor: String, Sendable, Equatable { case exact, inherited, none }

enum DraftCloseReason: String, Sendable, Equatable {
    case sessionEnd, hourCap, machineArrival, recovered, unknown
}

struct TranscriptSpan: Codable, Sendable, Equatable {
    var text: String               // strict
    var anchor: SpanAnchor         // absent OR unknown raw ⇒ .none
    var frameStart: Int64?         // nil iff anchor == .none
    var frameEnd: Int64?
    var confidence: Double?        // key omitted entirely when nil
    var sourceRevisionID: String?  // key omitted when == containing revision's id
}

struct TranscriptRevision: Codable, Sendable, Equatable {
    var id: String                 // ULID — strict
    var source: RevisionSource     // strict KEY presence; unknown raw → .unknown(raw)
    var createdAt: Date            // strict
    var spans: [TranscriptSpan]    // KEY must be present; may be empty — strict key
    var parentID: String?          // lenient (absent = root)
    var basedOnMachineID: String?  // lenient
    var generator: String?         // lenient …
    var locale: String?
    var coverageFrames: Int64?
    var skippedRanges: [FrameRange]?
    var deviceID: String?
    var closedBy: DraftCloseReason?
}

struct TranscriptHeadSummary: Codable, Sendable, Equatable {
    var id: String
    var fileNumber: Int
    var source: RevisionSource
    var createdAt: Date
    var characterCount: Int
    var firstLine: String
    var isForked: Bool
}

struct TranscriptHead: Codable, Sendable, Equatable {
    var current: TranscriptHeadSummary?
    var revisionFiles: [Int]
    var unreadableFiles: [Int]     // what makes head validation a fixed point (F6)
    var revisionCount: Int
}

struct TranscriptDraft: Codable, Sendable, Equatable {
    var captureID: String          // strict — self-identifying tripwire (design §13 tail)
    var parentID: String?          // revision the draft was opened against
    var basedOnMachineID: String?
    var openedAt: Date             // strict
    var lastWriteAt: Date          // strict
    var text: String               // strict
}
```

Encoding details (get these right; Gate A freezes them):
- `RevisionSource` encodes as its case name string (`"machineLive"`, `"import"`, …);
  `.unknown(let raw)` re-encodes `raw` verbatim so a foreign revision round-trips.
- `TranscriptSpan.encode(to:)` omits `confidence` and `sourceRevisionID` keys when nil
  (§9.5 economies); `frameStart`/`frameEnd` omitted when nil.
- All five types get hand-written `init(from:)`. Strict fields throw on absence; every
  enum decodes unknown raw values without throwing (`SpanAnchor` → `.none`,
  `RevisionSource` → `.unknown(raw)`, `DraftCloseReason` → `.unknown`).
- Copy the decoder idiom from `MarkerLog.swift` / `LiveTranscriptStore.swift`.

**Steps (TDD, red-first each):**

- [ ] **1.1 TranscriptText tests + extraction.** Test: `TranscriptText.join(["a","","b"]) == "a b"`;
  join of empty array is `""`. Then a pin: `TranscriptConsolidator` fixture (two committed
  results) — `committedText` unchanged after the extraction. Run existing
  `TranscriptConsolidatorTests` untouched. Commit `refactor: factor TranscriptText.join out of consolidator (T6a)`.
- [ ] **1.2 Decoder round-trip + strictness tests.** For each type: full round-trip through
  `CaptureCoding`; missing `id`/`createdAt`/`source` key/`spans` key/`span.text` throws;
  missing every lenient key decodes with nils; `spans: []` with key present decodes.
- [ ] **1.3 Unknown-enum rule tests (F10).** JSON with `"source": "futureCase"` decodes to
  `.unknown("futureCase")` and `isHumanLineage == false`; `"anchor": "wobbly"` → `.none`;
  `"closedBy": "telepathy"` → `.unknown`. Re-encode of `.unknown("futureCase")` yields
  `"futureCase"`.
- [ ] **1.4 Key-omission tests.** Encoded span with nil `confidence` contains no
  `"confidence"` key (assert on the raw JSON string); same for `sourceRevisionID`.
- [ ] **1.5 Mirror tripwires** (copy `RecoveryExecutorTests.swift:206` pattern):
  `Mirror(reflecting: TranscriptRevision(...)).children.count == 12` and
  `TranscriptSpan == 6`, each with a comment naming what to update when it fires.
- [ ] **1.6 Full suite + commit** `feat: revision chain format types + decoders (T6a)`.

---

### Task 2: T6a-files — AtomicFile.createExclusively, DirectorySnapshot.transcriptDirUnreadable, SegmentLayout paths

**Files:**
- Modify: `Raconte/Capture/AtomicFile.swift`
- Modify: `Raconte/Capture/DirectorySnapshot.swift:202-216`
- Modify: `Raconte/Capture/SegmentLayout.swift` (path constants + helpers)
- Test: `RaconteTests/AtomicFileTests.swift` (extend), `RaconteTests/DirectorySnapshotTests.swift` or nearest existing, `RaconteTests/LiveTranscriptStoreTests.swift` (layout tests live there today, see :231)

**Interfaces produced:**

```swift
// AtomicFile — sibling to replace(); replace() is UNCHANGED.
/// Create-once: stages data at url.part, fsyncs, then renames with RENAME_EXCL so an
/// existing target fails with EEXIST instead of being silently replaced (design §4.5b).
static func createExclusively(at url: URL, writing data: Data) throws
// Throws AtomicFileError.posix(operation: "renamex_np", code: EEXIST) on collision.
// Implementation: same open/writeAll/fsync/close as replace() (reuse private writeAll),
// then renamex_np(partPath, finalPath, UInt32(RENAME_EXCL)); on failure unlink the .part
// ONLY for EEXIST (a real IO error leaves the .part as evidence, matching replace()).
// Same try? fsyncDirectory(dir) after success as replace() — keep the two consistent.

// SegmentLayout — design §4.1 additions:
static let transcriptHeadFileName  = "head.json"
static let transcriptDraftFileName = "draft.json"
static let entryLogFileName        = "entry-log.jsonl"   // T7 writes it; path lands now
static func transcriptHeadURL(captureDirectory: URL) -> URL
static func transcriptDraftURL(captureDirectory: URL) -> URL
static func entryLogURL(captureDirectory: URL) -> URL    // beside entry.json, NOT in transcript/

// CaptureSnapshot — new field, default false, beside manifestCorrupt:
var transcriptDirUnreadable: Bool
```

`gatherCapture`'s transcript block (`DirectorySnapshot.swift:202-216`) restructures from
`(try? contentsOfDirectory) ?? []` to `do/catch`: catch with
`CocoaError.fileReadNoSuchFile` (mirror `LiveTranscriptReader.loadBytes`,
`LiveTranscriptStore.swift:245-254`) → absent (current behaviour, `transcriptPresent = false`);
any other error → `transcriptDirUnreadable = true` AND `transcriptPresent = true`
(an unreadable directory must keep `holdsIrreplaceableArtifacts` true — quarantine, never
delete). Document it as a display/recovery stat only, never an allocation input (§4.5a).

**Steps:**

- [ ] **2.1 createExclusively red tests.** (a) creates when target absent, content exact,
  no stray `.part`; (b) target exists → throws `.posix(operation: "renamex_np", code: EEXIST)`
  AND the existing target's bytes are untouched; (c) `.part` cleaned up after EEXIST.
- [ ] **2.2 Implement; verify pass. Mutation check (design §10):** temporarily swap the
  `renamex_np` call for `rename` — test (b) must fail. Restore. Record the mutation output
  in the completion report.
- [ ] **2.3 SegmentLayout path tests** (extend the `:231` group): head/draft URLs land in
  `transcript/`, entry-log beside `entry.json`; `canonicalRevision(fromFileName:)` returns
  nil for `head.json` and `draft.json` (they must never be mistaken for revisions).
- [ ] **2.4 transcriptDirUnreadable red test.** Build a capture dir whose `transcript/` is
  a *file*, not a directory (a listing error that isn't no-such-file) → snapshot has
  `transcriptDirUnreadable == true`, `transcriptPresent == true`. Absent dir → false/false
  (pin current behaviour). Implement via the do/catch restructure; all existing
  DirectorySnapshot tests stay green.
- [ ] **2.5 Full suite + commit** `feat: create-once atomic writes + three-answer transcript listing (T6a)`.

---

### Task 3: T6b — TranscriptRevisionStore: listing, append, head, derivation

**Files:**
- Create: `Raconte/Transcription/TranscriptChain.swift` (pure derivation)
- Create: `Raconte/Transcription/TranscriptRevisionStore.swift` (actor)
- Test: `RaconteTests/TranscriptChainTests.swift`, `RaconteTests/TranscriptRevisionStoreTests.swift`

**Interfaces produced:**

```swift
// TranscriptChain.swift — pure, nonisolated, no I/O. Design §2.2–§2.3 verbatim.
enum TranscriptChain {
    /// The total order: (createdAt, id). The ONLY order any caller may use.
    static func ordered(_ revisions: [TranscriptRevision]) -> [TranscriptRevision]
    static func humanTip(_ ordered: [TranscriptRevision]) -> TranscriptRevision?
    /// Transitive closure over parentID and basedOnMachineID, by id lookup within `among`.
    /// Missing ids (synced-in gaps) are simply absent from the closure — never an error.
    static func ancestry(of revision: TranscriptRevision,
                         among revisions: [TranscriptRevision]) -> Set<String>
    static func isAttached(_ revision: TranscriptRevision,
                           in ordered: [TranscriptRevision]) -> Bool
    static func current(_ ordered: [TranscriptRevision]) -> TranscriptRevision?
    static func forkedHumanLineage(_ ordered: [TranscriptRevision]) -> Bool
    /// spans → display text, via TranscriptText.join. The one plainText rule (§4.2).
    static func plainText(_ revision: TranscriptRevision) -> String
}

enum TranscriptChainListing: Equatable {          // design §4.5a — deliberate 4th copy
    case absent
    case unreadable(String)
    case present(files: [Int])
}

enum TranscriptRevisionStoreError: Error, Equatable {
    case transcriptDirUnreadable(String)   // refuses to append (§4.5a)
    case allocationCollision               // two EEXISTs in a row
    case revisionUnreadable(file: Int)     // surfaced by loadChain
    case trashedCapture                    // write attempted on trashedAt != nil
}

actor TranscriptRevisionStore {
    nonisolated let capturesRoot: URL
    init(capturesRoot: URL)

    /// Three-answer listing of canonical-<n>.json files. .unreadable NEVER collapses to [].
    nonisolated static func listing(captureDirectory: URL) -> TranscriptChainListing

    /// Loads every readable revision + the unreadable file numbers, in (createdAt, id) order.
    struct ChainLoad: Sendable, Equatable {
        var revisions: [TranscriptRevision]   // ordered
        var unreadableFiles: [Int]            // non-empty ⇒ entry is read-only (§4.8)
    }
    nonisolated static func loadChain(captureDirectory: URL) -> ChainLoad?
    // nil ⇔ listing == .absent; .unreadable ⇒ ChainLoad([], unreadable sentinel) — see tests

    /// Create-once append (§4.5): checks sidecar trashedAt first (throws .trashedCapture);
    /// listing .unreadable throws; n = max(present)+1 (or 0); createExclusively; on EEXIST
    /// re-list + retry ONCE; then persist head. Creates transcript/ only here (A2b).
    @discardableResult
    func append(_ revision: TranscriptRevision, captureID: String) throws -> Int  // returns n

    /// Head read for the scanner: validated, never trusted. On mismatch/absent/unreadable
    /// rebuilds IN MEMORY and returns the rebuild; queues persistence via the actor —
    /// the read itself writes nothing.
    nonisolated static func validatedHead(captureDirectory: URL) -> TranscriptHead?
    func persistHead(captureID: String) throws       // the only head writer
}
```

Head content rules: `current` summary from `TranscriptChain.current` over the readable
chain; `firstLine` = first line of `plainText`, max 120 chars; `revisionFiles` = every
parsed `canonical-<n>` filename readable or not; `unreadableFiles` = decode failures
(what makes rebuild a fixed point, F6).

**Steps:**

- [ ] **3.1 TranscriptChain order tests.** `ordered` stable under shuffle and under
  filename renumbering (ids/createdAt fixed, input order permuted → same output);
  tie on `createdAt` broken by `id` (ULIDs sort lexicographically).
- [ ] **3.2 The design's §10 attachment walks, as named tests.**
  - `testF1MachineAfterMachineIsDetached`: machineLive → userEdit A → userEdit B →
    retranscribe M1(parent rev0) → retranscribe M2(parent M1) ⇒ M1, M2 both detached;
    current == B.
  - `testA1DataLossWalk`: {rev0 machine, M retranscribe(parent rev0, latest createdAt)}
    current == M; insert userEdit Y with createdAt between ⇒ current == Y, M detached.
    No file involved — pure.
  - `testA1DivergenceWalk`: two concurrent userEdits, neither in other's ancestry ⇒
    current = later by (createdAt,id); `forkedHumanLineage == true`.
  - `testNilBase`: chain with no machine revision ⇒ no machine ancestor for diff
    (assert via ancestry/humanTip primitives).
  - `testUnknownSourceIsMachineLineage`: an `.unknown("x")` revision never becomes humanTip.
- [ ] **3.3 Listing tests.** Absent dir → `.absent`; dir with only `live.jsonl`/
  `markers.jsonl`/`head.json`/stray `.part` → `.present(files: [])`; `canonical-0.json` +
  `canonical-7.json` → `[0,7]`; unreadable `transcript/` (a file at that path) →
  `.unreadable`. **Mutation check (A3):** replace the listing's do/catch with
  `(try? …) ?? []` → the unreadable test must fail.
- [ ] **3.4 Append tests.** First append creates `transcript/` + `canonical-0.json` (byte
  round-trip); second lands at 1; append onto pre-seeded `canonical-3.json` lands at 4;
  a hand-planted collision (seed the target file between listing and write via a test seam:
  inject `beforeWrite: () -> Void` hook or plant `canonical-<max+1>.json` before calling)
  → EEXIST path re-lists and lands at next free n, planted file byte-untouched;
  sidecar `trashedAt != nil` → `.trashedCapture` thrown, `transcript/` NOT created;
  listing unreadable → throws, nothing written.
- [ ] **3.5 Head + read-only tests.** `validatedHead` on head-absent → in-memory rebuild
  matching directory; corrupt `head.json` → same rebuild; **fixed point (F6)**: chain with
  one undecodable `canonical-1.json` → rebuilt head lists it in `unreadableFiles`, and a
  second `validatedHead` call returns an identical value with **zero writes** (assert
  directory mtimes/contents byte-identical across the two calls). `loadChain` with an
  undecodable file reports it in `unreadableFiles` (§4.8 read-only signal).
- [ ] **3.6 THE read-path test (design §10: "the single most important test in T6").**
  Build a tree: revisions + no head + a stale `draft.json`. Snapshot every file's bytes +
  mtimes. Run `TranscriptRevisionStore.listing`, `loadChain`, `validatedHead`, and a full
  `LibraryScanner.scan`. Assert the tree is byte-identical and mtime-identical after.
- [ ] **3.7 Full suite + commit** `feat: TranscriptRevisionStore — create-once chain, derived attachment (T6b)`.

---

### GATE A: adversarial review — the format freezes here

Dispatch an Opus adversarial review of Tasks 1–3 (the design doc §11 requires it "after
T6a–T6b, format frozen"). Reviewer instructions: attack the decoder strictness split, the
encode-key omissions, the `(createdAt, id)` derivation against the §2.3 walks, EEXIST
handling, and A2b (`transcript/` creation sites). The reviewer independently re-runs the
full suite. Fix findings before Task 4. **After this gate, `TranscriptRevision`'s encoded
shape does not change without a new design pass.**

---

### Task 4: T6c — promotion + loader preference + wiring

**Files:**
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift` (add promotion)
- Modify: `Raconte/Library/EntryTranscript.swift:68-99` (canonical preference)
- Modify: `Raconte/Capture/UI/CaptureView.swift:456-457` (finalize slot), launch path :215-220
- Modify: `Raconte/Library/UI/EntryDetailView.swift:92-99` (`refresh()` promotion nudge)
- Test: `RaconteTests/TranscriptPromotionCanonicalTests.swift` (NOT `TranscriptPromotionTests.swift` — that file is consolidator promotion, unrelated), extend `RaconteTests/EntryTranscriptLoaderTests` equivalents

**Interfaces produced:**

```swift
// On TranscriptRevisionStore:
enum PromotionOutcome: Sendable, Equatable {
    case promoted(revisionID: String)
    case skippedAlreadyPromoted, skippedTrashed, skippedNoAudio, skippedNoLog
    case failed(String)
}
@discardableResult
func promoteIfNeeded(captureID: String) async -> PromotionOutcome
/// One-shot pass over every capture directory; serialized by the actor; returns counts.
func promoteCorpus() async -> [String: PromotionOutcome]

// Pure mapping, testable without the actor (design §5.2):
nonisolated static func spans(fromCommitted committed: [TranscriptResult]) -> [TranscriptSpan]
```

Promotion rules (§5.1/§5.2, with the code-maps corrections):
- Skips in order: `trashedAt != nil` (read sidecar via `EntryMetadataStore.read(url:)`
  static seam) → `.skippedTrashed`; listing shows any canonical file → `.skippedAlreadyPromoted`;
  no `final/recording.m4a` → `.skippedNoAudio`; log absent → `.skippedNoLog`;
  log unreadable → `.failed` (never promote a log we can't fully read).
- Span mapping: per committed result, if `runs` non-empty → one span per run,
  `anchor = .exact` iff BOTH `captureFrameStart`/`captureFrameEnd` non-nil else `.none`;
  runless → ONE span for the whole result, `anchor: .inherited`, frames from
  `result.range` (§5.2 — the runless branch is `.inherited`, C1).
- Revision fields: `id = ULID.make()`, `source: .machineLive`, `createdAt = now`,
  `parentID: nil`, `basedOnMachineID: nil`, `generator`/`locale` from the LAST record,
  `coverageFrames`/`skippedRanges` copied from `manifest.transcript` — **nil when the
  manifest has no TranscriptRef** (locked decision 3: launch-recovered captures), with a
  comment citing the code-maps finding. `deviceID`: read-or-mint a per-install ULID
  (`UserDefaults` key `raconte.deviceID` via a small `DeviceIdentity.stable()` helper in
  the same file). `closedBy: nil`.

Wiring:
- **Finalize:** `CaptureView.swift` — between the `recordTranscriptRef` loop (:456) and the
  `detectSpokenDate` loop (:457): `for id in transcribed { await revisionStore.promoteIfNeeded(captureID: id) }`.
  `CaptureScreenModel` gains the store via the same composition-root injection pattern as
  `entryMetadataStore` (a `let` handed in from `ContentView.init` /
  `LibraryScreenModel.live()` — one store instance app-wide, matching the one-actor-per-file rule).
- **Launch pass:** `LibraryScreenModel` gains `func promoteCorpusOnce() async` guarded by a
  `private var corpusPromotionRan = false`; called fire-and-forget from the same place
  `sweepTrash()` is (after first scan publishes), BEFORE the sweep.
- **Entry-open:** `EntryDetailView.refresh()` calls
  `await model.promoteIfNeeded(captureID)` (thin passthrough on `LibraryScreenModel`)
  before `model.transcript(for:)`.

Loader preference (`EntryTranscriptLoader.load`):
- New first branch: `TranscriptRevisionStore.loadChain(captureDirectory:)` — if non-nil
  and has a readable current: text = `TranscriptChain.plainText(current)`,
  state `.present`. If `unreadableFiles` non-empty → add new
  `EntryDegradation.revisionUnreadable` (extend the OptionSet AND `allDeclared`,
  `EntryListItem.swift:51-54` — the table test will demand it). If NO revision is readable
  → fall through to today's `live.jsonl` path unchanged (§4.8 three answers all the way down).
- Attribution (`.compute` mode): unchanged for v1 — it renders from committed records +
  markers exactly as today. Canonical text and `committedText` are display-identical by
  construction (same join), so the paragraphs stay consistent. Add the test proving it.

**Steps:**

- [ ] **4.1 Span-mapping table tests** (pure): timed runs → exact spans; run missing one
  bound → `.none`; runless result → single `.inherited` span with result.range frames;
  mixed. Generator disagreement across records → last record's generator wins (comment §5.2).
- [ ] **4.2 Display-identity test (F16).** Fixture log (reuse a `LiveTranscriptStoreTests`
  fixture) → promote → `TranscriptChain.plainText(revision)` ==
  `consolidate(records).committedText`, byte for byte.
- [ ] **4.3 Promotion skip tests.** Each skip case; once-only (second call →
  `.skippedAlreadyPromoted`, directory unchanged); trashed capture leaves NO `transcript/`
  behind when the log lived elsewhere — i.e. skip happens before any write.
- [ ] **4.4 Provenance tests.** With a manifest carrying a TranscriptRef: `coverageFrames`
  copied. **Mutation check (B1):** point the copy at the wrong source (hardcode nil) →
  test fails. Without a ref (launch-recovery shape): promotes, coverage nil, no throw.
- [ ] **4.5 Loader preference tests.** Canonical present → text from revision;
  canonical + undecodable sibling → `revisionUnreadable` degradation, text from best
  readable; all revisions unreadable → live.jsonl fallback; no canonical → today's path
  (pin with an existing fixture). Detection boundary (C3): `SpokenDateDetection` input
  text identical pre/post promotion for the same log.
- [ ] **4.6 Wire finalize + launch + entry-open.** UI-adjacent, so cover with the model:
  a `CaptureScreenModel`-level test that a finalized capture ends with exactly one
  canonical revision whose `coverageFrames` is non-nil (mutation check: move the promote
  call before `recordTranscriptRef` → fails).
- [ ] **4.7 Full suite + commit** `feat: promote live.jsonl to canonical revision zero (T6c)`.

---

### Task 5: T6d — splice engine + draft lifecycle

**Files:**
- Create: `Raconte/Transcription/TranscriptSplice.swift`
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift` (draft API)
- Test: `RaconteTests/TranscriptSpliceTests.swift`, `RaconteTests/TranscriptDraftLifecycleTests.swift`

**Interfaces produced:**

```swift
// TranscriptSplice.swift — pure (§3.3). No I/O, no actor.
enum TranscriptSplice {
    /// Diff editedText against parent's plainText; rewrite the span array per §3.3:
    /// unchanged spans verbatim (text, frames, anchor, sourceRevisionID);
    /// partial edit → split, BOTH sides .inherited with the parent span's FULL bounds;
    /// insertion → .inherited zero-length point at preceding anchored span's frameEnd,
    ///   .none if no preceding anchored span; deletion → span gone, frames unclaimed.
    /// Then merge adjacent spans sharing (.none) or (.inherited + identical bounds +
    /// identical sourceRevisionID). Adjacent .exact never merged.
    static func spans(parent: TranscriptRevision, editedText: String) -> [TranscriptSpan]
}

// TranscriptRevisionStore draft API (§2.5). All throw .trashedCapture on trashedAt != nil.
struct DraftPolicy: Sendable {          // the two invented numbers, injectable for tests
    var sessionEndSeconds: TimeInterval = 90
    var hourCapSeconds: TimeInterval = 3600
}
/// Writes draft.json via AtomicFile.replace. Creates transcript/ lazily — ONLY when
/// text differs from current's plainText (A2b: content-carrying writes only).
func writeDraft(captureID: String, text: String, now: Date) throws
/// Closes per §2.5: text == current's plainText → delete draft, mint NOTHING.
/// Else mint userEdit revision via TranscriptSplice (parentID = draft.parentID,
/// basedOnMachineID propagated per §6.4), then delete draft. Returns minted id or nil.
@discardableResult
func closeDraft(captureID: String, reason: DraftCloseReason, now: Date) throws -> String?
/// Stale-draft pass for launch + entry-open (NEVER the scan): closes drafts whose
/// lastWriteAt is older than policy.sessionEndSeconds with reason .recovered.
func closeStaleDrafts(now: Date) async
```

The 2 s editor debounce is T7's (UI); the store exposes `writeDraft`/`closeDraft` and the
90 s / 60 min rules only. `closeDraft` computes hourCap from `openedAt`.

**Locked decision — the text diff:** use Swift's built-in
`editedText.difference(from: parentText)` over `Character`s (Myers), with adjacent
removals+insertions coalesced into replacement hunks before applying §3.3. Do NOT use
`inferringMoves()` — v1 has no editor move-reporting, and the design defines move as
delete+insert unless the editor reports one (§3.3). No third-party diff dependency.

**Steps:**

- [ ] **5.1 Splice table tests** (the design §10 list, one test per row): unchanged text
  preserves `exact` + `sourceRevisionID`; mid-span edit degrades BOTH sides to
  `.inherited` with parent's full bounds, never sub-ranges (F17); deletion leaves frames
  unclaimed (no neighbour stretching); insertion with no preceding anchor → `.none`;
  insertion after an anchored span → zero-length `.inherited` point at its frameEnd;
  span-merge bound: adjacent `.none` merge, adjacent `.inherited`-same-bounds-same-source
  merge, adjacent `.exact` never merge.
- [ ] **5.2 Monotone-lattice property (F18, scoped).** Generative: random parent + random
  edit → no output span has `anchor == .exact` with text differing from the parent span it
  descends from. **Mutation check:** relax the partial-edit rule to keep `.exact` → fails.
- [ ] **5.3 Draft lifecycle tests.** writeDraft text == current → no `transcript/` created
  on a fresh capture (A2b); differing text → draft.json exists, atomic-replaced on second
  write; closeDraft with equal text → draft deleted, NO revision minted (the F7
  crash-duplicate rule: compare against CURRENT, not parent — test the crash shape:
  revision already minted, draft still on disk, close again → nothing new);
  closeDraft with changed text → userEdit revision, correct parentID/basedOnMachineID
  (§6.4: copies parent's, or parent's id when parent is machine), draft gone;
  hourCap: openedAt 61 min ago → closes with `.hourCap`; closeStaleDrafts skips fresh
  drafts, closes stale with `.recovered`, skips trashed captures.
- [ ] **5.4 Full suite + commit** `feat: splice engine + draft lifecycle (T6d)`.

---

### Task 6: T6e — merge, accept, decline, revert

**Files:**
- Create: `Raconte/Transcription/TranscriptMerge.swift`
- Test: `RaconteTests/TranscriptMergeTests.swift`

**Interfaces produced:**

```swift
// TranscriptMerge.swift — pure minting of merge revisions (§6). v1 is whole-revision
// (owner decision §12.6); per-hunk is out of scope but the overlap rule ships anyway
// because revert/accept both route through it.
enum TranscriptMerge {
    /// Accept: adopt the machine revision's spans verbatim (text+frames together — the
    /// legitimate route up the lattice). parentID = current.id,
    /// basedOnMachineID = machine.id, source = .merge.
    static func accept(current: TranscriptRevision, machine: TranscriptRevision,
                       id: String, createdAt: Date, deviceID: String?) -> TranscriptRevision
    /// Decline: spans byte-identical to current's, basedOnMachineID = machine.id (§6.5).
    static func decline(current: TranscriptRevision, machine: TranscriptRevision,
                        id: String, createdAt: Date, deviceID: String?) -> TranscriptRevision
    /// Revert: adopt the reverted-to machine revision's spans verbatim (§6.5).
    static func revert(current: TranscriptRevision, toMachine machine: TranscriptRevision,
                       id: String, createdAt: Date, deviceID: String?) -> TranscriptRevision
    /// F11 rule, shipped for future per-hunk use and applied at every merge close:
    /// any retained span whose frame range intersects an adopted span's degrades to .inherited.
    static func degradingOverlaps(retained: [TranscriptSpan],
                                  adopted: [TranscriptSpan]) -> [TranscriptSpan]
}
// Store glue: func apply(_ merge: TranscriptRevision, captureID: String) throws -> Int
// is just append() — merges are ordinary revisions. Machine-arrival queues (owner Q4):
// nothing closes a draft here; T8 wires arrival.
```

**Steps:**

- [ ] **6.1 Accept tests.** Adopted spans byte-identical to machine's (text AND frames,
  the merge-exemption test F18 demands as its own case); parentID/basedOnMachineID
  correct; result is human lineage; after append, `TranscriptChain.current` == the merge.
- [ ] **6.2 Decline tests.** Spans == current's exactly; basedOnMachineID advanced;
  next attachment derivation: the declined machine revision stays detached, current is
  the decline. Comment in code: "text-identical is intentional — see §6.5, this is not
  the §2.5 no-op rule" (the design says it will look like a bug otherwise).
- [ ] **6.3 Revert tests.** Untouched-entry shape: rev0 machine → retranscribe M (current,
  attached) → revert to rev0 ⇒ current is the merge, spans byte-equal rev0's, `.exact`
  anchors restored legitimately.
- [ ] **6.4 F11 overlap test.** Retained `exact` span [0,100] + adopted span [45,100] →
  retained degrades to `.inherited`; property: after `degradingOverlaps`, no two `.exact`
  spans intersect.
- [ ] **6.5 basedOnMachineID propagation walk (§6.4/F13):** userEdit-after-merge copies the
  merge's basedOnMachineID (stored, not "nearest machine ancestor" — construct the case
  where they differ and assert the stored answer).
- [ ] **6.6 Full suite + commit** `feat: merge/accept/decline/revert minting (T6e)`.

---

### GATE B: adversarial whole-branch review

Opus review of the full T6 delta against the design doc + this plan; reviewer re-runs the
suite independently and runs the §10 checklist as an audit (every named test exists and
tests what its name says — the fabricated-evidence lesson from #25 step 3). Residual
minors get filed or parked in this plan's history section, not silently dropped.

---

## Self-review notes (plan author)

- Spec coverage: §2 (Tasks 1,3), §3 (5), §4 (1,2,3), §5 (4), §6 (6), §7 → T7 plan,
  §8.3/`Manifest.kind` → T10 (explicit non-goal here), §10 tests distributed per task.
- The §12.Q4 queue rule and §6 arrival wiring are T8's; T6e only mints.
- Type/name consistency: `TranscriptChain`/`TranscriptText`/`TranscriptSplice`/
  `TranscriptMerge`/`TranscriptRevisionStore` — checked against each task's Consumes list.
- Known deliberate gaps: editor UI, revision-history panel, diff presentation, audit log,
  tap-to-play — all T7; retranscription worker — T8.
