import Foundation

/// Pure derivation over an in-memory set of revisions (design §2.2–§2.3). No I/O, no
/// actor isolation — every function here is a value transform so the walks in §10 can
/// be pinned as plain unit tests with no filesystem involved.
///
/// The total order is `(createdAt, id)` and it is the ONLY order any caller may use —
/// `ordered` is where that rule lives, once.
enum TranscriptChain {

    /// The total order: `(createdAt, id)`, ascending. `id` (a ULID, lexicographically
    /// sortable) breaks a `createdAt` tie deterministically rather than leaving it to
    /// whatever order the caller happened to pass revisions in.
    static func ordered(_ revisions: [TranscriptRevision]) -> [TranscriptRevision] {
        revisions.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    /// The latest human-lineage revision in the total order, or nil if the chain has
    /// none. `RevisionSource.isHumanLineage` is the one lineage predicate (design §2.1)
    /// — an `.unknown` source never qualifies.
    static func humanTip(_ ordered: [TranscriptRevision]) -> TranscriptRevision? {
        ordered.last { $0.source.isHumanLineage }
    }

    /// Transitive closure over `parentID` and `basedOnMachineID`, walking *backward*
    /// from `revision` (its ancestors, never its descendants). Lookups are by id within
    /// `among`; an id that names no revision there — a gap left by a sync that hasn't
    /// pulled everything yet — simply stops the walk on that branch rather than
    /// erroring. `revision` itself is never included in its own ancestry.
    static func ancestry(of revision: TranscriptRevision,
                         among revisions: [TranscriptRevision]) -> Set<String> {
        var byID: [String: TranscriptRevision] = [:]
        byID.reserveCapacity(revisions.count)
        for candidate in revisions { byID[candidate.id] = candidate }

        var visited = Set<String>()
        var frontier: [String] = []
        if let parentID = revision.parentID { frontier.append(parentID) }
        if let basedOnMachineID = revision.basedOnMachineID { frontier.append(basedOnMachineID) }

        while let id = frontier.popLast() {
            guard !visited.contains(id) else { continue }
            visited.insert(id)
            guard let ancestor = byID[id] else { continue }
            if let parentID = ancestor.parentID { frontier.append(parentID) }
            if let basedOnMachineID = ancestor.basedOnMachineID { frontier.append(basedOnMachineID) }
        }
        return visited
    }

    /// A human revision is always attached (design §2.3). A machine revision is
    /// attached only if the chain's human tip is one of ITS ancestors — i.e. it sits
    /// underneath the human lineage, not off to the side of it. With no human tip at
    /// all, every revision is attached (nothing to be detached from yet).
    static func isAttached(_ revision: TranscriptRevision,
                           in ordered: [TranscriptRevision]) -> Bool {
        guard let tip = humanTip(ordered) else { return true }
        if revision.source.isHumanLineage { return true }
        return ancestry(of: revision, among: ordered).contains(tip.id)
    }

    /// The greatest attached revision by the total order — the chain's tip as far as
    /// this device's read is concerned. Detached revisions (stale machine output that
    /// isn't underneath the human edits) are never candidates.
    static func current(_ ordered: [TranscriptRevision]) -> TranscriptRevision? {
        ordered.last { isAttached($0, in: ordered) }
    }

    /// True when two human-lineage revisions exist with neither in the other's
    /// ancestry — concurrent edits that never converged (design §2.3, the A1 divergence
    /// walk). A single human lineage, however long, is never a fork.
    static func forkedHumanLineage(_ ordered: [TranscriptRevision]) -> Bool {
        let humans = ordered.filter { $0.source.isHumanLineage }
        guard humans.count > 1 else { return false }
        for i in 0..<humans.count {
            let ancestryOfI = ancestry(of: humans[i], among: ordered)
            for j in (i + 1)..<humans.count {
                let ancestryOfJ = ancestry(of: humans[j], among: ordered)
                if !ancestryOfJ.contains(humans[i].id) && !ancestryOfI.contains(humans[j].id) {
                    return true
                }
            }
        }
        return false
    }

    /// spans → display text, via `TranscriptText.join` (design §4.2 rule 8) — the one
    /// `plainText` rule.
    static func plainText(_ revision: TranscriptRevision) -> String {
        TranscriptText.join(revision.spans.map(\.text))
    }
}
