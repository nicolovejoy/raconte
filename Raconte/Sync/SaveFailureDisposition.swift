import CloudKit

/// What `CloudKitEngineControl.handleFailedSaves` does with one failed record save.
/// Decided from the `CKError.Code` alone so the table is unit-testable — the delegate
/// method takes `CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave`, which
/// nothing outside CloudKit can construct.
enum SaveFailureDisposition: Equatable, Sendable {
    /// `.serverRecordChanged` with the server's copy attached: design §4's per-field
    /// LWW merge through `CloudRecordExchange.resolvePushConflicts`, then re-enqueue.
    case mergeConflict
    /// `.unknownItem`: the server holds no record with this ID. Drop this device's
    /// archived server state (`CloudRecordExchange.resolveUnknownItem`) so the next
    /// push is a CREATE; re-enqueue only if there was state to drop.
    case recreate
    /// `.batchRequestFailed`: this record was fine — a sibling in the same atomic batch
    /// failed and took it down with it. Re-enqueue as-is, archived state untouched.
    case retry
    /// Anything else: log, surface as `lastError`, leave to the next reconciliation
    /// scan. `.zoneNotFound` sits here on purpose — the zone is re-saved on every
    /// `start()`, so a missing zone heals on the next launch without special handling.
    case drop

    static func decide(code: CKError.Code, hasServerRecord: Bool) -> SaveFailureDisposition {
        switch code {
        case .serverRecordChanged where hasServerRecord: return .mergeConflict
        case .unknownItem: return .recreate
        case .batchRequestFailed: return .retry
        default: return .drop
        }
    }
}
