import Foundation
import CryptoKit

/// Walks the on-disk archive and reports every sync-eligible artifact plus a digest of
/// the content that artifact's record is built from (T3). Pure IO + digest computation —
/// no CloudKit, no bookkeeping comparison; `SyncPlanner` decides what to enqueue from
/// this output plus the upload ledger.
///
/// Eligibility (`docs/plans/2026-08-17-m4-sync-implementation-plan.md` "Locked
/// decisions"): a capture syncs only when its manifest reads cleanly AND reports a
/// verified final m4a (`final.verifiedAt` present), and the directory sits directly
/// under `captures/` — this scanner never looks inside `trash-pending/`, by
/// construction: it only lists `capturesRoot`'s own children, so a staged-for-removal
/// directory is structurally invisible to it. A trashed-but-not-purged entry
/// (`entry.json.trashedAt` set, directory still under `captures/`) IS eligible — trash
/// is a synced field, not a removal.
struct SyncTreeScanner {
    let containerRoot: URL
    let deviceID: String

    init(containerRoot: URL, deviceID: String) {
        self.containerRoot = containerRoot
        self.deviceID = deviceID
    }

    func scan() -> SyncScanResult {
        var skipped: [String] = []
        var artifacts = scanJournals(skipped: &skipped)
        artifacts += scanCaptures(skipped: &skipped)
        return SyncScanResult(artifacts: artifacts, skipped: skipped)
    }

    /// The state of ONE artifact, without walking the whole tree.
    ///
    /// Exists so the upload ledger can be written with the *same* digest formula the
    /// reconciliation scan will later compare against. A digest computed any other way
    /// would never match, and the next launch would re-enqueue a record that is already
    /// on the server — forever.
    ///
    /// Journals only for now; T6+ fill in the capture-side cases as their builders land.
    /// Nil means "nothing to digest" (absent, unreadable, or not built yet), and the
    /// caller's rule is to leave the ledger untouched — the safe direction, since a
    /// missing ledger entry costs one redundant upload while a wrong one costs a lost
    /// edit.
    func artifact(for name: SyncRecordName) -> SyncArtifactState? {
        switch name {
        case .journal(let id):
            var skipped: [String] = []
            return scanJournals(skipped: &skipped).first { $0.name == .journal(id: id) }
        case .entry, .audio, .revision, .liveLog, .markerStream:
            return nil
        }
    }

    // MARK: Journals

    private func scanJournals(skipped: inout [String]) -> [SyncArtifactState] {
        let fm = FileManager.default
        let registryURL = AppContainer.journalsURL(containerRoot: containerRoot)
        guard fm.fileExists(atPath: registryURL.path) else { return [] }
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? CaptureCoding.decoder().decode(JournalRegistry.self, from: data)
        else {
            skipped.append(AppContainer.journalsFileName)
            return []
        }
        return registry.journals.map(journalArtifact)
    }

