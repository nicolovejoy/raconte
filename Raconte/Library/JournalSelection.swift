import Foundation

/// The pure "which journal does capture file into" decision (M3 T3), split out of
/// `CaptureScreenModel` so the default-journal rule is testable without an actor hop.
///
/// Owner decision (M3 plan): first launch auto-creates one journal named "Journal" and
/// selects it; capture always files into the currently selected journal; there is no
/// "unfiled" state in any UI path. A stored selection that no longer resolves (T1's
/// dangling-id case — a deleted or not-yet-synced journal) falls back to an existing
/// journal rather than reintroducing "no journal selected".
enum JournalSelection {
    enum Outcome: Equatable {
        /// An id to select — either the stored preference (still valid) or, when it's
        /// missing or dangling, the first journal in the registry.
        case existing(String)
        /// The registry has no journals at all; the caller must mint the "Journal"
        /// default and select it. Not decided here because minting is a `JournalStore`
        /// write (id, timestamp) — this function stays synchronous and side-effect-free.
        case needsDefault
    }

    static func resolve(registry: JournalRegistry, storedID: String?) -> Outcome {
        if let storedID, registry.contains(id: storedID) {
            return .existing(storedID)
        }
        if let first = registry.journals.first {
            return .existing(first.id)
        }
        return .needsDefault
    }
}
