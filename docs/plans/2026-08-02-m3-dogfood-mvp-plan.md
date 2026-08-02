# M3 — Dogfood MVP (journals, library, editorial, sync)

Status: plan of record, 2026-08-02. Supersedes the original M3/M4 ordering in
`docs/native-rebuild-plan.md` for scope and sequence; the principles there stand.
Companion: `docs/user-journeys.md` (owner-edited), mockups from the 2026-08-02 design
session.

Goal: the owner starts journaling into Raconte immediately — reading old paper journals
aloud on the phone and making present-day entries — on iPhone, MacBook, and mini, with a
Mac editorial surface and CloudKit sync arriving before editorial gets heavy use.

## Decisions (owner, 2026-08-02)

- **Journals are first-class.** Every entry belongs to a journal ("1987 Journal",
  "Trip to France", "Testing Raconte"). Capture happens in the context of the current
  journal.
- **Backdating is optional.** `originalDate` defaults to `capturedAt`; the owner edits it
  only when reading old material. No required metadata, ever.
- **Deletion = 30-day trash.** Soft delete anywhere (including phone), recoverable 30
  days, then truly gone. Builds on the existing quarantine mechanism, not beside it.
- **Human edits are version-controlled.** Append-only revision chain per entry; machine
  transcript is the base layer; revisions batch per editorial session or per hour,
  whichever is shorter. Never overwrite, never reapply automatically.
- **Retranscribe mints a machine revision** without touching human edits.
- **Search indexes both layers** (machine + human-corrected); corrected text displays and
  ranks first; machine-only hits still surface, labeled. (Claude's call, revisitable.)
- **Audio-time anchoring through edits: deferred** — issue #13.
- **Sync sequencing:** data model first, capture on all three devices immediately (silos
  merge later — entries are ULID-keyed and immutable at capture), CloudKit as the next
  rock after editorial v1 exists, before multi-device editing begins.
- **Migration retranscribes at import:** old web transcripts arrive as the first human
  revision over a freshly synthesized machine base. Paper-archive web entries without
  audio force a text-only entry kind (migration phase, not before).

## Architecture stance

- Disk stays ground truth. User metadata lives in a new `entry.json` sidecar per capture
  directory — NOT in the manifest. The manifest is capture-machine territory, hardened by
  the recovery suite; entry metadata is user-mutable and must be editable without
  touching those paths. Missing `entry.json` ⇒ all defaults (journal = unfiled,
  originalDate = capturedAt). Hand-written `init(from:)` per the §11 decoder rule.
- No GRDB yet. At dogfood scale (tens to low hundreds of entries) the library reads the
  directory scan directly, as recovery already does. GRDB + FTS5 arrive with search, as a
  rebuildable index over disk — never as a second source of truth.
- Revision-chain on-disk format is a design task (T6) before its build, same discipline
  as the M2 design doc. Not sketched here to avoid a format decided in a planning doc.

## Tasks

Phase 0 — dogfood enablers (parallel, small)
- **T0** (#12): keep the display awake while recording (`isIdleTimerDisabled`,
  iOS only, on while capture is active, off on stop/interruption/background). Sonnet.

Phase 1 — model on disk
- **T1**: `Journal` (ULID id, name, createdAt) + journals registry in the app container;
  `EntryMetadata` + `entry.json` sidecar (journalID, originalDate?, trash state);
  `EntryMetadataStore` with atomic write; current-journal selection persisted
  (UserDefaults). Pure logic test-first; no UI. Opus.
- **T2**: library model — enumerate capture directories into `[EntryListItem]` (journal,
  originalDate w/ default, duration, first transcript line, edited badge, trash filter),
  sorted by originalDate; pure and scan-based. Opus or Sonnet.

Phase 2 — dogfood UI (after T1/T2)
- **T3**: capture screen journal context (header, journal picker/create, optional
  backdate field) per phone mockup. Sonnet.
- **T4**: library + entry detail screens per phone mockup (journal chips, year groups,
  both dates, playback with existing scrubber). Sonnet.
- **T5**: trash — soft delete (tombstone in `entry.json`), Trash view, restore,
  30-day sweep that only hard-deletes tombstoned dirs past expiry; must compose with
  `holdsIrreplaceableArtifacts` (quarantine keeps protecting non-tombstoned dirs). Opus.

Phase 3 — editorial v1 (Mac)
- **T6**: revision-chain design doc (on-disk format, session/hour batching rule, promote
  rules vs. live transcript, retranscribe semantics, migration's human-first import shape
  and text-only entries). Adversarial review pass like M2's. Opus + review agents.
- **T7**: Mac editor UI per mockup — read, edit, revision history panel. Sonnet/Opus.
- **T8**: retranscribe from `final/recording.m4a` → new machine revision. Also closes the
  standing "retranscription is the correctness guarantee" gap from M2. Opus.

Phase 4 — sync (pulled forward from M4)
- **T9**: CKSyncEngine, private DB, custom zone; design task first, then build. Container
  `iCloud.org.pianohouseproject.raconte` already reserved. Gate: lands before editorial
  is used from more than one device.

Phase 5 — migration
- **T10**: one-off import script: Neon rows + blobs → capture dirs; retranscribe at
  import; old transcript = human revision v1; text-only entry kind for audio-less
  paper-archive entries. Then the recountly.org teardown checklist (notify prompt-lab
  first, per the 2026-08-02 handoff reply).

## Process

Fable supervises; Opus/Sonnet subagents build one task at a time with tight briefs.
Builders do not commit — every diff is reviewed by the supervisor before landing.
Seam-heavy tasks (T1, T5, T6, T8, T9) get closer review than UI tasks. Device
verification per the standing rule: CI green means little for SDK-facing code.

M2 tail items not folded in here (#1 background awareness, #9 interruption endedAt,
abandon hook, recovery ref synthesis) stay open on their own; dogfooding will tell us
which of them actually matter next.
