import Foundation

/// Writes an open-format export package: `ArchiveWalker.list` decides WHAT belongs in
/// it, this type WRITES it — byte-for-byte copies, one derived `transcript.md` per
/// entry, a sha256 for every file, and `raconte-export.json` written LAST so its mere
/// presence on disk tells `ArchiveVerifier` (T12) the copy actually finished.
///
/// Read-only against the source container: every file lands via `FileManager
/// .copyItem`, every read of the source tree goes through `EntryMetadataStore.read`
/// and `TranscriptRevisionStore.loadChain` — both `nonisolated static` READ paths —
/// and nothing is ever written back under `containerRoot`. All writes target the
/// `.part` staging directory under the caller-supplied `destination` instead.
struct ArchiveExporter: Sendable {
    let containerRoot: URL
    let appVersion: String
    let build: String
    let now: @Sendable () -> Date

    init(containerRoot: URL, appVersion: String, build: String,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.containerRoot = containerRoot
        self.appVersion = appVersion
        self.build = build
        self.now = now
    }

    struct Report: Equatable, Sendable {
        var packageURL: URL
        var counts: ExportManifest.Counts
        var warnings: [String]
    }

    /// Assembles `<destination>/Raconte-export-<stamp>.part/`, copies every listed file,
    /// writes `transcript.md` per entry, hashes every file, writes `raconte-export.json`
    /// LAST, then renames `.part` away. Throws on any I/O failure and removes the
    /// `.part` on every throw path — nothing is left half-written under `destination`.
    func export(into destination: URL) async throws -> Report {
        let listing = try ArchiveWalker.list(containerRoot: containerRoot)

        // Hoisted once (Fix wave Finding 4): the directory stamp and `exportedAt` must
        // name the SAME instant, not two separate `now()` calls that could straddle a
        // clock tick.
        let timestamp = now()
        let stamp = Self.stampFormatter().string(from: timestamp)
        let packageName = "Raconte-export-\(stamp)"
        let finalURL = destination.appendingPathComponent(packageName, isDirectory: true)
        let partURL = destination.appendingPathComponent("\(packageName).part", isDirectory: true)

        let fm = FileManager.default
        do {
            // Fix wave Finding 5: a `.part` staging directory can survive a prior crash
            // (the exporter's own cleanup only runs on a throw it catches itself, not on
            // e.g. the process being killed). Clear any stale one before staging fresh —
            // otherwise a leftover file from a previous aborted export rides along into
            // the finished package via the `moveItem` below.
            if fm.fileExists(atPath: partURL.path) {
                try fm.removeItem(at: partURL)
            }
            try fm.createDirectory(at: partURL, withIntermediateDirectories: true)

            var files: [String: FileDigest] = [:]
            var totalBytes = 0

            // MARK: Byte-for-byte copies from the walker's listing.
            for file in listing.files {
                let destinationURL = partURL.appendingPathComponent(file.relativePath)
                try fm.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: file.source, to: destinationURL)
                let digest = try Self.digest(of: destinationURL)
                files[file.relativePath] = digest
                totalBytes += digest.bytes
            }

            // MARK: One derived transcript.md per capture.
            var entries: [String: ExportManifest.EntrySummary] = [:]
            for captureID in listing.captureIDs {
                let (relativePath, digest, summary) = try writeTranscript(
                    captureID: captureID, into: partURL)
                files[relativePath] = digest
                totalBytes += digest.bytes
                entries[captureID] = summary
            }

            let manifest = ExportManifest(
                format: ExportManifest.format,
                schemaVersion: ExportManifest.schemaVersion,
                exportedAt: timestamp,
                appVersion: appVersion,
                build: build,
                counts: ExportManifest.Counts(
                    entries: listing.captureIDs.count,
                    journals: listing.journalIDs.count,
                    files: files.count,
                    bytes: totalBytes),
                entries: entries,
                files: files,
                warnings: listing.warnings)

            // Written LAST, via AtomicFile so a kill mid-write never leaves a half
            // written manifest — its presence is what tells the verifier the export
            // completed.
            let manifestData = try CaptureCoding.encoder().encode(manifest)
            try AtomicFile.replace(at: partURL.appendingPathComponent("raconte-export.json"),
                                   writing: manifestData)

            try fm.moveItem(at: partURL, to: finalURL)

            return Report(packageURL: finalURL, counts: manifest.counts, warnings: manifest.warnings)
        } catch {
            try? fm.removeItem(at: partURL)
            throw error
        }
    }

    // MARK: One entry's derived transcript.md

    private func writeTranscript(
        captureID: String, into partURL: URL
    ) throws -> (relativePath: String, digest: FileDigest, summary: ExportManifest.EntrySummary) {
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)

        let hasAudio = FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: directory).path)

        var journalID: String?
        var originalDate: String?
        var sidecarReadable = true
        do {
            let metadata = try EntryMetadataStore.read(
                url: SegmentLayout.entryMetadataURL(captureDirectory: directory))
            journalID = metadata.journalID
            originalDate = metadata.originalDate?.isoString
        } catch {
            sidecarReadable = false
        }

        let ordered = TranscriptRevisionStore.loadChain(captureDirectory: directory)?.revisions ?? []
        let current = TranscriptChain.current(ordered)

        let markdown = TranscriptMarkdown.render(
            captureID: captureID, journalID: journalID, originalDate: originalDate, revision: current)
        let relativePath = "entries/\(captureID)/transcript.md"
        let url = partURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = Data(markdown.utf8)
        try data.write(to: url)

        let summary = ExportManifest.EntrySummary(
            journalID: journalID,
            hasAudio: hasAudio,
            revisionCount: ordered.count,
            currentRevisionID: current?.id,
            transcriptCharacterCount: current.map { TranscriptChain.plainText($0).count } ?? 0,
            sidecarReadable: sidecarReadable)

        // Fix wave Finding 6: digest re-read from the just-written PACKAGE file, the
        // same `digest(of:)` every copied file goes through below — so
        // `docs/export-format.md`'s "re-reading the file back out of the package" is
        // universally true, not true for every file except this one.
        return (relativePath, try Self.digest(of: url), summary)
    }

    // MARK: Digest of a just-copied file (re-read from the PACKAGE, not the source —
    // this is the digest the package itself will be verified against later).

    private static func digest(of url: URL) throws -> FileDigest {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return FileDigest(sha256: SHA256Hex.of(data), bytes: data.count)
    }

    /// `yyyyMMdd-HHmmss`, always UTC — deterministic regardless of the host's local
    /// timezone, so two exports run back-to-back on different machines (or the same
    /// machine after a timezone change) still name packages the same way for the same
    /// injected instant. `en_US_POSIX` locale pins the numeral/format rules.
    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
