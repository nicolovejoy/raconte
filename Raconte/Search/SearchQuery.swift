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
    static let openMarker = "\u{E000}"
    static let closeMarker = "\u{E001}"

    var text: String
    var matches: [Range<String.Index>]

    static func parse(_ marked: String) -> SearchSnippet {
        var text = ""
        var matches: [Range<String.Index>] = []
        var openAt: String.Index?
        for ch in marked {
            switch String(ch) {
            case openMarker: openAt = text.endIndex
            case closeMarker:
                if let start = openAt { matches.append(start..<text.endIndex); openAt = nil }
            default: text.append(ch)
            }
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
