import Foundation

/// The match bar of an entry opened from Search (#194): every match of the query's terms,
/// paragraph by paragraph, and which one is current. Pure.
///
/// Matches are numbered in reading order across paragraphs. The first is current on
/// arrival; `next` and `previous` wrap. With no matches the bar reads "0 of 0" and both are
/// no-ops — an entry edited after it was indexed can lose the words the list found.
struct SearchMatchCursor: Equatable {
    /// `TranscriptHighlighter.matches` of each paragraph, in the order given.
    private(set) var paragraphMatches: [[Range<String.Index>]]
    /// Index of the current match among all of them; nil when there are none.
    private(set) var current: Int?
    /// The texts the matches index into, so a caller can tell whether a reload changed them.
    let paragraphTexts: [String]

    init(paragraphTexts: [String], terms: [String]) {
        self.paragraphTexts = paragraphTexts
        paragraphMatches = paragraphTexts.map { TranscriptHighlighter.matches(in: $0, terms: terms) }
        current = paragraphMatches.contains { !$0.isEmpty } ? 0 : nil
    }

    /// The cursor for an entry opened with `highlight`, or nil when there is nothing to
    /// highlight: no highlight, or no non-empty term (an empty term is a prefix of every
    /// word). Nil means no bar and the plain rendering.
    static func forEntry(highlight: SearchHighlight?, paragraphTexts: [String]) -> SearchMatchCursor? {
        guard let terms = highlight?.terms, terms.contains(where: { !$0.isEmpty }) else { return nil }
        return SearchMatchCursor(paragraphTexts: paragraphTexts, terms: terms)
    }

    /// The cursor after the entry's transcript is read again. `old` when it was built over
    /// the same texts, so a refresh that reads the same words keeps the owner's place;
    /// otherwise a fresh one, because `old`'s ranges index into the texts it was built over.
    static func refreshed(_ old: SearchMatchCursor?, highlight: SearchHighlight?,
                          paragraphTexts: [String]) -> SearchMatchCursor? {
        if let old, old.paragraphTexts == paragraphTexts { return old }
        return forEntry(highlight: highlight, paragraphTexts: paragraphTexts)
    }

    var total: Int { paragraphMatches.reduce(0) { $0 + $1.count } }

    /// "1 of 4", or "0 of 0".
    var label: String {
        guard let current else { return "0 of 0" }
        return "\(current + 1) of \(total)"
    }

    /// The paragraph holding the current match.
    var currentParagraph: Int? { locate()?.paragraph }

    /// The current match's index within paragraph `paragraph`'s matches, or nil when it is
    /// in another paragraph (or there is none).
    func currentIndexWithin(_ paragraph: Int) -> Int? {
        guard let found = locate(), found.paragraph == paragraph else { return nil }
        return found.within
    }

    /// How far into its paragraph the current match starts, 0…1: its Character offset over
    /// the paragraph's Character count. Nil with no current match. The detail screen scrolls
    /// a transcript drawn as one `Text` by this fraction, since SwiftUI cannot scroll to a
    /// character; for evenly wrapped prose it puts the match roughly on screen.
    var currentMatchFraction: Double? {
        guard let found = locate() else { return nil }
        return Self.fraction(of: paragraphMatches[found.paragraph][found.within].lowerBound,
                             in: paragraphTexts[found.paragraph])
    }

    /// `index`'s Character offset in `text` over `text`'s Character count; 0 for an empty text.
    static func fraction(of index: String.Index, in text: String) -> Double {
        let count = text.count
        guard count > 0 else { return 0 }
        return Double(text.distance(from: text.startIndex, to: index)) / Double(count)
    }

    /// Paragraph `paragraph`'s matches; empty for an index past either end.
    func matches(inParagraph paragraph: Int) -> [Range<String.Index>] {
        paragraphMatches.indices.contains(paragraph) ? paragraphMatches[paragraph] : []
    }

    mutating func next() {
        guard let current, total > 0 else { return }
        self.current = (current + 1) % total
    }

    mutating func previous() {
        guard let current, total > 0 else { return }
        self.current = (current - 1 + total) % total
    }

    private func locate() -> (paragraph: Int, within: Int)? {
        guard var remaining = current else { return nil }
        for (paragraph, matches) in paragraphMatches.enumerated() {
            if remaining < matches.count { return (paragraph, remaining) }
            remaining -= matches.count
        }
        return nil
    }
}
