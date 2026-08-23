import Foundation

/// Pure read-side merge of every device's marker stream for one capture into ONE
/// virtual log (M4 T10, design §4/§7.4): "marker streams are structurally conflict-free
/// (one writer per record). All merging is read-side and deterministic: union all
/// streams; corrections ordered by `at`, tie-break deviceID; later wins at the same
/// boundary; `retractsSeq` resolves within its own stream only."
///
/// No IO, no clock, no state — every device runs this SAME function over the SAME set
/// of streams (its own + every foreign one materialized by ingest) and must reach the
/// SAME answer, which is what makes the merge itself require no CloudKit-side
/// conflict resolution at all.
enum MarkerStreamMerge {
    /// One device's marker log, as `MarkerLogReader.load` (own stream) or
    /// `MarkerLogReader.load(url:)` (a foreign `markers-<deviceID>.jsonl`) already
    /// decoded it. `markers` carries each record's ORIGINAL `seq` — the value that
    /// device's own `MarkerLogWriter.nextSeq` assigned — untouched; `merge` is what
    /// renumbers into the merged total order.
    struct Stream: Equatable, Sendable {
        var deviceID: String
        var markers: [StructureMarker]
    }

    /// One record tagged with the stream it came from, carrying its PRE-merge seq —
    /// what `retractsSeq` remap has to look up against, since a target seq is only ever
    /// meaningful within the retracting record's own stream (a device can only write a
    /// `.correctionRetract` against a seq its own `MarkerLogWriter` assigned; it has no
    /// way to know a foreign device's numbering at write time — the whole reason cross-
    /// device correction ordering is a READ-time concern, never a write-time one).
    private struct Tagged {
        var deviceID: String
        var originalSeq: Int
        var marker: StructureMarker
    }

    /// Locked total order (implementation plan "Locked decisions"): sort key
    /// `(at ?? .distantPast, deviceID, seq)`. Unstamped legacy records (`at == nil`,
    /// every marker written before M4 T1) sort before every stamped one, matching
    /// design §7.1's own rule restated for the merge. Equal `at` → the ASCENDING
    /// deviceID sort places the lexicographically GREATER deviceID later — i.e. at a
    /// higher post-renumber seq — which is what makes it win under
    /// `MarkerCorrections.effectiveMarkers`' existing "later seq wins" precedence rule
    /// (that fold is unchanged by this task; it operates on whatever `seq` the merge
    /// hands it, with no notion of deviceID at all).
    ///
    /// Renumbering is by SORTED POSITION, not by `at`/deviceID value — the output is a
    /// dense `0..<n`, exactly what a real single-stream `markers.jsonl` always was, so
    /// `MarkerCorrections`/`MarkerSnapping`/`TranscriptAttribution` need no merge-
    /// awareness at all.
    ///
    /// `retractsSeq` remap: looked up ONLY within the retracting record's OWN stream
    /// (`Tagged.deviceID`) — a same-stream target remaps to its new position; anything
    /// else (never existed in that stream, or only coincidentally shares a raw seq
    /// number with a DIFFERENT stream's record — raw seq numbers restart at 0 per
    /// device and are not globally unique before this merge) is dropped, i.e. the
    /// merged record's `retractsSeq` becomes `nil`. A `nil` `retractsSeq` is already a
    /// legal, meaningful state downstream: `MarkerCorrections.effectiveMarkers` only
    /// ever inserts a target into `retractedSeqs` `if let target = marker.retractsSeq`,
    /// so a dropped retract simply retracts nothing — the identical "ignored, not an
    /// error" treatment a same-stream retract-of-a-nonexistent-seq already gets.
    static func merge(_ streams: [Stream]) -> [StructureMarker] {
        var tagged: [Tagged] = []
        for stream in streams {
            for marker in stream.markers {
                tagged.append(Tagged(deviceID: stream.deviceID, originalSeq: marker.seq, marker: marker))
            }
        }

        tagged.sort { lhs, rhs in
            let lhsAt = lhs.marker.at ?? .distantPast
            let rhsAt = rhs.marker.at ?? .distantPast
            if lhsAt != rhsAt { return lhsAt < rhsAt }
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
            return lhs.originalSeq < rhs.originalSeq
        }

        // (deviceID, originalSeq) -> new position. Built AFTER sorting, from the final
        // order, so every record (not only retracts) can be looked up by its origin.
        var newSeqByOrigin: [String: Int] = [:]
        newSeqByOrigin.reserveCapacity(tagged.count)
        for (index, item) in tagged.enumerated() {
            newSeqByOrigin[originKey(deviceID: item.deviceID, seq: item.originalSeq)] = index
        }

        return tagged.enumerated().map { index, item in
            var marker = item.marker
            marker.seq = index
            if marker.kind == .correctionRetract, let target = marker.retractsSeq {
                marker.retractsSeq = newSeqByOrigin[originKey(deviceID: item.deviceID, seq: target)]
            }
            return marker
        }
    }

    private static func originKey(deviceID: String, seq: Int) -> String {
        "\(deviceID)#\(seq)"
    }
}
