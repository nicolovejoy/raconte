# Export package format

T13: "Export archive…" on About writes an open-format package to a folder the owner
picks, and immediately reads it back to prove it. This is the longevity story — CloudKit
is only transport (`docs/native-rebuild-plan.md`, `plans/2026-07-29-data-model-and-migration.md`
§3). The code is `Raconte/Export/` (`ArchiveWalker`, `ArchiveExporter`, `ArchiveVerifier`,
`ExportManifest`, `TranscriptMarkdown`); the About wiring is `ExportRunner` +
`AboutView`'s "Archive" section.

## Package layout

```
Raconte-export-<yyyyMMdd-HHmmss>/
  raconte-export.json           manifest, written LAST
  journals.json                 the journals registry, byte copy
  journals/<journalID>/cover.jpg
  entries/<captureID>/
    entry.json                  captures/<id>/entry.json — byte copy, even if unreadable
    capture.json                captures/<id>/manifest.json, renamed ("manifest" is taken)
    audio.m4a                   captures/<id>/final/recording.m4a
    entry-log.jsonl
    live.jsonl                  captures/<id>/transcript/live.jsonl, if present
    transcript.md                DERIVED — see below
    revisions/canonical-<n>.json, revisions/draft.json
    markers/markers.jsonl, markers/markers-<deviceID>.jsonl   own AND foreign devices
    images/<id>.<ext>, images/<id>.json         (thumbnails skipped)
```

The stamp in the package's own directory name is UTC, always, regardless of the host
machine's timezone — two exports run back to back name packages deterministically for
the same injected instant.

## Every file is a byte copy, except two

Every file under the package **except `transcript.md` and `raconte-export.json`** is an
exact byte-for-byte copy (`FileManager.copyItem`) of the file that already lives under the
app's container — no reformatting, no re-encoding, nothing normalized. A corrupt or
unreadable sidecar is still copied as-is; the exporter records a warning, never silence,
and never exclusion (an owner archiving their own data wants everything that exists, not
a curated subset).

`transcript.md` is the one derived, human-readable file: one per entry, rendered fresh
from that entry's current transcript revision by `TranscriptMarkdown.render` — a small
YAML-ish frontmatter block (`captureID`, `revisionID`, `source`, `createdAt`, `journalID`,
`originalDate`) followed by a blank line and the revision's plain text.

`raconte-export.json` is the manifest — see below — built from what the exporter itself
just wrote, not copied from anywhere.

## The manifest — `raconte-export.json`

Written **last**, after every other file is on disk and hashed. Its mere presence is what
tells `ArchiveVerifier` the export actually finished; a killed-mid-write export never
produces one; the exporter builds the whole package under a `.part` staging directory and
only renames it into place once the manifest write succeeds, removing the `.part` on any
throw.

Fields (`ExportManifest`):
- `format` / `schemaVersion` — `"raconte-export"` / `1`, for a future reader to
  recognize the package shape before parsing further.
- `exportedAt`, `appVersion`, `build` — provenance: which build of the app wrote this,
  and when.
- `counts` — `entries`, `journals`, `files`, `bytes`, for a quick sanity read without
  parsing the rest.
- `entries` — keyed by captureID: `journalID`, `hasAudio`, `revisionCount`,
  `currentRevisionID`, `transcriptCharacterCount`, `sidecarReadable`.
- `files` — every package-relative path except the manifest itself, mapped to a
  `FileDigest` (`sha256`, `bytes`) computed by **re-reading the file back out of the
  package** after the copy, not from the source — the digest a later reader will be
  checked against is the package's own bytes, not a claim about the source container.
- `warnings` — from the walk: an entry with no final audio, an unreadable sidecar, a
  capture directory whose name isn't a well-formed ULID, an unreadable `journals.json`,
  an unrecognized file the walker left out of the package.

## Skipped on purpose

`segments/` (deleted at finalize anyway, nothing left to copy), `transcript/head.json`
(a cache, rebuildable from the revisions), `images/thumbnails/` (regenerable from the
originals), and anything outside `captures/` / `journals.json` / `journals/` entirely:
`trash-pending/`, `quarantine/`, `sync/`. None of these are the owner's data — they are
either derived caches or the app's own bookkeeping.

Anything else the walker doesn't recognize — inside a capture directory, `transcript/`,
or `images/` — is also left out, but never silently: it appends a warning naming the
file (`"entries/<id>: unrecognized file <relative name>, not exported"`) instead. This
is how a stray `canonical-<n>.json.<uuid>.part` body (nothing sweeps those today) or a
file shape a future app version adds gets surfaced rather than vanishing unremarked.

## Verification semantics

`ArchiveVerifier.verify(packageURL:)` proves a package **against itself** — the manifest
it shipped, and the `revisions/` files inside the package. It never touches the source
container, on purpose: it has to still work years later, off a USB stick, with nothing
else around. It never writes anything under `packageURL` either.

Six problem shapes, kept distinct rather than collapsed into one another:
- `manifestUnreadable` — `raconte-export.json` is missing or won't parse. Short-circuits
  everything else; without a manifest there is nothing to check the package against.
- `missingFile` — the manifest names a file that isn't on disk, or is on disk but can't
  be read back (same practical failure: the content the manifest promised isn't
  recoverable).
- `checksumMismatch` — the file is right there and reads fine, but its bytes don't match
  the digest the manifest recorded.
- `unlistedFile` — present on disk, absent from the manifest.
- `transcriptMismatch` — the shipped `transcript.md`'s body doesn't match what
  rebuilding that entry's chain **from the package's own `revisions/` files** produces.
  This is the one check that isn't pure file-presence: it re-derives the transcript the
  same way the exporter did and compares.
- `countMismatch` — the manifest's entry count doesn't match the number of capture-id
  directories the package's own file listing actually contains right now (a directory
  someone deleted after export drops out of this count, independent of what the
  manifest still claims).

A `Report` is `ok` exactly when its `problems` list is empty; `checkedFiles` is the
manifest's own file count, for a quick "did it check what I expected" sanity read.

## Verifying a package by hand

No app is required to re-check a package's checksums — the manifest is plain JSON, and
`jq`+`shasum` on any Unix machine reproduces exactly what `ArchiveVerifier` does for the
file-level checks. Run this from inside the package directory itself:

```
jq -r '.files | to_entries[] | "\(.value.sha256)  \(.key)"' raconte-export.json | shasum -a 256 -c
```

Every line should read `OK`; a line reading `FAILED` names a file whose bytes no longer
match what the manifest recorded. To spot a file that exists on disk but isn't in the
manifest at all (an `.unlistedFile`, in the app's own terms), compare a plain file
listing against the manifest's own key list:

```
find . -type f | sort
jq -r '.files | keys[]' raconte-export.json | sort
```

Anything in the first list but not the second (besides `raconte-export.json` itself,
which is never listed) is unlisted.

These checksums detect **rot and truncation, not tampering** — anyone who edits a file
can simply regenerate the manifest to match, so a checksum match proves the package
hasn't silently decayed, not that its contents are what the app originally wrote.

## What a smoke of this looks like

About → Archive → "Export archive…" → pick a folder → the row under the button reads
`Exported N entries to <folder name> — verified` once both steps finish. Opening that
folder, `entries/<captureID>/transcript.md` reads as that entry's transcript with a
plain-text frontmatter block above it.
