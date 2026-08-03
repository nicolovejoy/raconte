import Foundation

/// The 30-day rule, in one place (M3 decision: "delete anywhere, recoverable 30 days,
/// then truly gone").
///
/// Seconds, not `Calendar` components, on purpose: the sweep must reach the same answer
/// on a device whose time zone changed between the delete and the sweep, and "30 days"
/// here is a retention budget rather than a date on a calendar.
enum TrashPolicy {
    static let retentionDays = 30
    static let retentionSeconds = Double(retentionDays) * 86_400

    static func expiry(trashedAt: Date) -> Date {
        trashedAt.addingTimeInterval(retentionSeconds)
    }

    /// True once the budget is spent. `>=`, so an entry trashed exactly 30 days ago is
    /// gone rather than living one more sweep.
    static func isExpired(trashedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(trashedAt) >= retentionSeconds
    }

    /// Whole days the owner still has, rounded **up** and floored at 0: with 30 minutes
    /// left the honest answer is "today", not "0 days", and rounding down would show
    /// "0 days left" for most of the final day. Never negative — an expired entry the
    /// sweep has not reached yet reads as 0, not as a negative countdown.
    static func daysRemaining(trashedAt: Date, now: Date) -> Int {
        let remaining = expiry(trashedAt: trashedAt).timeIntervalSince(now)
        if remaining <= 0 { return 0 }
        return Int(ceil(remaining / 86_400))
    }
}

/// What a read of one capture's `entry.json` said — absent, unreadable, or a value.
///
/// Three answers rather than two, the same distinction §11 settled for the transcript
/// log and `EntryMetadataStore` already draws. The sweep is the one place in the app
/// that *destroys* data, so collapsing "we could not parse it" into either "not trashed"
/// (harmless, but then the file is never reconsidered) or "trashed" (deletes a recording
/// on the strength of a byte we could not read) is exactly the failure this type exists
/// to make unrepresentable.
enum SidecarState: Sendable, Equatable {
    case absent
    case unreadable
    case present(EntryMetadata)
}

/// One capture directory offered to the sweep.
struct TrashSweepCandidate: Sendable, Equatable {
    var captureID: String
    var sidecar: SidecarState
}

/// Why the sweep declined to delete a capture it *considered*.
///
/// Deliberately not recorded for a capture that simply isn't trashed: that is every
/// entry in the library on every launch, it is not a skip, and recording it would bury
/// the two answers that matter under the noise of the normal case.
enum TrashSweepSkip: Sendable, Equatable {
    /// Trashed, still inside the 30 days.
    case withinRetention(daysRemaining: Int)
    /// `entry.json` exists and did not parse. Nothing is written and nothing is
    /// deleted — an unreadable sidecar is neither "not trashed" nor "trashed".
    case metadataUnreadable
    /// Expired and the removal itself failed (permissions, a file held open). Recorded
    /// rather than retried: the next launch plans it again from the same sidecar.
    case deleteFailed(String)
}

/// A capture directory the sweep left alone, and why. `SkippedCapture`'s sibling —
/// a silent skip is how an entry stays deleted-but-present forever with nobody noticing.
struct SkippedSweep: Sendable, Equatable {
    var captureID: String
    var reason: TrashSweepSkip
}

/// One planned step. `RecoveryPlanner`'s shape: the decision is pure, the executor only
/// applies it.
enum TrashSweepAction: Sendable, Equatable {
    /// Permanently remove the whole capture directory — audio, manifest, transcript,
    /// sidecar. The one legitimate path in the app that deletes a finalized capture.
    case deleteCaptureDirectory(captureID: String)
    case skip(SkippedSweep)
}

struct TrashSweepResult: Sendable, Equatable {
    var deleted: [String] = []
    var skipped: [SkippedSweep] = []

    var isEmpty: Bool { deleted.isEmpty && skipped.isEmpty }
}

/// The pure sweep decision: `(candidates, now) -> [TrashSweepAction]`.
///
/// **How this composes with recovery's quarantine.** `holdsIrreplaceableArtifacts` guards
/// captures the *machine* might delete by mistake — a corrupt manifest must never cost a
/// finished recording. That rule is untouched here and the recovery planner is not
/// consulted: this sweep deletes only on the strength of a sidecar that read cleanly and
/// carries a `trashedAt` older than the retention budget, which is the owner's own
/// explicit instruction plus 30 days of grace. Nothing else in the app may delete a
/// directory holding an `.m4a` or a transcript.
enum TrashSweep {
    /// What the sweep concluded about one sidecar, before an id is attached to it.
    /// Split from `TrashSweepAction` so the rule is stated once, over the sidecar alone.
    enum Disposition: Sendable, Equatable {
        /// Not a candidate at all: no sidecar, or one that says the entry is live.
        /// The overwhelmingly common answer, and not a skip.
        case leaveAlone
        case delete
        case skip(TrashSweepSkip)
    }

    static func plan(_ candidates: [TrashSweepCandidate], now: Date) -> [TrashSweepAction] {
        candidates.compactMap { candidate in
            switch decide(candidate.sidecar, now: now) {
            case .leaveAlone:
                return nil
            case .delete:
                return .deleteCaptureDirectory(captureID: candidate.captureID)
            case .skip(let reason):
                return .skip(SkippedSweep(captureID: candidate.captureID, reason: reason))
            }
        }
    }

    static func decide(_ sidecar: SidecarState, now: Date) -> Disposition {
        switch sidecar {
        // An absent sidecar is an un-trashed entry (`EntryMetadata.defaults`), and the
        // sweep must never create one to say so.
        case .absent:
            return .leaveAlone
        case .unreadable:
            return .skip(.metadataUnreadable)
        case .present(let metadata):
            guard let trashedAt = metadata.trashedAt else { return .leaveAlone }
            if TrashPolicy.isExpired(trashedAt: trashedAt, now: now) { return .delete }
            return .skip(.withinRetention(
                daysRemaining: TrashPolicy.daysRemaining(trashedAt: trashedAt, now: now)))
        }
    }
}
