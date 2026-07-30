# Data model + migration — native rebuild (2026-07-29)

Forward design for Milestone 3, done during Milestone 1 so M1 doesn't create migration debt.
Plan of record: `docs/native-rebuild-plan.md`. Carries over the web app's semantics
(`db/schema.sql`, `src/lib/entry-sql.ts`) with the two structural upgrades the pivot buys us:
audio-as-ground-truth (multi-segment audio assets → solves web #53) and generated-vs-user
field separation (field-level enrichment provenance).

Scope note: this is the M3 target schema. M1 ships a strict subset of it (§5), not a throwaway.

---

## 1. GRDB / SQLite schema

Conventions:
- IDs are TEXT. New rows: ULID (`src/lib/ulid.ts` port). Migrated rows keep their web id
  verbatim (incl. the 23 `imp_<year>_<MON_DD_HH.MM>` paper imports) — see §4.
- Timestamps are TEXT ISO-8601 UTC (`...Z`). Lexicographic order == chronological order, so
  plain SQLite `ORDER BY` works and export files are human-readable. `originalWrittenAt` is
  stored as a full timestamp (anchored local-noon, the web `writtenAtIso` idiom) with a
  separate precision enum telling the UI how much of it is real.
- Applied via GRDB `DatabaseMigrator`, one registered migration per version. DDL below is the
  raw SQL each migration runs.
- Every syncable table carries `ckSystemFields BLOB` (archived CKRecord metadata for change
  tags — §2). Derived tables (`entry_search`, `entry_fts`) are **local-only, never synced**.

### entries

```sql
CREATE TABLE entries (
  id                    TEXT PRIMARY KEY,
  spokenAt              TEXT NOT NULL,                         -- web recorded_at: when actually recorded
  originalWrittenAt     TEXT,                                  -- web written_at: when the page was first written; null for a normal spoken entry
  writtenPrecision      TEXT CHECK (writtenPrecision IN ('exact','day','month','year')),  -- how much of originalWrittenAt is real; null when originalWrittenAt is null
  durationSeconds       REAL NOT NULL DEFAULT 0,
  journalId             TEXT REFERENCES journals(id),
  pageLabel             TEXT,                                  -- free text, e.g. "pp. 14–16"
  status                TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('capturing','active','trashed')),
  trashedAt             TEXT,                                  -- set iff status='trashed'; drives "newest-trashed-first" + auto-purge timer

  -- USER-authored fields (generated equivalents live in enrichments; display coalesces user ?? generated)
  userTitle             TEXT,                                  -- null = fall back to enrichment title
  notes                 TEXT,
  location              TEXT DEFAULT 'home',

  -- canonical transcript pointer + provenance (bodies live in transcript_revisions, append-only)
  canonicalRevisionId   TEXT REFERENCES transcript_revisions(id),
  transcriptLastUserEditedAt  TEXT,                            -- null = user has never touched the transcript
  transcriptLastGeneratedAt   TEXT,                            -- last time STT/enrichment (re)generated it

  -- audio-complete cue carried from web for provenance; native entries recompute from segment coverage
  audioComplete         INTEGER,                               -- 1 full / 0 partial / null unknown-or-no-audio

  createdAt             TEXT NOT NULL,
  updatedAt             TEXT NOT NULL,
  ckSystemFields        BLOB,
  legacyWebId           TEXT                                   -- provenance for migrated rows (== id today; kept distinct in case ids ever diverge)
);

-- effective date = when-written-if-known-else-when-spoken (the web coalesce, now a column)
ALTER TABLE entries ADD COLUMN effectiveAt TEXT
  GENERATED ALWAYS AS (coalesce(originalWrittenAt, spokenAt)) VIRTUAL;

CREATE INDEX entries_effectiveAt        ON entries (effectiveAt DESC);
CREATE INDEX entries_journal_effective  ON entries (journalId, effectiveAt);
CREATE INDEX entries_status             ON entries (status);
```

Notes: `status` folds the web `deleted_at` into an explicit enum and adds `capturing` for
in-flight recordings (§5). Trash stays soft (row + media kept); permanence is an explicit
purge. `capturing` rows are the recovery-scan target.

### journals

```sql
CREATE TABLE journals (
  id             TEXT PRIMARY KEY,
  label          TEXT NOT NULL,
  notes          TEXT,
  kind           TEXT NOT NULL DEFAULT 'contemporary'
                   CHECK (kind IN ('contemporary','paperArchive')),   -- web kind: null→contemporary, 'archive'→paperArchive
  startedOn      TEXT,                                                 -- YYYY-MM-DD owner-set range override
  endedOn        TEXT,
  coverPhotoId   TEXT REFERENCES photos(id),                          -- web #33 (schema-only until UI built)
  isActive       INTEGER NOT NULL DEFAULT 0,                          -- capture default; OPEN whether synced (§2)
  createdAt      TEXT NOT NULL,
  updatedAt      TEXT NOT NULL,
  ckSystemFields BLOB
);
```

At most one `isActive=1` is an app-side invariant (the web `setActiveJournalSql` single-UPDATE
idiom ports directly).

### transcript_revisions (append-only)

```sql
CREATE TABLE transcript_revisions (
  id         TEXT PRIMARY KEY,
  entryId    TEXT NOT NULL REFERENCES entries(id),
  text       TEXT NOT NULL,
  source     TEXT NOT NULL CHECK (source IN ('import','onDeviceSTT','cloudSTT','userEdit')),
  createdAt  TEXT NOT NULL,
  ckSystemFields BLOB
);
CREATE INDEX transcript_revisions_entry ON transcript_revisions (entryId, createdAt);
```

Never UPDATE/DELETE. A user edit or a re-transcription appends a new row and repoints
`entries.canonicalRevisionId`; the entry-level `transcriptLast*EditedAt/GeneratedAt` stamps
carry the provenance the plan named. Because each revision has a distinct id it can never
conflict on sync (§2). Time-indexed capture segments (SpeechAnalyzer volatile→committed spans
with audio offsets) are a Milestone-2 addition — a `transcript_segments(entryId, revisionId,
text, audioStartTime, audioEndTime)` table — kept out of the M3 core here; the canonical
revision text is the searchable/exportable artifact.

### enrichments (generated fields, separate from user fields)

```sql
CREATE TABLE enrichments (
  entryId     TEXT PRIMARY KEY REFERENCES entries(id),   -- one current enrichment per entry
  model       TEXT NOT NULL,
  title       TEXT,
  summary     TEXT,
  tags        TEXT NOT NULL DEFAULT '[]',                -- JSON array (SQLite JSON1)
  enrichedAt  TEXT NOT NULL,
  ckSystemFields BLOB
);
```

Field-level provenance is structural, not a flag soup: generation writes freely here and never
touches `entries.userTitle/notes`; the display/effective value is `entries.userTitle ??
enrichments.title`, `entries.notes ?? …` etc. This is the clean version of what the web
approximated with `title = coalesce(entries.title, $n)`. Regeneration overwrites this row and
still can't clobber a user edit.

### photos

```sql
CREATE TABLE photos (
  id             TEXT PRIMARY KEY,
  entryId        TEXT REFERENCES entries(id),            -- entry photo (all migrated photos are these)
  journalId      TEXT REFERENCES journals(id),           -- OR a journal cover; exactly one of entryId/journalId set
  mime           TEXT NOT NULL,
  bytes          INTEGER NOT NULL,
  width          INTEGER,
  height         INTEGER,
  sha256         TEXT NOT NULL,                          -- content address (CKAsset dedupe + export verify)
  filename       TEXT NOT NULL,                          -- relative path in app container
  createdAt      TEXT NOT NULL,
  ckSystemFields BLOB
);
CREATE INDEX photos_entry   ON photos (entryId, id);      -- id is ULID → capture order (web idiom)
CREATE INDEX photos_journal ON photos (journalId);
```

Photos stay NOT best-effort (web #10 lesson): a lost photo is unrecoverable, so a failed
photo write fails the capture save.

### audio_assets (per-entry, multi-segment — solves web #53)

```sql
CREATE TABLE audio_assets (
  id             TEXT PRIMARY KEY,
  entryId        TEXT NOT NULL REFERENCES entries(id),
  segmentIndex   INTEGER NOT NULL,                       -- 0-based order within the entry
  startTime      REAL NOT NULL DEFAULT 0,                -- seconds into the entry timeline
  durationSeconds REAL NOT NULL,
  mime           TEXT NOT NULL,                          -- e.g. audio/mp4 (AAC-LC finalized)
  bytes          INTEGER NOT NULL,
  sha256         TEXT NOT NULL,                          -- content address (immutable asset)
  filename       TEXT NOT NULL,                          -- relative path in app container
  state          TEXT NOT NULL DEFAULT 'finalized'
                   CHECK (state IN ('capturing','raw','finalized')),
  createdAt      TEXT NOT NULL,
  ckSystemFields BLOB
);
CREATE UNIQUE INDEX audio_assets_entry_seg ON audio_assets (entryId, segmentIndex);
```

An entry's audio is the ordered concatenation of its finalized segments. A pause/resume adds a
segment instead of the web's "keep only the last segment" data loss. Entry-level
`audioComplete` becomes derived (segments cover `[0, duration)` with no gaps) for native
entries; it's kept as a stored column only to carry the web flag forward for migrated rows.

### FTS5 (external-content + triggers)

Searchable text is assembled across three tables (user-or-generated title, notes, location,
canonical transcript), so we keep a denormalized shadow table `entry_search` (one row per
entry, maintained by the app in the same write transaction as any searchable change) and put
an external-content FTS5 index over it with the standard three sync triggers.

```sql
CREATE TABLE entry_search (
  entryId    TEXT PRIMARY KEY REFERENCES entries(id),
  title      TEXT,      -- coalesce(userTitle, enrichment.title)
  notes      TEXT,
  location   TEXT,
  transcript TEXT       -- canonical revision text
);

CREATE VIRTUAL TABLE entry_fts USING fts5(
  title, notes, location, transcript,
  content='entry_search', content_rowid='rowid'
);

-- external-content keep-in-sync triggers (rowid = entry_search implicit rowid)
CREATE TRIGGER entry_search_ai AFTER INSERT ON entry_search BEGIN
  INSERT INTO entry_fts(rowid, title, notes, location, transcript)
  VALUES (new.rowid, new.title, new.notes, new.location, new.transcript);
END;
CREATE TRIGGER entry_search_ad AFTER DELETE ON entry_search BEGIN
  INSERT INTO entry_fts(entry_fts, rowid, title, notes, location, transcript)
  VALUES ('delete', old.rowid, old.title, old.notes, old.location, old.transcript);
END;
CREATE TRIGGER entry_search_au AFTER UPDATE ON entry_search BEGIN
  INSERT INTO entry_fts(entry_fts, rowid, title, notes, location, transcript)
  VALUES ('delete', old.rowid, old.title, old.notes, old.location, old.transcript);
  INSERT INTO entry_fts(rowid, title, notes, location, transcript)
  VALUES (new.rowid, new.title, new.notes, new.location, new.transcript);
END;
```

Query with `entry_fts MATCH ?` + `snippet()`/`highlight()` for the web's match-highlighting
parity, join `entry_fts.rowid → entry_search.rowid → entry_search.entryId → entries`, filter
`status='active'`. `entry_search` and `entry_fts` are local — rebuilt on import and on any
CloudKit fetch, never synced.

---

## 2. CloudKit sync mapping (CKSyncEngine, custom zone) — sketch

Enough to prove the schema doesn't block sync; full conflict design is Milestone 4.

- **One custom zone** `RecountlyZone` in the **private** database. iCloud identity only — no
  auth UI. Never sync the SQLite file itself.
- **Record types** = one per table: `Entry`, `Journal`, `TranscriptRevision`, `Enrichment`,
  `Photo`, `AudioAsset`. `CKRecord.recordName` = the local `id` (ULID or `imp_…`; both are
  ASCII ≤255, valid record names). Scalar columns map to CKRecord fields 1:1;
  `tags` travels as a JSON string field.
- **CKAssets** = immutable content-addressed media: `Photo.file` and `AudioAsset.file`, with
  `sha256` as a sibling field. Assets are never mutated — a new capture/segment is a new
  record. This is why `audio_assets`/`photos` are append-style and content-addressed.
- **Parent references for cascade**: `TranscriptRevision`, `Enrichment`, `Photo`, `AudioAsset`
  set `parent = Entry` (CKRecord.Reference). Zone-scoped Entry deletion cascades children.
- **Trash = a synced field**, not a CloudKit delete: `Entry.status`/`trashedAt` replicate, so
  trashing on one device hides it on all. **Tombstones = real deletes** only at purge:
  CKSyncEngine surfaces `deletedRecordZoneChanges`, and the local handler deletes the matching
  rows (+ local media files). Append-only `TranscriptRevision`s never conflict (unique
  recordName per edit); `Entry`/`Enrichment` use last-writer-wins on the server change tag.
- **Sync metadata columns**: per-record `ckSystemFields BLOB` (archived `CKRecord` so we can
  reconstruct a record with its current change tag when pushing). A single-row-per-key
  `sync_state(key TEXT PRIMARY KEY, value BLOB)` table holds CKSyncEngine's serialized state
  (state serialization + pending changes). We do **not** hand-roll change tokens — the engine
  owns fetch/push cursors; `updatedAt` is the app-side dirty signal fed into pending changes.
- **Not synced**: `entry_search`, `entry_fts` (derived), `sync_state` (engine-local). **OPEN:**
  `journals.isActive` — recommend local-only (per-device capture convenience), so exclude it
  from the `Journal` record; sync everything else on the row.

Nothing in §1 blocks this: every table has a stable text id, media is content-addressed and
immutable, deletes are representable as either a status flip or a record delete, and the FTS
layer is disposable/rebuildable.

---

## 3. Open-format export package (v1 acceptance criterion)

Self-describing, checksummed, per-entry directories. CloudKit is transport; this folder is the
longevity story.

```
recountly-export-<ISO8601>/
  manifest.json
  journals.json
  entries/
    <entryId>/
      entry.json          # machine-authoritative record
      transcript.md       # canonical transcript (optional YAML frontmatter: title, spokenAt)
      audio.m4a           # single continuous asset (the common case)
      audio/              # ONLY when the entry has >1 segment: 000.m4a, 001.m4a, …
      photos/
        <photoId>.jpg
```

`manifest.json`:
```json
{
  "format": "recountly-export",
  "schemaVersion": 1,
  "exportedAt": "2026-07-29T21:00:00Z",
  "source": "neon-export" | "native-app",
  "appVersion": "…",
  "counts": { "entries": 50, "journals": 3, "photos": 12, "audioFiles": 26 },
  "files": { "entries/<id>/audio.m4a": "sha256:…", "entries/<id>/transcript.md": "sha256:…", "…": "…" }
}
```
`files` is the verification anchor — a sha256 for **every** file in the package.

`journals.json`: array of `{ id, label, notes, kind, startedOn, endedOn, coverPhotoId, createdAt }`.

`entry.json` (exact fields):
```json
{
  "schemaVersion": 1,
  "id": "01J…" ,
  "spokenAt": "2026-07-20T18:04:00Z",
  "originalWrittenAt": "1998-06-01T12:00:00Z" | null,
  "writtenPrecision": "exact" | "day" | "month" | "year" | null,
  "effectiveAt": "1998-06-01T12:00:00Z",
  "durationSeconds": 62,
  "journalId": "01J…" | null,
  "pageLabel": "pp. 14–16" | null,
  "location": "home" | null,
  "status": "active" | "trashed",
  "trashedAt": null,
  "createdAt": "…",
  "updatedAt": "…",
  "title":   { "value": "…" | null, "source": "user" | "generated" | null },
  "notes":   "…" | null,
  "tags":    ["…"],
  "summary": "…" | null,
  "enrichment": { "model": "claude-haiku-4-5", "enrichedAt": "…", "title": "…", "summary": "…", "tags": ["…"] } | null,
  "transcript": {
    "file": "transcript.md",
    "sha256": "…",
    "source": "import" | "onDeviceSTT" | "cloudSTT" | "userEdit",
    "lastUserEditedAt": null,
    "lastGeneratedAt": null
  },
  "audio": [
    { "file": "audio.m4a", "segmentIndex": 0, "startTime": 0, "durationSeconds": 62,
      "mime": "audio/mp4", "bytes": 501234, "sha256": "…", "complete": true }
  ],
  "photos": [
    { "file": "photos/<id>.jpg", "id": "<id>", "mime": "image/jpeg", "bytes": 98765, "sha256": "…" }
  ],
  "legacy": { "webId": "imp_2024_JUL_28_08.46", "source": "neon-export-2026-07-29" } | null
}
```
`audio` is always an array (0..n). Migrated entries always have 0 or 1 element →
`entries/<id>/audio.m4a`. Multi-segment native entries use `entries/<id>/audio/NNN.m4a` and
list each. `title.source` records whether the effective title was user- or model-authored.

---

## 4. Migration plan — one-evening Node script in the web repo

New script `scripts/export-open-package.mjs` (dry-run by default; `--commit`/`--out <dir>` to
write), reusing the existing `@neondatabase/serverless` + `@vercel/blob` deps and the
`op inject` env. It produces **exactly** the §3 package; the native app's importer then reads
that package. Two independent artifacts, one format — the web side never needs to know about
SQLite/GRDB.

Steps:
1. `SELECT * FROM entries` (**no `deleted_at` filter** — export trashed too), `journals`,
   `photos`, `entry_moves`.
2. For each entry: download the private audio blob at `audio/<id>.<ext>` and each photo at
   `photos/<photoId>.<ext>` via `@vercel/blob` `get()`/`download`. Write files, compute sha256.
3. Emit `entry.json` / `transcript.md` / `journals.json` / `manifest.json` per §3.
4. **Verify** (below), print a summary (`N entries, M imp_, …`). (Live counts 2026-07-29: 36 entries, 22 imp_ — the earlier ~50/23 estimate was stale; several rows purged.)

### Column → field mapping

Web `entries` → native / entry.json:
- `id` → `id` **verbatim, incl. `imp_…`** (decision below) + `legacy.webId`.
- `recorded_at` → `spokenAt`.
- `written_at` → `originalWrittenAt` (+ `writtenPrecision`, see awkward mappings).
- `created_at` / `updated_at` → carried.
- `duration_seconds` → `durationSeconds` **and** the single `audio_assets` row's duration.
- `transcript` → `transcript.md` + a `transcript_revisions` row `source:"import"`, set canonical;
  `transcriptLastUserEditedAt`/`LastGeneratedAt` = null.
- `title` → **split by heuristic** (awkward, below): generated → `enrichment.title`; user → `userTitle`.
- `tags` → `enrichment.tags`.
- `summary` → `enrichment.summary`.
- `enriched_at` / `enrichment_model` → `enrichment.enrichedAt` / `enrichment.model`.
- `notes` → `entries.notes` (user).
- `location` → `entries.location`.
- `page_label` → `pageLabel`.
- `journal_id` → `journalId`.
- `audio_url`/`audio_mime`/`audio_bytes`/`audio_complete` → one `audio_assets` row
  (`segmentIndex 0`, `startTime 0`, `state:"finalized"`); `audio_url` (the proxy path) is
  dropped — the file itself is in the package. Null audio → no row / empty `audio[]`.
- `deleted_at` → `status` (`trashed` if set else `active`) + `trashedAt`.
- `transcript_tsv` → dropped (derived; native FTS rebuilds it).

Web `journals` → `kind`: `'archive'`→`paperArchive`, null→`contemporary`; `active`→`isActive`
(**OPEN:** may be dropped as local-only per §2); `started_on`/`ended_on`→`startedOn`/`endedOn`;
rest 1:1.

Web `photos` → 1:1; `entryId` kept, `journalId` always null (journal covers were never built —
`schema.sql` `photos` has no `journal_id`); compute `sha256`/`width`/`height` on export.

### Awkward mappings — decisions

- **ULIDs / `imp_` ids carry over verbatim** (recommended, taken here). Preserves idempotency
  (re-running import is a no-op on id), keeps photo/audio/revision references intact, and gives
  stable CloudKit record names. Downside: `imp_` ids aren't time-sortable base32 — irrelevant,
  since native sorts by `effectiveAt`/`spokenAt`, never by id.
- **Single audio + `audio_complete`** → one finalized `audio_asset` (`segmentIndex 0`). The
  multi-segment table is future-facing; migrated entries are trivially single-segment.
  `audioComplete` copied to the entry column as a display cue; `false` (web paused-then-resumed,
  last-segment-only) stays honest — we can't reconstruct the lost audio.
- **Web `title` is user-or-generated, unrecorded which.** Heuristic: if `enriched_at` is set,
  treat `title` as generated → `enrichment.title`, `title.source:"generated"`; if `title` is
  set but `enriched_at` is null, treat as a user edit → `userTitle`, `title.source:"user"`.
  Imperfect (an edited-then-enriched title reads as generated) but the only signal available.
- **`writtenPrecision`** — web has none. **OPEN:** default `"day"` for rows with a non-null
  `written_at` that came from the paper importer (all `imp_` rows have null `written_at` today,
  so in practice this is null across the board and the question is moot for this dataset).
- **`entry_moves` audit log — DROP from the native model; archive to
  `legacy/entry_moves.json`** in the export for provenance. No native feature or CloudKit record
  consumes it; keeping it would import a table with manual-FK-cleanup baggage for zero value.

### Verification

- Export side: after writing, re-read every file, recompute sha256, assert it matches
  `manifest.files`; assert counts (entries incl. all `imp_` rows — 22 as of 2026-07-29, don't hardcode, photo count, "N entries
  with audio" vs the DB's non-null `audio_url` count). Fail loudly on any mismatch.
- Import side: the native importer recomputes every sha256 against `manifest.files` before
  inserting (rejects a tampered/truncated package), inserts inside one transaction, rebuilds
  `entry_search`/FTS, then reports inserted counts back for a human eyeball against the export
  summary. Milestone-4 "delete app, reinstall, archive reconstructs from CloudKit" is the
  independent end-to-end check that the imported data round-trips through sync.

---

## 5. What Milestone 1 minimally needs (no migration debt)

**Decision: M1 ships the real `entries` + `audio_assets` tables (a subset of §1), not a
throwaway `captures` table.** A recording in flight is an `entries` row with
`status='capturing'`; each rotated/finalized segment is an `audio_assets` row. The recovery
scan is `SELECT … FROM entries WHERE status='capturing'`. This is why `status` includes
`'capturing'` and why `audio_assets` exists from day one — so M2–M5 add columns/tables via
additive GRDB migrations rather than migrating a temporary schema away.

M1 uses only:
- `entries`: `id`, `spokenAt`, `durationSeconds`, `status`, `createdAt`, `updatedAt`
  (everything else nullable/defaulted; `journalId` null, no transcript, no enrichment).
- `audio_assets`: full table (this is M1's core — indestructible segmented capture).
- `sync_state` / schema-version: the GRDB migrator's version bookkeeping only. No CloudKit,
  no FTS, no `entry_search`, no `journals` yet.

Crash-truth for in-flight segments lives in on-disk sidecar checkpoints (atomic
`.part`→final rename, per the plan's capture design); the DB row is updated on segment
finalize, so a mid-write crash loses at most the current unrotated segment, which the recovery
scan rebuilds from the sidecar. That's an M1 implementation detail, not a schema concern — the
schema above already accommodates it (`audio_assets.state='capturing'` for the unfinalized
tail).

---

## Open decisions (flagged, not silently chosen)

1. `journals.isActive` synced vs local-only — recommend local-only.
2. `writtenPrecision` default for migrated paper entries — recommend `"day"` (moot for the
   current dataset; all `imp_` rows have null `written_at`).
3. Web `title` user-vs-generated split heuristic (gated on `enriched_at`) — accept as best-effort.
4. `entry_moves` — recommend drop-from-model, archive to `legacy/entry_moves.json`.
5. Enrichment history — recommend single current row per entry (`entryId` PK); append-only
   history deferred.
6. User-editable tags — deferred; tags stay enrichment-owned for now (web parity).
7. Multi-segment audio export layout (`audio.m4a` vs `audio/NNN.m4a`) — spec supports both;
   migration only ever emits the single-file case.
