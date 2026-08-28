/// Decision table for a `serverRecordChanged` rejection of a WRITE-ONCE record
/// (AudioAsset / LiveLog / Revision / Image — the four child builders that take no
/// `base:`). Root cause and agreed fix: docs/2026-08-26-sync-investigation-state.md,
/// RESOLVED section. Pure — same testable-table shape as `EnvironmentGate` and
/// `SaveFailureDisposition`.
///
/// The server copy handed back with a push rejection never has its asset downloaded
/// (`fileURL` nil), but its `sha256` FIELD is present, which is what makes this
/// decision possible without any network round trip.
enum WriteOnceConflictGate {

    enum Disposition: Equatable {
        /// The server already holds these exact bytes: credit the upload ledger with
        /// the LOCAL digest and retire the pending save — the upload is, in every
        /// observable sense, done.
        case settleAsUploaded(UploadedDigest)
        /// Anything else. A write-once record with a genuinely differing server copy
        /// is a state the design says cannot legitimately exist — surface it loudly,
        /// never overwrite blind.
        case divergent(reason: String)
    }

    /// The four record kinds whose builders mint fresh records with no `base:` —
    /// content is immutable after creation, so "the server moved" can only mean
    /// "the server already has it" or real trouble.
    static func isWriteOnce(_ name: SyncRecordName) -> Bool {
        switch name {
        case .audio, .liveLog, .revision, .image: return true
        case .journal, .entry, .markerStream: return false
        }
    }

    static func decide(serverSHA256: String?, local: UploadedDigest?) -> Disposition {
        guard let local else {
            return .divergent(reason: "local artifact unreadable — nothing to compare")
        }
        guard let serverSHA256, !serverSHA256.isEmpty else {
            return .divergent(reason: "server copy carries no sha256")
        }
        guard serverSHA256 == local.sha256 else {
            return .divergent(reason: "sha256 mismatch — server \(serverSHA256), local \(local.sha256)")
        }
        return .settleAsUploaded(local)
    }
}
