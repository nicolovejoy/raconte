import Foundation
import GRDB
import SwiftUI

/// What the owner typed, turned into an FTS5 pattern that never reaches the query parser
/// raw (a stray quote or `-` is a syntax error in FTS5; GRDB's constructors tokenise first).
struct SearchQuery: Sendable, Equatable {
    var text: String

    /// Straight and typographic double quotes. iOS and macOS smart punctuation converts typed
    /// `"` to these, and SwiftUI's `.searchable` cannot turn that off.
    private static let quoteMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{AB}", "\u{BB}"]

    /// The trimmed input when it is one whole quoted string, else nil.
    private var quotedPhrase: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, let first = t.first, let last = t.last,
              Self.quoteMarks.contains(first), Self.quoteMarks.contains(last) else { return nil }
        let inner = t.dropFirst().dropLast()
        guard !inner.contains(where: { Self.quoteMarks.contains($0) }) else { return nil }
        return String(inner)
    }

    /// Built from `terms`, not the raw text: GRDB's ASCII tokenizer keeps non-ASCII
    /// punctuation such as `…` as a token, so the raw text would yield `…*`, not nil.
    var pattern: FTS5Pattern? {
        let words = terms.joined(separator: " ")
        if quotedPhrase != nil { return FTS5Pattern(matchingPhrase: words) }
        return FTS5Pattern(matchingAllPrefixesIn: words)
    }

    /// Lowercased word tokens, for the in-entry highlighter (Phase A3) and tests.
    var terms: [String] {
        (quotedPhrase ?? text)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// FTS5 `snippet()` output with private-use markers, parsed into text + match ranges.
struct SearchSnippet: Sendable, Equatable {
    private static let openScalar: Unicode.Scalar = "\u{E000}"
    private static let closeScalar: Unicode.Scalar = "\u{E001}"
    static let openMarker = String(openScalar)
    static let closeMarker = String(closeScalar)

    var text: String
    /// Aligned to unicode scalars, not always to Characters: a match can end inside a
    /// grapheme (see `parse`).
    var matches: [Range<String.Index>]

    /// By unicode scalar, never by Character. FTS5 ends a token before a combining mark it
    /// does not fold (a keycap's U+FE0F, a virama, Arabic harakat), so the close marker can
    /// sit directly in front of one; as Characters the two are a single grapheme that is
    /// neither the marker nor text. An open marker with no close, and a close with no open,
    /// are dropped.
    static func parse(_ marked: String) -> SearchSnippet {
        var scalars = String.UnicodeScalarView()
        var count = 0
        var spans: [Range<Int>] = []   // scalar offsets into the stripped text
        var openAt: Int?
        for scalar in marked.unicodeScalars {
            switch scalar {
            case openScalar: openAt = count
            case closeScalar:
                if let start = openAt { spans.append(start..<count); openAt = nil }
            default:
                scalars.append(scalar)
                count += 1
            }
        }
        // Indices are taken from the finished string, in one forward walk.
        let text = String(scalars)
        let view = text.unicodeScalars
        var index = view.startIndex
        var offset = 0
        var matches: [Range<String.Index>] = []
        for span in spans {
            index = view.index(index, offsetBy: span.lowerBound - offset)
            let lower = index
            index = view.index(index, offsetBy: span.count)
            offset = span.upperBound
            matches.append(lower..<index)
        }
        return SearchSnippet(text: text, matches: matches)
    }

    var attributed: AttributedString {
        var out = AttributedString(text)
        for range in matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = InkTone.accent.color.opacity(0.35)
        }
        return out
    }
}
