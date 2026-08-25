import Foundation

/// Mints a blank entry — a capture directory with no audio at all (image capture plan,
/// design doc "Entry existence with no audio": a photographed drawing with nothing
/// else). Deliberately NOT `SegmentStore`/`CaptureCoordinator`: those own the live audio
/// state machine (segments, rotation, interruption recovery) and are the wrong owner
/// for a manifest that is finalized from the instant it is written — there is no
/// recording session here to model.
///
/// Mirrors `EntryMetadataStore`'s split of a pure static seam (the manifest shape,
/// testable with no disk) plus a thin write side (directory + `AtomicFile.replace`,
/// the same primitive `SegmentStore`/`FinalizerWorker`/`RecoveryExecutor` all write
/// `manifest.json` through).
enum BlankEntryMinter {
    /// The format stamped into a blank entry's manifest. Meaningless for a capture with
    /// no audio — `LibraryScanner.durationSeconds` never reaches it, since
    /// `final.durationFrames == 0` short-circuits to `0` before the sample rate is used
    /// — but `Manifest.format` is non-optional, so a value has to be here. Matches the
    /// house default (`AudioFormatDescriptor` used across the manifest fixtures).
    static let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    /// A manifest that is already finalized: `state = .complete`,
    /// `final.verifiedAt = createdAt` (so `FinalizeArtifactPush.isFinalized` reads it as
    /// pushable the moment it lands on disk), `final.durationFrames = 0` (there is no
    /// audio to have a duration). Pure — no disk, so this is the thing
    /// `BlankEntryMinterTests` round-trips through `CaptureCoding` rather than comparing
    /// by struct equality, since `isFinalized` re-decodes from bytes.
    static func manifest(captureID: String, createdAt: Date) -> Manifest {
        Manifest(captureID: captureID,
                 createdAt: createdAt,
                 state: .complete,
                 stateSeq: 1,
                 stateUpdatedAt: createdAt,
                 format: format,
                 final: FinalRef(verifiedAt: createdAt, durationFrames: 0))
    }

    /// Creates `captures/<id>/` and writes the finalized manifest (plus `entry.json`
    /// when `journalID` is non-nil). Returns the new captureID, or `nil` on any write
    /// failure — directory creation or either manifest/sidecar write. Nothing is left
    /// half-written on the caller's behalf beyond what `AtomicFile.replace` already
    /// guarantees per-file: a manifest write failure after directory creation leaves an
    /// empty directory, which the library scan's `holdsSomethingToShow` gate already
    /// treats as `noDurableContent` and skips — the same fate as any other empty/failed
    /// capture directory, not a new failure mode.
    static func create(capturesRoot: URL, journalID: String?,
                       captureID: String = ULID.make(), now: Date = Date()) -> String? {
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifestData = try CaptureCoding.encoder().encode(manifest(captureID: captureID, createdAt: now))
            try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: directory),
                                   writing: manifestData)
            if let journalID {
                try EntryMetadataStore.write(EntryMetadata(journalID: journalID),
                                            url: SegmentLayout.entryMetadataURL(captureDirectory: directory))
            }
        } catch {
            return nil
        }
        return captureID
    }
}
