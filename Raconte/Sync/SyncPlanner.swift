import Foundation

/// Reconciles a tree scan against the upload ledger (T3) — pure, no IO. Decides what
/// needs to go up, `SyncTreeScanner` decides what's actually on disk, and
/// `SyncBookkeepingStore` owns what was last durably uploaded; this is the diff of the
/// two.
enum SyncPlanner {
    /// Enqueues exactly (new artifacts) ∪ (digest-changed artifacts).
    ///
    /// Iterates `scan`, never `ledger` — a ledger entry with no surviving artifact in
    /// `scan` is never visited here and produces nothing. That is deliberate, not an
    /// oversight: deletes are Task 11's explicit, CloudKit-delete path, never inferred
    /// from an artifact's absence from a scan. A scan racing against an in-flight
    /// staged removal (`StagedRemover.stage`, #25) could observe a capture mid-move —
    /// briefly absent from `captures/` on its way to `trash-pending/` — and inferring a
    /// delete from that would sync-delete an entry that was never actually deleted.
    static func reconcile(scan: [SyncArtifactState], ledger: [String: UploadedDigest]) -> [SyncRecordName] {
        var toEnqueue: [SyncRecordName] = []
        for artifact in scan {
            guard let uploaded = ledger[artifact.name.rawValue] else {
                // Never uploaded — new.
                toEnqueue.append(artifact.name)
                continue
            }
            // Changed: compare BOTH sha256 and bytes. Comparing only `bytes` would miss
            // same-size-different-content edits (the mutation this task's check names).
            if uploaded.sha256 != artifact.sha256 || uploaded.bytes != artifact.bytes {
                toEnqueue.append(artifact.name)
            }
        }
        return toEnqueue
    }
}
