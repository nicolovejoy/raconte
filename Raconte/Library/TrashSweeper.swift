import Foundation

/// Applies `TrashSweep` to the real filesystem (M3 T5).
///
/// `LibraryScanner`'s split, and `RecoveryExecutor`'s: the decision is pure and lives in
/// `TrashSweep`; this type only gathers sidecar states and removes directories.
///
/// **Isolation:** no mutable state and not `@MainActor`, so `run()` is a `nonisolated`
/// `async` method on the cooperative pool. It is called after the library's first scan
/// has already published, so a launch never waits on it.
///
/// **What it may delete.** The whole capture directory, and only when that capture's
/// `entry.json` read *cleanly* and carries a `trashedAt` older than
/// `TrashPolicy.retentionDays`. Nothing about the manifest, the segments, the `.m4a` or
/// the transcript enters the decision, in either direction: recovery's
/// `holdsIrreplaceableArtifacts` protects captures the *machine* might delete by mistake,
/// and is untouched here; this is the one path where the owner asked, thirty days ago,
/// for exactly this.
struct TrashSweeper: Sendable {
    let capturesRoot: URL
    let containerRoot: URL
    /// Injected so the retention boundary is testable without waiting a month.
    var now: @Sendable () -> Date = { Date() }

    init(capturesRoot: URL, containerRoot: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capturesRoot = capturesRoot
        self.containerRoot = containerRoot ?? AppContainer.containerRoot(capturesRoot: capturesRoot)
        self.now = now
    }

    /// `onDeleted` (M4 T11): fired once per capture this sweep actually stages,
    /// carrying that capture's own `SyncRecordFamily` gathered BEFORE the stage runs —
    /// the only point it is still enumerable. `nil` in every pre-M4 caller and every
    /// test that doesn't care (sync off, or a fixture never wired one) — a sweep
    /// behaves exactly as it always did without it. `@Sendable` because this whole
    /// call runs inside `Task.detached`.
    func run(onDeleted: (@Sendable (String, [SyncRecordName]) async -> Void)? = nil) async -> TrashSweepResult {
        let capturesRoot = self.capturesRoot
        let containerRoot = self.containerRoot
        let now = self.now
        return await Task.detached(priority: .utility) {
            let remover = StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)
            let candidates = Self.gather(capturesRoot: capturesRoot)
            var result = await Self.apply(TrashSweep.plan(candidates, now: now()), remover: remover,
                                          capturesRoot: capturesRoot, onDeleted: onDeleted)
            // The launch-time safety net (owner answer 3): purge whatever this run just
            // staged, plus anything a previous launch staged and never got to reclaim.
            result.pendingRemovalFailures = remover.purge().failed
            return result
        }.value
    }

    // MARK: - Gather

    /// One candidate per child directory of `captures/`, each carrying the three-way
    /// answer its `entry.json` gave. Existence is checked before the read so `absent` is
    /// a real answer rather than the `defaults` `EntryMetadataStore.read` returns for it —
    /// the sweep reports what it saw, and "there was no sidecar" and "there was one and
    /// it said nothing" are different observations even though they decide the same way.
    static func gather(capturesRoot: URL) -> [TrashSweepCandidate] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: capturesRoot.path) else { return [] }
        return ids.sorted().compactMap { id -> TrashSweepCandidate? in
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return TrashSweepCandidate(captureID: id, sidecar: sidecarState(captureDirectory: dir))
        }
    }

    static func sidecarState(captureDirectory: URL) -> SidecarState {
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            return .present(try EntryMetadataStore.read(url: url))
        } catch {
            return .unreadable
        }
    }

    // MARK: - Apply

    /// `deleted` is staged (#25), not necessarily unlinked yet — from the library's point
    /// of view the entry is gone the moment the rename lands, and `run()`'s trailing
    /// `purge()` only reclaims the bytes.
    ///
    /// M4 T11: `SyncRecordFamily.names` reads `id`'s own capture directory BEFORE
    /// `remover.stage` renames it away — the only point it is still enumerable — so
    /// `onDeleted` always carries a real family, never an empty one just because the
    /// directory was already gone by the time anyone asked.
    static func apply(_ actions: [TrashSweepAction], remover: StagedRemover, capturesRoot: URL,
                      onDeleted: (@Sendable (String, [SyncRecordName]) async -> Void)?) async -> TrashSweepResult {
        var result = TrashSweepResult()
        for action in actions {
            switch action {
            case .skip(let skipped):
                result.skipped.append(skipped)
            case .deleteCaptureDirectory(let id):
                let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
                let family = SyncRecordFamily.names(captureID: id, captureDirectory: directory)
                do {
                    _ = try remover.stage(captureID: id)
                    result.deleted.append(id)
                    await onDeleted?(id, family)
                } catch {
                    result.skipped.append(SkippedSweep(
                        captureID: id, reason: .deleteFailed(String(describing: error))))
                }
            }
        }
        return result
    }
}
