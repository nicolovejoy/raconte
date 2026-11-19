import Foundation
import SwiftUI

/// What a Search result carries into the entry it opens: the query's terms, as
/// `SearchQuery.terms` gives them (lowercased word tokens). A quoted phrase arrives as its
/// words, so the entry marks each word on its own, not the phrase as one run.
struct SearchHighlight: Hashable, Sendable {
    var terms: [String]
}

/// Marks a query's hits inside a transcript (#194). Pure: no view, no index.
enum TranscriptHighlighter {
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Word-start, case- and diacritic-insensitive prefix matches — the index's rule, in
    /// text order, one range per matching word.
    ///
    /// A word is a maximal run of Characters that are letters or numbers: the rule
    /// `SearchQuery.terms` uses and `unicode61` applies, so `l'école` is two words here as
    /// it is in the index (ICU's `.byWords` keeps it whole and would show "0 of 0" for a
    /// hit the list promised). Words and terms are folded; the range comes from the
    /// ORIGINAL text. It covers the first `term.count` Characters of the word, or the whole
    /// word when folding changed the word's Character count (`ß` folds to `ss`), where a
    /// prefix cannot be mapped back. When several terms match one word the longest wins.
    static func matches(in text: String, terms: [String]) -> [Range<String.Index>] {
        let folded = terms.map(fold).filter { !$0.isEmpty }
        guard !folded.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var wordStart: String.Index?
        func close(at end: String.Index) {
            guard let start = wordStart else { return }
            wordStart = nil
            let word = text[start..<end]
            let foldedWord = fold(String(word))
            guard let hit = folded.filter({ foldedWord.hasPrefix($0) }).max(by: { $0.count < $1.count })
            else { return }
            if foldedWord.count == word.count {
                out.append(start..<text.index(start, offsetBy: hit.count))
            } else {
                out.append(start..<end)
            }
        }
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if wordStart == nil { wordStart = index }
            } else {
                close(at: index)
            }
        }
        close(at: text.endIndex)
        return out
    }

    /// `text` with each match backgrounded; the `current` one (an index into `matches`) a
    /// stronger tone. The ranges must come from `matches(in:terms:)` over this same `text`;
    /// what any other range does is unspecified (a probe saw foreign ranges skipped and
    /// applied alike).
    static func attributed(_ text: String, matches: [Range<String.Index>], current: Int?) -> AttributedString {
        var out = AttributedString(text)
        for (i, range) in matches.enumerated() {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = InkTone.accent.color.opacity(i == current ? 0.7 : 0.35)
        }
        return out
    }
}
