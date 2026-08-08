import Foundation

/// Snaps raw marker frames onto inter-word gaps in a committed transcript (design §6).
/// Pure: no I/O, no actor, no clock. The raw frame is NEVER mutated — a better
/// snapping rule later re-derives better boundaries from untouched data (owner
/// decision 2). Consumed by T7 promotion and re-applied by T8 retranscription.
enum MarkerSnapping {

    /// ±window around the raw tap frame. One named constant — tune here, nowhere else.
    /// Tuned from device sessions 2026-08-07/08: taps trail the true boundary by
    /// 0.18–0.37 s and never lead, so 1.5 s (the original guess) was ~4× oversized —
    /// and since rule 2 ranks gaps by *size* first, an oversized window lets a long
    /// pause far from the tap steal the snap from the correct small gap beside it.
    /// 0.75 s is 2× the worst observed lag.
    static let snapWindowSeconds: Double = 0.75

    static func windowFrames(sampleRate: Double) -> Int64 {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Int64((snapWindowSeconds * sampleRate).rounded())
    }

    /// A span of transcribed speech on the capture-frame axis.
    struct SpokenInterval: Equatable, Sendable {
        var start: Int64
        var end: Int64
    }

    struct SnappedMarker: Equatable, Sendable {
        /// The stored marker, raw frame intact.
        var marker: StructureMarker
        var snappedFrame: Int64
        /// §6 rule 4: nothing usable in the window — raw frame kept; T7 surfaces it.
        var approximate: Bool
    }

    /// Interval extraction with the untimed-run rule (design §6): a record whose runs
    /// are all timed contributes one interval per run; a record containing ANY untimed
    /// run contributes its record-level `TranscriptResult.range` as a single interval
    /// (the design's "record-level captureFrameStart/End"; conservative —
    /// no interior gaps invented from partial data). Output is sorted and merged.
    ///
    /// A record with *no* runs at all is the untimed case too: the transcriber
    /// attributed nothing, so only the record range is known.
    ///
    /// Every element of `committed` is used as given — filtering volatile results is the
    /// caller's job, and by contract it has already happened
    /// (`LiveTranscriptReader.consolidate(_:).committed`).
    static func intervals(fromCommitted committed: [TranscriptResult]) -> [SpokenInterval] {
        var extracted: [SpokenInterval] = []
        for result in committed {
            let timed = result.runs.compactMap { run -> SpokenInterval? in
                guard let start = run.captureFrameStart,
                      let end = run.captureFrameEnd else { return nil }
                return SpokenInterval(start: start, end: end)
            }
            if !result.runs.isEmpty, timed.count == result.runs.count {
                extracted.append(contentsOf: timed)
            } else {
                extracted.append(SpokenInterval(start: result.range.start,
                                                end: result.range.end))
            }
        }
        return merged(extracted)
    }

    /// Sorted, empty-or-inverted spans dropped, and overlapping *or exactly touching*
    /// spans fused. Touching matters: two records that abut would otherwise leave a
    /// zero-length "gap" that no marker can usefully snap into, and an overlap would
    /// manufacture a negative-length one.
    private static func merged(_ input: [SpokenInterval]) -> [SpokenInterval] {
        let sorted = input
            .filter { $0.end > $0.start }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [SpokenInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1].end = max(last.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// §6 rules, in order, per marker (details plan §0.3.7):
    /// 0. Raw frame outside every interval → already in a gap: keep it, exact.
    /// 1. Collect inter-interval gaps intersecting [frame−w, frame+w].
    /// 2. Pick the largest by intersection length; ties → nearest the raw frame.
    ///    Snapped frame = midpoint of the intersection.
    /// 3. No gap, but an interval boundary in the window → nearest boundary.
    /// 4. Nothing in the window → raw frame, approximate.
    /// Output order matches input order; markers of every kind (including .unknown)
    /// pass through — snapping is kind-agnostic.
    static func snap(markers: [StructureMarker],
                     intervals: [SpokenInterval],
                     windowFrames: Int64) -> [SnappedMarker] {
        // Re-merged defensively: every gap below is derived from adjacency, so an
        // unsorted or overlapping input would silently invent gaps. `intervals(from:)`
        // already returns merged output, so this is normally a no-op.
        let speech = merged(intervals)
        let window = max(0, windowFrames)
        return markers.map { snap(marker: $0, intervals: speech, window: window) }
    }

    private static func snap(marker: StructureMarker,
                             intervals: [SpokenInterval],
                             window: Int64) -> SnappedMarker {
        let frame = marker.frame

        // Rule 0. Strictly interior, so a tap that landed exactly on a run boundary is
        // "already in a gap" too — it is a correct boundary and nothing can improve it.
        // This rule pre-empts the largest-gap ranking below: a marker sitting in an
        // interior gap stays put even when a bigger gap lies elsewhere in the window.
        let insideSpeech = intervals.contains { frame > $0.start && frame < $0.end }
        guard insideSpeech else {
            return SnappedMarker(marker: marker, snappedFrame: frame, approximate: false)
        }

        let lowerBound = frame - window
        let upperBound = frame + window

        // Rules 1–2. A gap is only as useful as the part of it inside the window, so
        // both the ranking and the snapped frame use the *intersection*, never the whole
        // gap — which is what keeps the snap within ±window of the tap.
        var best: (length: Int64, distance: Int64, midpoint: Int64)?
        if intervals.count > 1 {
            for index in 0..<(intervals.count - 1) {
                let clippedStart = max(intervals[index].end, lowerBound)
                let clippedEnd = min(intervals[index + 1].start, upperBound)
                guard clippedEnd > clippedStart else { continue }
                let midpoint = (clippedStart + clippedEnd) / 2
                let candidate = (length: clippedEnd - clippedStart,
                                 distance: abs(midpoint - frame),
                                 midpoint: midpoint)
                guard let current = best else {
                    best = candidate
                    continue
                }
                if candidate.length > current.length
                    || (candidate.length == current.length
                        && candidate.distance < current.distance) {
                    best = candidate
                }
            }
        }
        if let best {
            return SnappedMarker(marker: marker,
                                 snappedFrame: best.midpoint,
                                 approximate: false)
        }

        // Rule 3. Reachable only at the head of the first interval and the tail of the
        // last: every interior boundary abuts a gap, which rule 1 would already have
        // caught.
        var nearestBoundary: Int64?
        for interval in intervals {
            for boundary in [interval.start, interval.end]
            where boundary >= lowerBound && boundary <= upperBound {
                if let current = nearestBoundary {
                    if abs(boundary - frame) < abs(current - frame) {
                        nearestBoundary = boundary
                    }
                } else {
                    nearestBoundary = boundary
                }
            }
        }
        if let nearestBoundary {
            return SnappedMarker(marker: marker,
                                 snappedFrame: nearestBoundary,
                                 approximate: false)
        }

        // Rule 4. The tap landed deep inside one long run.
        return SnappedMarker(marker: marker, snappedFrame: frame, approximate: true)
    }
}