    /// Digest definition (locked): sha256 of the journal's canonical single-journal
    /// JSON encoding (sorted-keys `lineEncoder`), plus — when a cover exists — the
    /// cover's OWN sha256 appended as a suffixed line, so a cover change alone flips
    /// this digest without the (potentially large, and irrelevant to "did the record
    /// change") image bytes ever being part of what `bytes` reports.
    private func journalArtifact(_ journal: Journal) -> SyncArtifactState {
        let coverURL = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: journal.id)
        var source = (try? CaptureCoding.lineEncoder().encode(journal)) ?? Data()
        if let coverData = try? Data(contentsOf: coverURL) {
            source.append(Data("\n".utf8))
            source.append(Data(Self.sha256Hex(coverData).utf8))
        }
        return SyncArtifactState(name: .journal(id: journal.id),
                                  sha256: Self.sha256Hex(source), bytes: source.count)
    }

    // MARK: Captures

    private func scanCaptures(skipped: inout [String]) -> [SyncArtifactState] {
        let fm = FileManager.default
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        guard let ids = try? fm.contentsOfDirectory(atPath: capturesRoot.path) else { return [] }

        var artifacts: [SyncArtifactState] = []
        for captureID in ids.sorted() {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // Non-directory children are ignored, not reported — matches
                // `DirectorySnapshot.gather`'s existing convention.
                continue
            }
            // A stray directory whose name isn't a well-formed ULID cannot be
            // represented as `.entry(captureID:)`/`.audio(captureID:)`/etc. at all —
            // `SyncRecordName` would refuse to parse a record built from it back.
            // Report it rather than silently minting an unparseable name.
            guard ULID.isWellFormed(captureID) else {
                skipped.append(captureID)
                continue
            }
            artifacts += scanCapture(captureID: captureID, directory: directory, skipped: &skipped)
        }
        return artifacts
    }

    private func scanCapture(captureID: String, directory: URL, skipped: inout [String]) -> [SyncArtifactState] {
        let fm = FileManager.default
        let manifestURL = SegmentLayout.manifestURL(captureDirectory: directory)
        guard fm.fileExists(atPath: manifestURL.path) else {
            // Not yet written — a capture directory created microseconds before its
            // first manifest write. Ordinary and expected, not a diagnostic failure
            // (same "absent is not an error" shape as `scanJournals`'s fileExists
            // pre-check).
            return []
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? CaptureCoding.decoder().decode(Manifest.self, from: manifestData)
        else {
            // Present but unreadable/undecodable — a real diagnostic failure. This is
            // capture-level (nothing about this capture can be trusted without a
            // manifest), so it gets the bare captureID: the one skip form that means
            // "the whole capture is excluded," never confused with a specific missing
            // artifact below (those are path-qualified).
            skipped.append(captureID)
            return []
        }
        // In-flight / not-yet-verified: excluded, not skipped — this is an ordinary,
        // expected, not-yet-eligible state, not a diagnostic-worthy failure.
        guard manifest.final.verifiedAt != nil else { return [] }

        var artifacts: [SyncArtifactState] = []

        if let entry = entryArtifact(captureID: captureID, directory: directory, manifestData: manifestData) {
            artifacts.append(entry)
        } else {
            // `entry.json` exists but could not be read — distinct from "absent"
            // (EntryMetadataStore.read's own rule: absent = defaults, unreadable
            // throws). Digesting a read failure as if the file were absent would make
            // a corrupt sidecar byte-identical to a genuinely unfiled entry and
            // silently enqueue it. No Entry artifact for this capture; everything
            // else (audio, transcript, markers) is independent and still scanned.
            skipped.append("\(captureID)/\(SegmentLayout.entryMetadataFileName)")
        }

        if let audioArtifact = audioArtifact(captureID: captureID, directory: directory) {
            artifacts.append(audioArtifact)
        } else {
            // `final.verifiedAt` is set but the m4a is gone or unreadable — worth
            // surfacing, but a DIFFERENT failure than an unreadable manifest, so it
            // gets its own path-qualified form (matching the revision case below)
            // rather than reusing the bare-captureID form that means "whole capture
            // excluded."
            skipped.append("\(captureID)/final/\(SegmentLayout.finalRecordingName)")
        }

        if let liveLog = liveLogArtifact(captureID: captureID, directory: directory) {
            artifacts.append(liveLog)
        }

        artifacts += scanRevisions(captureID: captureID, directory: directory, skipped: &skipped)

        if let markerStream = markerStreamArtifact(captureID: captureID, directory: directory) {
            artifacts.append(markerStream)
        }

        return artifacts
    }

    /// Digest definition (locked): sha256 of `entry.json` bytes + `manifest.json`
    /// bytes, concatenated in that order. An absent `entry.json` (the common case —
    /// every capture starts without one) contributes zero bytes, matching what "no
    /// entry.json" already means on disk: `EntryMetadata.defaults`, i.e. `{}`. An
    /// entry.json that EXISTS but can't be read returns nil (distinct from absent) —
    /// the caller reports that as a skip and omits the Entry artifact entirely, never
    /// silently treating a read failure as "no metadata."
    private func entryArtifact(captureID: String, directory: URL, manifestData: Data) -> SyncArtifactState? {
        let fm = FileManager.default
        let entryURL = SegmentLayout.entryMetadataURL(captureDirectory: directory)
        let entryData: Data
        if fm.fileExists(atPath: entryURL.path) {
            guard let data = try? Data(contentsOf: entryURL) else { return nil }
            entryData = data
        } else {
            entryData = Data()
        }
        let source = entryData + manifestData
        return SyncArtifactState(name: .entry(captureID: captureID),
                                  sha256: Self.sha256Hex(source), bytes: source.count)
    }

    /// Digest definition (locked): sha256 of the verified final m4a's bytes, verbatim.
    /// `.mappedIfSafe` avoids fully residentizing a multi-hour recording (can be
    /// 100+ MB) just to hash it — `SHA256.hash(data:)` streams over the mapped region
    /// the same way it would over an in-memory buffer, so the digest is unaffected.
    private func audioArtifact(captureID: String, directory: URL) -> SyncArtifactState? {
        let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: directory)
        guard let data = try? Data(contentsOf: m4aURL, options: .mappedIfSafe) else { return nil }
        return SyncArtifactState(name: .audio(captureID: captureID), sha256: Self.sha256Hex(data), bytes: data.count)
    }

    /// Digest definition (locked): sha256 of `live.jsonl` bytes, verbatim. Only when
    /// transcription actually produced one — three-answer honesty: a degraded capture
    /// with no live.jsonl pushes Entry + AudioAsset and simply has no LiveLog record,
    /// never a record over zero bytes standing in for "none".
    private func liveLogArtifact(captureID: String, directory: URL) -> SyncArtifactState? {
        let liveURL = SegmentLayout.liveTranscriptURL(captureDirectory: directory)
        guard let data = try? Data(contentsOf: liveURL, options: .mappedIfSafe) else { return nil }
        return SyncArtifactState(name: .liveLog(captureID: captureID), sha256: Self.sha256Hex(data), bytes: data.count)
    }

    /// Digest definition (locked): sha256 of THIS device's own `markers.jsonl` bytes
    /// only. Foreign streams (`markers-<deviceID>.jsonl`, materialized by a later
    /// task's ingest) are never read here — the exact filename this constructs is the
    /// only marker file this method ever touches, so a foreign stream sitting right
    /// beside it in `transcript/` is structurally invisible to this scan.
    private func markerStreamArtifact(captureID: String, directory: URL) -> SyncArtifactState? {
        let markerURL = SegmentLayout.markerLogURL(captureDirectory: directory)
        guard let data = try? Data(contentsOf: markerURL, options: .mappedIfSafe) else { return nil }
        return SyncArtifactState(name: .markerStream(captureID: captureID, deviceID: deviceID),
                                  sha256: Self.sha256Hex(data), bytes: data.count)
    }

    /// One artifact per readable `canonical-<n>.json`, keyed by the revision's OWN id
    /// (never its file number — file numbers are per-device and never synced, design §2
    /// note 1). Digest definition (locked): sha256 of the file's bytes, verbatim — the
    /// id used to name the record is read from those same bytes, never re-derived.
    private func scanRevisions(captureID: String, directory: URL, skipped: inout [String]) -> [SyncArtifactState] {
        let fm = FileManager.default
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: directory)
        guard let names = try? fm.contentsOfDirectory(atPath: transcriptDir.path) else { return [] }

        var artifacts: [SyncArtifactState] = []
        for name in names.sorted() {
            guard let revisionNumber = SegmentLayout.canonicalRevision(fromFileName: name) else { continue }
            let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: directory, revision: revisionNumber)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let revision = try? CaptureCoding.decoder().decode(TranscriptRevision.self, from: data)
            else {
                skipped.append("\(captureID)/\(name)")
                continue
            }
            artifacts.append(SyncArtifactState(name: .revision(id: revision.id),
                                                sha256: Self.sha256Hex(data), bytes: data.count))
        }
        return artifacts
    }

    // MARK: Digest

    /// Full lowercase-hex sha256 — the one hashing formula every digest definition
    /// above uses. Internal, not `private`, so tests compute the same expected values
    /// without duplicating the formula.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A tree scan's result: every sync-eligible artifact found, plus a diagnostic list of
/// what was skipped and why. Each string's SHAPE tells you what failed and how badly:
/// a bare captureID means the manifest itself was unreadable/undecodable — the whole
/// capture is excluded, nothing about it can be trusted; a captureID naming a stray
/// `captures/` child that isn't a well-formed ULID (its record name could never parse
/// back) is reported the same bare way, for the same reason — the whole thing is
/// unusable. Everything else is path-qualified to name exactly which artifact failed
/// while the rest of that capture still scanned normally:
/// `"<captureID>/entry.json"` (entry.json exists but is unreadable — no Entry
/// artifact), `"<captureID>/final/recording.m4a"` (verified but the file is gone or
/// unreadable — no AudioAsset artifact), `"<captureID>/<fileName>"` for an unreadable
/// revision file. `AppContainer.journalsFileName` names an unreadable registry. This is
/// Debug-screen diagnostics (T12), never a decision input to `SyncPlanner` — a skipped
/// item produces no artifact and is simply absent from `artifacts`, which is all the
/// planner ever sees.
struct SyncScanResult: Equatable, Sendable {
    var artifacts: [SyncArtifactState]
    var skipped: [String]
}
