# recountly native rebuild — decision + plan of record (2026-07-29)

**Decision (owner):** full native rebuild, Option A. No hybrid bridge — the web app has not
been adopted in earnest, so there is no transition to protect. Two independent clean-room
designs (Claude + ChatGPT, prompted from `scratchpad` problem statement, no implementation
context) converged on every load-bearing choice; that convergence is the basis of this plan.

## Architecture (converged)

- **SwiftUI universal app** (iOS 26 + macOS 26, true multiplatform target, not Catalyst).
  One codebase; platform-specific capture/reading surfaces where it matters.
- **Audio is ground truth; transcript is a derived, replaceable interpretation.** This is
  the spine. Everything the web version fought (#23/#52/#54/#69) becomes "re-derive text
  from the file on disk."
- **Capture:** AVAudioSession (background-audio mode, `.playAndRecord`) + AVAudioEngine
  tap → append-only audio segments written to disk continuously (segment rotation
  ~15–30s, sidecar checkpoints, atomic `.part`→final rename). Persistent capture state
  machine (idle→preparing→recording→interrupted→resuming→stopping→captured→finalizing→
  complete); interruptions (calls, route changes) are normal states; every launch runs a
  recovery scan — "Recovered recording: 18m42s" is a feature, not an error. Finalize to
  mono AAC-LC ~64–96kbps in a background worker; keep raw segments until verified.
- **Live transcription: on-device** SpeechAnalyzer/SpeechTranscriber (iOS 26 API —
  volatile + finalized streaming, time-indexed, no network). Cloud transcription only as
  an optional post-hoc second pass presented as a diff. Never in the capture path.
- **Transcript layers:** volatile hypothesis (UI-only) → committed capture segments
  (persisted incrementally with audio time offsets) → canonical editable transcript with
  provenance timestamps (`lastUserEditedAt` vs `lastGeneratedAt`); retranscription never
  silently replaces user-touched text.
- **Storage: GRDB/SQLite** + files (audio, photos) in the app container. **FTS5** search
  (snippets/highlighting — feature parity with the web's match highlighting). Not SwiftData.
- **Sync: CKSyncEngine → CloudKit private database**, custom zone; media as immutable
  content-addressed CKAssets; tombstones for trash; append-only transcript revisions.
  Never sync the SQLite file itself. No server, no auth UI — iCloud identity + Face ID
  app lock. Encourage Advanced Data Protection; no custom crypto.
- **Enrichment:** client-side Claude API call post-capture (user API key in Keychain,
  provider behind a protocol); generated fields stored separately from user fields —
  generation only fills untouched fields (field-level provenance, the mechanism the web
  version approximated with `coalesce`).
- **Export is a v1 acceptance criterion, not a later feature.** Open-format package
  (per-entry dirs: audio.m4a, transcript.md, entry.json, photos, manifest + checksums).
  CloudKit is transport, the export folder is the longevity story.

## Data model (validated by convergence — both clean rooms reinvented the web schema)

Entries (spokenAt vs originalWrittenAt + explicit date precision, title/notes/location,
status incl. trash), Journals (contemporary | paperArchive, date ranges), page labels as
free text, photo attachments, audio assets, transcript revisions, enrichment records.
Carry over the web app's semantic decisions: journals-as-folders, reading-order archive
views, effective-date sorting, page-label sticky suggestion, photos require spoken
descriptions (searchability), trash-only permanence.

## Explicitly NOT building (v1)

Server/backend of any kind; accounts/auth UI; web capture; cloud realtime STT; SwiftData+
auto-CloudKit as the archive core; custom crypto/key management; SHA-256-everything and
elaborate revision graphs (v2 if ever); verbal markup commands; semantic/vector search;
sharing infra (future: export one entry as static HTML).

## Milestones (build order is the risk management)

**Status (2026-08-11) — this list is the original plan of record and is not kept current
line-by-line; [docs/overview.md](overview.md) is.** M1 shipped. M2's live-transcript half
shipped; its "editable canonical transcript" half is the T6 revision-chain store (shipped,
PR #45 merged) plus the T7 editor built on top of it (branch `t7/editor-ui`, Gate B + PR
still pending — see overview.md §5). M3 shipped (journals/library/trash; FTS5 search still
pending, folded into M5 below rather than M3 as originally scoped). M4/M5 not started.

1. **Indestructible local capture** — capture screen, AVAudioEngine, background mode, PCM
   segments, state machine, restart recovery, playback. NO transcription, NO sync, NO
   folders. Paranoid test protocol: lock screen, switch apps, pull headphones, Bluetooth,
   accept/decline calls, force-quit, fill disk, airplane mode, kill at every state
   transition. **No iOS-26 dependency — can start immediately on current OS.**
2. **Live transcript + reconciliation** — SpeechTranscriber progressive text (iOS 26 beta
   now, GA ~Sept — timing self-resolves), segment timestamps, checkpoints,
   retranscription-from-audio, editable canonical transcript.
3. **Archive model + search** — journals, historical dates, pages, photos, trash, FTS5 +
   highlighting. **Data migration here:** one-evening script exporting Neon rows + private
   blobs (~50 entries incl. the 23 paper-archive imports) into the local store.
4. **CloudKit replication** — CKSyncEngine, immutable assets, conflict policy, tombstones.
   Done = delete app from a Mac, reinstall, full archive reconstructs from CloudKit.
5. **Reading polish + enrichment + export** — Mac three-pane reading, typography
   (Newsreader idea carries over), Claude enrichment, open-format export + verification.

## The web app / server during and after

- **recountly.org is FROZEN** — no new features, stays deployed as the reading surface for
  existing entries until Milestone 4 verification passes. Then: export everything (script),
  verify the export, retire Vercel project + Neon + Blob + domain routing per a teardown
  checklist (keep the domain).
- GitHub issues #33, #35-remainder, #36-remainder, #53, #63, #71 and the Node-22/24 bump +
  passkeys plans are **obsoleted or parked** by this pivot (#53/#71 solved structurally by
  the architecture). Leave open with a pointer comment until teardown; don't mass-close yet.
- The repo question (new repo vs. this one) + Xcode project/bundle-id naming = first
  decisions of the next session, before scaffolding.

## Next session (fresh context)

1. Decide repo/project naming; scaffold the Xcode project.
2. Detail the Milestone 1 design (segment format, state machine, recovery scan, test
   harness) via the usual plan → implement → review pipeline, sized for subagents.
3. Set up the paranoid-test checklist as the M1 smoke doc.
