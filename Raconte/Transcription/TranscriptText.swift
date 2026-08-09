import Foundation

/// The ONE join rule (design §4.2 rule 8): plain single-space concatenation of
/// non-empty pieces. Real spacing and punctuation are the canonical transcript's
/// problem (T6/T7), not this layer's.
///
/// Factored out of `TranscriptConsolidator.join` (T6a) so revision assembly shares
/// the exact same rule instead of a second, drifting implementation.
enum TranscriptText {
    static func join(_ pieces: [String]) -> String {
        pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
