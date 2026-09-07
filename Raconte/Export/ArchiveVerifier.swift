import Foundation

/// Reads a package written by `ArchiveExporter` (T11) back and proves it against ITS
/// OWN data — the manifest it shipped, and the `revisions/` files that live inside the
/// package itself. Never touches the source container: this has to work on a USB
/// stick years later, with nothing else around. Read-only against the package: no
/// file under `packageURL` is ever created, written, or deleted.
///
/// Three-answer honesty (never collapsed into one another):
/// - `.manifestUnreadable` — the manifest itself is present but couldn't be parsed;
///   an absent/corrupt manifest short-circuits everything else, since without it there
///   is nothing to check the package against.
/// - `.missingFile` — the manifest names a file the package doesn't have (or that
///   exists but can't be read back — same practical failure from a verifier's point of
///   view: the content the manifest promised is not recoverable).
/// - `.checksumMismatch` — the file is right there and reads fine, but its bytes don't
///   match the digest the manifest recorded.
/// `.unlistedFile` (present on disk, absent from the manifest) and
/// `.transcriptMismatch`/`.countMismatch` (derived checks, not raw file presence) are
/// the two further problem shapes the format needs beyond that triad.
enum ArchiveVerifier {
    enum Problem: Equatable, Sendable {
        case manifestUnreadable(String)
        case missingFile(String)
        case checksumMismatch(String)
        case unlistedFile(String)
        case transcriptMismatch(captureID: String)
        case countMismatch(field: String, manifest: Int, found: Int)
    }

    struct Report: Equatable, Sendable {
        var checkedFiles: Int
        var problems: [Problem]
        var ok: Bool { problems.isEmpty }
    }

    private static let manifestFileName = "raconte-export.json"

    static func verify(packageURL: URL) -> Report {
        let manifestURL = packageURL.appendingPathComponent(manifestFileName)
        let manifest: ExportManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try CaptureCoding.decoder().decode(ExportManifest.self, from: data)
        } catch {
            return Report(checkedFiles: 0,
                          problems: [.manifestUnreadable("\(manifestFileName): \(error)")])
        }

        let onDiskPaths = onDiskRelativePaths(under: packageURL, excluding: manifestFileName)

        // MARK: File-level problems. One merged, sorted walk over the union of every
        // path the manifest names and every path actually on disk, so missingFile /
        // checksumMismatch / unlistedFile interleave in path order rather than being
        // grouped by kind — "manifest walk order, sorted by path".
        var fileProblems: [Problem] = []
        for path in Set(manifest.files.keys).union(onDiskPaths).sorted() {
            switch (manifest.files[path], onDiskPaths.contains(path)) {
            case (.some, false):
                fileProblems.append(.missingFile(path))
            case (.none, true):
                fileProblems.append(.unlistedFile(path))
            case let (.some(digest), true):
                guard let data = try? Data(contentsOf: packageURL.appendingPathComponent(path),
                                           options: .mappedIfSafe)
                else {
                    // Present in the listing but couldn't actually be read back — the
                    // manifest's promised content is not recoverable, same as absent.
                    fileProblems.append(.missingFile(path))
                    continue
                }
                if SHA256Hex.of(data) != digest.sha256 {
                    fileProblems.append(.checksumMismatch(path))
                }
            case (.none, false):
                continue // unreachable: `path` came from the union of the two sets.
            }
        }

        // MARK: Transcript-level problems. Rebuild each entry's chain from the
        // PACKAGE's own `revisions/` files (never the source container) and compare its
        // plain text to the shipped `transcript.md`'s body. Skipped for an entry whose
        // `transcript.md` is itself missing/unreadable — already reported above, and
        // there is nothing on disk left to compare against.
        var transcriptProblems: [Problem] = []
        for captureID in manifest.entries.keys.sorted() {
            let relativePath = "entries/\(captureID)/transcript.md"
            guard onDiskPaths.contains(relativePath),
                  let document = try? String(
                    contentsOf: packageURL.appendingPathComponent(relativePath), encoding: .utf8)
            else { continue }

            let rebuilt = rebuiltPlainText(captureID: captureID, packageURL: packageURL)
            if rebuilt != TranscriptMarkdown.body(of: document) {
                transcriptProblems.append(.transcriptMismatch(captureID: captureID))
            }
        }

        // MARK: Count-level problems. `entries` is recomputed from which capture ids
        // actually still have at least one file on disk under `entries/<id>/` —
        // independent of the manifest's own entry list, which a deleted directory
        // leaves untouched.
        var countProblems: [Problem] = []
        let entriesFound = entryDirectoryIDs(in: onDiskPaths).count
        if manifest.counts.entries != entriesFound {
            countProblems.append(.countMismatch(field: "entries",
                                                manifest: manifest.counts.entries,
                                                found: entriesFound))
        }

        return Report(checkedFiles: manifest.files.count,
                      problems: fileProblems + transcriptProblems + countProblems)
    }

    // MARK: Package-relative file listing (excludes the manifest itself).

    private static func onDiskRelativePaths(under packageURL: URL, excluding manifestFileName: String) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        let prefix = packageURL.path + "/"
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            var relative = url.path
            if relative.hasPrefix(prefix) { relative.removeFirst(prefix.count) }
            guard relative != manifestFileName else { continue }
            paths.insert(relative)
        }
        return paths
    }

    /// Distinct capture ids that still own at least one on-disk file under
    /// `entries/<id>/…`. A capture whose whole directory was deleted contributes no
    /// path here at all, dropping it from the count.
    private static func entryDirectoryIDs(in onDiskPaths: Set<String>) -> Set<String> {
        let prefix = "entries/"
        var ids: Set<String> = []
        for path in onDiskPaths where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                ids.insert(String(rest[rest.startIndex..<slash]))
            }
        }
        return ids
    }

    // MARK: Rebuilding one entry's transcript from the package's OWN `revisions/`.

    /// `draft.json` is not a revision — `SegmentLayout.canonicalRevision(fromFileName:)`
    /// already excludes it, same predicate `ArchiveWalker` used to decide what belongs
    /// under `revisions/` in the first place. A revision file that fails to decode is
    /// silently excluded from the rebuilt chain (no revision-specific "unreadable"
    /// problem exists in this format — its bytes, if they differ from what the
    /// manifest recorded, are already caught above as a `.checksumMismatch` on that
    /// path).
    private static func rebuiltPlainText(captureID: String, packageURL: URL) -> String {
        let revisionsDir = packageURL.appendingPathComponent("entries/\(captureID)/revisions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: revisionsDir.path)) ?? []

        let decoder = CaptureCoding.decoder()
        var revisions: [TranscriptRevision] = []
        for name in names.sorted() {
            guard SegmentLayout.canonicalRevision(fromFileName: name) != nil else { continue }
            guard let data = try? Data(contentsOf: revisionsDir.appendingPathComponent(name)),
                  let revision = try? decoder.decode(TranscriptRevision.self, from: data)
            else { continue }
            revisions.append(revision)
        }

        let ordered = TranscriptChain.ordered(revisions)
        guard let current = TranscriptChain.current(ordered) else { return "" }
        return TranscriptChain.plainText(current)
    }
}
