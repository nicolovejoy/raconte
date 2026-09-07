import Foundation

/// The self-heal for #91: a child record (Audio/LiveLog/MarkerStream/Revision/Image)
/// that comes back `CKError.unknownItem` with NO archived server state is not stale
/// metadata — `resolveUnknownItem` correctly reports `false` and there is nothing to
/// drop. But if the reason the server has never heard of it is that its parent Entry
/// was ALSO just recreated (its own `.recreate` disposition, resent in this SAME
/// failure event), the child does not have to wait for a launch-only reconciliation
/// scan — the parent will exist by the time this batch lands, so the child can go out
/// right behind it.
///
/// Pure: no CloudKit type, no I/O. `CloudKitEngineControl.handleFailedSaves` is private
/// on a class the test suite never constructs (`SyncCoordinatorTests.swift` explains
/// why), so this decision is pulled out here — the same extraction pattern
/// `SaveFailureDisposition` already follows.
enum UnknownItemResend {
    /// One `.recreate`-disposed failure, as `handleFailedSaves` saw it.
    struct Outcome: Equatable, Sendable {
        var name: SyncRecordName
        /// What `resolveUnknownItem(for:)` returned for `name`.
        var hadServerState: Bool
        /// `name.parentEntry` for the four captureID-bearing shapes; for `.revision`,
        /// the Entry named by the failed record's `entryRef` field. Nil when there is
        /// no parent to check (an Entry or Journal failure) or it could not be read.
        var parent: SyncRecordName?
    }

    /// Names to resend, parents before children. A name with `hadServerState` is
    /// resent outright (the ordinary recreate-as-a-create case). A child with no
    /// archived state is resent iff its parent Entry is ALSO being resent in this same
    /// event — checked against the first-pass set, so a parent that itself had no
    /// server state does not carry its child along.
    static func plan(_ outcomes: [Outcome]) -> [SyncRecordName] {
        let resentParents = outcomes.filter(\.hadServerState).map(\.name)
        let resentParentSet = Set(resentParents)
        let resentChildren = outcomes
            .filter { !$0.hadServerState }
            .filter { $0.parent.map(resentParentSet.contains) ?? false }
            .map(\.name)
        return resentParents + resentChildren
    }
}
