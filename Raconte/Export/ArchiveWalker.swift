import Foundation

/// Lists everything the archive exporter (T11) would copy byte-for-byte — pure
/// filesystem enumeration, no writes, no digests. Companion to `SyncTreeScanner`
/// (`Raconte/Sync/SyncTreeScanner.swift:77-130`), whose walk this copies the SHAPE of,
/// deliberately WITHOUT its exclusions: sync decides what is eligible to upload; export
/// is "everything a human's own archive holds." An unfinalized capture, a foreign
/// device's marker stream, and an unreadable sidecar are all things an owner archiving
/// their own data would want copied — each gets a warning recorded, never silence and
/// never exclusion.
///
/// Package layout (`docs/plans/2026-09-06-overnight-hardening-export-plan.md` "PR 4"):
///
///     journals.json
///     journals/<journalID>/cover.jpg
///     entries/<captureID>/
///       entry.json                    # captures/<id>/entry.json, byte copy even if unreadable
///       capture.json                  # captures/<id>/manifest.json, renamed ("manifest" is taken)
///       audio.m4a                     # captures/<id>/final/recording.m4a
///       revisions/canonical-<n>.json, revisions/draft.json
///       markers/markers.jsonl, markers/markers-<deviceID>.jsonl
///       live.jsonl                    # captures/<id>/transcript/live.jsonl
///       entry-log.jsonl
///       images/<id>.<ext>, images/<id>.json           # thumbnails skipped
///
/// Skipped on purpose (matches the plan's "Skipped on purpose" list): `segments/`
/// (deleted at finalize anyway), `transcript/head.json` (a cache), `images/thumbnails/`,
/// and anything outside `captures/`/`journals.json`/`journals/` entirely
/// (`trash-pending/`, `quarantine/`, `sync/`). Anything else this format doesn't
/// recognize — a stray `canonical-<n>.json.<uuid>.part` body nothing sweeps, a
/// directory under `images/` other than `thumbnails/`, a name a future app version
/// adds — is warned about and left out of the package; never copied, and never
/// silently dropped without a trace (Fix wave Finding 2).
/// A container root that doesn't exist (or isn't a directory) at all is a real failure —
/// collapsing it to the same empty `Listing` a legitimately-empty archive produces would
/// be silent data loss on an export path. A root that DOES exist but has no `captures/`
/// yet (fresh install, nothing captured) is legitimate and must not throw.
enum ArchiveWalkerError: Error, Equatable {
    case containerRootMissing(URL)
}

enum ArchiveWalker {
    struct Listing: Equatable, Sendable {
        /// Sorted by `relativePath`.
        var files: [ExportFile]
        /// Sorted. Every well-formed-ULID child of `captures/`, regardless of whether
        /// it has a manifest, audio, or anything else — a directory that exists is a
        /// capture that exists.
        var captureIDs: [String]
        var journalIDs: [String]
        /// "entries/<id>: no final audio", "entries/<id>: sidecar unreadable", …
        var warnings: [String]
    }

    /// Pure listing, no writes. Lists `journals.json`, covers, and every
    /// `captures/<ULID>/` directory's exportable files. A capture directory whose name
    /// is not a well-formed ULID is skipped with a warning — it could never be
    /// represented under `entries/<id>/` in the package at all, since the package uses
    /// the same id as the package-relative path component.
    static func list(containerRoot: URL) throws -> Listing {
        let fm = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: containerRoot.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue
        else {
            throw ArchiveWalkerError.containerRootMissing(containerRoot)
        }

        var files: [ExportFile] = []
        var warnings: [String] = []
        var journalIDs: [String] = []

        let journalsURL = AppContainer.journalsURL(containerRoot: containerRoot)
        if fm.fileExists(atPath: journalsURL.path) {
            files.append(ExportFile(source: journalsURL, relativePath: AppContainer.journalsFileName))
            if let data = try? Data(contentsOf: journalsURL),
               let registry = try? CaptureCoding.decoder().decode(JournalRegistry.self, from: data) {
                for journal in registry.journals {
                    journalIDs.append(journal.id)
                    let coverURL = AppContainer.journalCoverURL(containerRoot: containerRoot,
                                                                 journalID: journal.id)
                    if fm.fileExists(atPath: coverURL.path) {
                        let relativePath = "\(AppContainer.journalCoversDirectoryName)/\(journal.id)/"
                            + AppContainer.journalCoverFileName
                        files.append(ExportFile(source: coverURL, relativePath: relativePath))
                    }
                }
            } else {
                warnings.append("\(AppContainer.journalsFileName): unreadable")
            }
        }

        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let names = (try? fm.contentsOfDirectory(atPath: capturesRoot.path)) ?? []
        var captureIDs: [String] = []
        for name in names.sorted() {
            let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            else {
                // Non-directory children are ignored, not reported — matches
                // `SyncTreeScanner`'s existing convention.
                continue
            }
            guard ULID.isWellFormed(name) else {
                warnings.append("entries/\(name): capture id is not a well-formed ULID, skipped")
                continue
            }
            captureIDs.append(name)
            files += captureFiles(captureID: name, directory: directory, warnings: &warnings)
        }

        files.sort { $0.relativePath < $1.relativePath }
        return Listing(files: files, captureIDs: captureIDs, journalIDs: journalIDs, warnings: warnings)
    }

    // MARK: One capture directory

