/// #90: what `SyncCoordinator.launch()` does about the environment tag before the
/// engine resumes. Pure so the table is unit-tested cell by cell — this decision
/// deletes an owner's sync cache when it says wipe.
/// Design: docs/plans/2026-08-24-90-environment-tag-design.md §3.
enum EnvironmentGateAction: Equatable, Sendable {
    case proceed
    case writeTag
    case wipeAndWriteTag
}

enum EnvironmentGate {
    static func decide(tag: CloudKitEnvironment?, detected: CloudKitEnvironment,
                       bookkeepingExists: Bool) -> EnvironmentGateAction {
        if tag == detected { return .proceed }
        if tag == nil && !bookkeepingExists { return .writeTag }
        return .wipeAndWriteTag
    }
}
