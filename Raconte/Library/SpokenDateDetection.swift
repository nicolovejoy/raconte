import Foundation

/// The rule that turns a parsed spoken date into an entry's backdate (M3 issue #15).
///
/// Pure and separate from both the parser and the hook, because the interesting part is
/// none of the string handling — it is *when we are allowed to write*. Owner decisions,
/// all encoded here:
/// - auto-apply, no suggestion chip;
/// - only when no manual backdate exists at that moment;
/// - once per entry, ever — `detectedDate` is the latch (see `EntryMetadata`), so a
///   backdate the owner later clears is never resurrected by a second pass.
enum SpokenDateDetection {
    /// Mutates `metadata` and reports whether anything changed. `false` means the caller
    /// must not write: a no-op rewrite of a sidecar is how a scan turns into a disk churn.
    @discardableResult
    static func apply(to metadata: inout EntryMetadata, transcriptText: String?,
                       now: Date = Date()) -> Bool {
        // The latch. `detectionRan`, not `detectedDate == nil` (issue #21) — an unreadable
        // `detectedDate` decodes to nil too, and checking the value would let that damage
        // reopen a latch that already fired. Checked before parsing, so a re-run costs
        // nothing.
        guard !metadata.detectionRan else { return false }
        guard let transcriptText,
              let detected = SpokenDateParser.detect(in: transcriptText) else { return false }

        // A future date is a misrecognition (disallow-future-backdates), not a real
        // backdate to clamp — discard outright. Not latched either: unlike a date the
        // parser found and correctly declined to apply (manual wins), this one was never
        // valid, so there is nothing to remember and a later transcript re-derivation gets
        // another try.
        guard !detected.isFuture(now: now) else { return false }

        metadata.detectedDate = detected
        metadata.detectionRan = true
        // Manual first, always. A date the owner typed outranks one the room said, and
        // recording the detection anyway is what keeps this a one-shot.
        if metadata.originalDate == nil {
            metadata.originalDate = detected
        }
        return true
    }
}