    private static func captureFiles(captureID: String, directory: URL,
                                     warnings: inout [String]) -> [ExportFile] {
        let fm = FileManager.default
        let base = "entries/\(captureID)"
        var files: [ExportFile] = []

        let manifestURL = SegmentLayout.manifestURL(captureDirectory: directory)
        if fm.fileExists(atPath: manifestURL.path) {
            files.append(ExportFile(source: manifestURL, relativePath: "\(base)/capture.json"))
        }

        let entryURL = SegmentLayout.entryMetadataURL(captureDirectory: directory)
        if fm.fileExists(atPath: entryURL.path) {
            files.append(ExportFile(source: entryURL,
                                    relativePath: "\(base)/\(SegmentLayout.entryMetadataFileName)"))
            do {
                _ = try EntryMetadataStore.read(url: entryURL)
            } catch {
                // Bytes are bytes — the file above is still copied. This only records
                // that the sidecar could not be read back as `EntryMetadata`.
                warnings.append("\(base): sidecar unreadable")
            }
        }

        let audioURL = SegmentLayout.finalRecordingURL(captureDirectory: directory)
        if fm.fileExists(atPath: audioURL.path) {
            files.append(ExportFile(source: audioURL, relativePath: "\(base)/audio.m4a"))
        } else {
            warnings.append("\(base): no final audio")
        }

        let entryLogURL = SegmentLayout.entryLogURL(captureDirectory: directory)
        if fm.fileExists(atPath: entryLogURL.path) {
            files.append(ExportFile(source: entryLogURL,
                                    relativePath: "\(base)/\(SegmentLayout.entryLogFileName)"))
        }

        files += transcriptFiles(base: base, directory: directory, warnings: &warnings)
        files += imageFiles(base: base, directory: directory, warnings: &warnings)
        warnings += topLevelUnrecognizedWarnings(base: base, directory: directory)

        return files
    }

    // MARK: Top-level capture directory — anything not one of the known files/
    // directories is unrecognized (Fix wave Finding 2). `segments/` is the one
    // documented skip at this level (deleted at finalize anyway); everything else
    // recognized here is handled by its own dedicated check above or by
    // `transcriptFiles`/`imageFiles` below.

    private static func topLevelUnrecognizedWarnings(base: String, directory: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        let recognizedFiles: Set<String> = [
            SegmentLayout.manifestFileName,
            SegmentLayout.entryMetadataFileName,
            SegmentLayout.entryLogFileName,
        ]
        let recognizedDirectories: Set<String> = [
            SegmentLayout.finalDirName,
            SegmentLayout.transcriptDirName,
            SegmentLayout.imagesDirName,
            SegmentLayout.segmentsDirName, // documented skip — deleted at finalize
        ]

        var warnings: [String] = []
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            let recognized = isDirectory.boolValue
                ? recognizedDirectories.contains(name)
                : recognizedFiles.contains(name)
            if !recognized {
                warnings.append("\(base): unrecognized file \(name), not exported")
            }
        }
        return warnings
    }

    // MARK: transcript/ — revisions + draft, markers (own AND foreign), live log

    private static func transcriptFiles(base: String, directory: URL,
                                        warnings: inout [String]) -> [ExportFile] {
        let fm = FileManager.default
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: directory)
        guard let names = try? fm.contentsOfDirectory(atPath: transcriptDir.path) else { return [] }

        var files: [ExportFile] = []
        for name in names.sorted() {
            let source = transcriptDir.appendingPathComponent(name)
            if SegmentLayout.canonicalRevision(fromFileName: name) != nil
                || name == SegmentLayout.transcriptDraftFileName {
                files.append(ExportFile(source: source, relativePath: "\(base)/revisions/\(name)"))
            } else if name == SegmentLayout.markerLogFileName
                || SegmentLayout.foreignStreamDeviceID(fromFileName: name) != nil {
                // Deliberately NOT excluding the foreign stream the way `SyncTreeScanner`
                // does — an export copies every device's marker log, own and foreign.
                files.append(ExportFile(source: source, relativePath: "\(base)/markers/\(name)"))
            } else if name == SegmentLayout.liveTranscriptFileName {
                files.append(ExportFile(source: source, relativePath: "\(base)/\(name)"))
            } else if name == SegmentLayout.transcriptHeadFileName {
                continue // documented skip — a cache, rebuildable from the revisions
            } else {
                // Anything else here — a stray `canonical-<n>.json.<uuid>.part` body
                // nothing sweeps, or a name a future app version adds — is warned
                // about, never silently dropped (Fix wave Finding 2).
                warnings.append("\(base): unrecognized file \(SegmentLayout.transcriptDirName)/\(name), not exported")
            }
        }
        return files
    }

    // MARK: images/ — originals + sidecars, never thumbnails/

    private static func imageFiles(base: String, directory: URL,
                                   warnings: inout [String]) -> [ExportFile] {
        let fm = FileManager.default
        let imagesDir = SegmentLayout.imagesDirectory(captureDirectory: directory)
        guard let names = try? fm.contentsOfDirectory(atPath: imagesDir.path) else { return [] }

        var files: [ExportFile] = []
        for name in names.sorted() {
            if name == SegmentLayout.imageThumbnailsDirName { continue } // documented skip

            let source = imagesDir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                // Fix wave Finding 8: a stray directory under `images/` (other than
                // `thumbnails/`) is not a file to list — it goes through the same
                // "unrecognized" warning as Finding 2, never silently listed as if it
                // were one exportable file.
                warnings.append("\(base): unrecognized file \(SegmentLayout.imagesDirName)/\(name), not exported")
                continue
            }
            files.append(ExportFile(source: source,
                                    relativePath: "\(base)/\(SegmentLayout.imagesDirName)/\(name)"))
        }
        return files
    }
}
