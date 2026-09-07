import Foundation

/// Renders one entry's `entries/<captureID>/transcript.md` (T11) — the export
/// package's human-readable derived file. Pure string transform: no I/O, no clock.
///
/// Format (deterministic, fixed key order regardless of which values are present):
///
///     ---
///     captureID: <id>
///     revisionID: <id, or empty>
///     source: <RevisionSource.string, or empty>
///     createdAt: <ISO8601, or empty>
///     journalID: <id, or empty>
///     originalDate: <PartialDate.isoString, or empty>
///     ---
///
///     <current revision's plain text, or empty>
enum TranscriptMarkdown {
    /// The exact string separating the frontmatter block from the body — a blank line,
    /// i.e. two newlines. Shared by `render` and `body(of:)` so the two can never drift.
    private static let bodySeparator = "\n\n"

    static func render(captureID: String, journalID: String?, originalDate: String?,
                       revision: TranscriptRevision?) -> String {
        let frontmatter = [
            "---",
            "captureID: \(captureID)",
            "revisionID: \(revision?.id ?? "")",
            "source: \(revision?.source.string ?? "")",
            "createdAt: \(revision.map { CaptureCoding.iso8601Formatter().string(from: $0.createdAt) } ?? "")",
            "journalID: \(journalID ?? "")",
            "originalDate: \(originalDate ?? "")",
            "---",
        ].joined(separator: "\n")

        let body = revision.map(TranscriptChain.plainText) ?? ""
        return frontmatter + bodySeparator + body
    }

    /// The body half of a document `render` produced — everything after the first blank
    /// line. The frontmatter block above never itself contains a blank line, so the
    /// FIRST occurrence of `bodySeparator` is always the real boundary, regardless of
    /// what the body text goes on to contain.
    static func body(of document: String) -> String {
        guard let range = document.range(of: bodySeparator) else { return "" }
        return String(document[range.upperBound...])
    }
}
