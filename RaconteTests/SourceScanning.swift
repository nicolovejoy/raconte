import Foundation

/// Strips `//` line comments from source text before a source-scanning test matches
/// against it. Shared by every such test in this suite (repo memory:
/// source-scanning-tests-must-strip-comments) — without it, a scan is satisfied by prose
/// *about* the pattern rather than the pattern itself. `CaptureLabelTests` and
/// `PrecisionDatePickerTests` each carried their own copy of exactly this logic before
/// this file existed; both now call through here instead of a third (or fourth) copy.
///
/// Line comments only; assumes no `//` inside a string literal in the scanned files —
/// true for every source this suite scans as of this writing.
func strippingComments(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let slashes = line.range(of: "//") else { return line }
            return line[line.startIndex..<slashes.lowerBound]
        }
        .joined(separator: "\n")
}
