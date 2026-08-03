import Foundation

/// Reads a spoken leading date off the opening of a transcript (M3 issue #15) — "March
/// 4th, 1998, we drove to the coast" ⇒ `1998-03-04`.
///
/// Pure and disk-free. The result carries its own precision, so "March 1998" is a
/// year-month backdate and never a fabricated March 1st.
///
/// **Not `NSDataDetector`**, which the issue originally proposed: it has no concept of
/// precision and backfills the components it wasn't given, so "March 1998" comes back as
/// a specific instant in March and "1998" as a specific day. That is exactly the
/// timezone-fragile, over-precise answer `PartialDate` exists to prevent.
enum SpokenDateParser {
    /// Only the opening is scanned. A date named a paragraph in is a date the entry is
    /// *about* something else — the backdate rule is "the entry opens by dating itself".
    static let openingCharacterLimit = 80

    /// `nil` when the opening names no date this recognizes. Never throws and never
    /// guesses: an impossible date ("February 30th, 1998") is no detection at all.
    static func detect(in transcript: String, limit: Int = openingCharacterLimit) -> PartialDate? {
        let rawTokens = tokenize(String(transcript.prefix(limit)))
        let tokens = dropLeadingFiller(rawTokens)
        guard !tokens.isEmpty else { return nil }

        // Most specific first. Each returns nil rather than falling back to a coarser
        // reading of the same words — "March 4th" with no year is not "1998".
        if let date = dayOfMonthYear(tokens) { return date }
        if let date = monthDayYear(tokens) { return date }
        if let date = monthYear(tokens) { return date }
        // Bare year reads the UNFILTERED tokens, not `tokens` — filler tolerance is a
        // month-led-pattern feature. A four-digit number carries no signal of its own, so
        // its only defence is position, and filler stripping moving it TO position 0 is
        // exactly the hole this closes ("So, in the 1998 election I voted" — "so"/"in"/
        // "the" are all filler words, and stripping them would otherwise promote 1998 to
        // a detected year). Accepted, documented false positive: "2000 dollars was a
        // lot" — the year genuinely opens the utterance, so it detects; there is no
        // signal left to tell that case apart from a real bare-year opening, and the
        // result is visible and editable in the UI, never silently applied.
        return bareYear(rawTokens)
    }

    // MARK: - Patterns

    /// "the 4th of March, 1998" / "4 March 1998" — `the` is already gone as filler.
    private static func dayOfMonthYear(_ t: [String]) -> PartialDate? {
        var i = 0
        guard let day = dayNumber(at: &i, in: t) else { return nil }
        if t[safe: i] == "of" { i += 1 }
        guard let month = monthNumber(t[safe: i]) else { return nil }
        i += 1
        guard let year = yearNumber(t[safe: i]) else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    /// "March 4th, 1998" / "March 4 1998" / "March the 4th, 1998".
    private static func monthDayYear(_ t: [String]) -> PartialDate? {
        guard let month = monthNumber(t[safe: 0]) else { return nil }
        var i = 1
        if t[safe: i] == "the" { i += 1 }
        guard let day = dayNumber(at: &i, in: t) else { return nil }
        guard let year = yearNumber(t[safe: i]) else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    /// "March 1998" / "March of 1998".
    private static func monthYear(_ t: [String]) -> PartialDate? {
        guard let month = monthNumber(t[safe: 0]) else { return nil }
        var i = 1
        if t[safe: i] == "of" { i += 1 }
        guard let year = yearNumber(t[safe: i]) else { return nil }
        return makeDate(year: year, month: month, day: nil)
    }

    /// A bare year, and **only** when it is the very FIRST token of the raw transcript —
    /// before any filler is stripped. Anywhere else it is prose — "I bought 1998 stamps"
    /// must not become a 1998 backdate — and the position test is the whole defence,
    /// since a four-digit number carries no other signal. Filler tolerance does not
    /// extend here (see the call site in `detect`): a bare year preceded by so much as
    /// "so" or "the" is not a dated opening, it is a number that happens to appear early.
    private static func bareYear(_ rawTokens: [String]) -> PartialDate? {
        guard let year = yearNumber(rawTokens[safe: 0]) else { return nil }
        return makeDate(year: year, month: nil, day: nil)
    }

    // MARK: - Components

    /// Every component check funnels through `PartialDate(parsing:)`, so month-length
    /// and leap-year validity is the same rule the stored format already enforces
    /// (February 30th ⇒ nil, not a crash and not a silently shifted date).
    private static func makeDate(year: Int, month: Int?, day: Int?) -> PartialDate? {
        var iso = String(format: "%04d", year)
        if let month { iso += String(format: "-%02d", month) }
        if let day { iso += String(format: "-%02d", day) }
        return try? PartialDate(parsing: iso)
    }

    /// Advances past a day token, with or without an ordinal suffix ("4", "4th", "21st").
    private static func dayNumber(at index: inout Int, in tokens: [String]) -> Int? {
        guard let token = tokens[safe: index] else { return nil }
        var digits = token
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits = String(digits.dropLast(2))
            break
        }
        guard isDigits(digits), digits.count <= 2, let day = Int(digits), (1...31).contains(day)
        else { return nil }
        index += 1
        return day
    }

    /// Range-limited on purpose: without it every four-digit number in the language is a
    /// candidate year, and a journal read aloud is full of them.
    private static func yearNumber(_ token: String?) -> Int? {
        guard let token, isDigits(token), token.count == 4, let year = Int(token),
              (1900...2099).contains(year) else { return nil }
        return year
    }

    private static func monthNumber(_ token: String?) -> Int? {
        guard let token else { return nil }
        return monthNames[token]
    }

    private static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static let monthNames: [String: Int] = {
        let full = ["january", "february", "march", "april", "may", "june",
                    "july", "august", "september", "october", "november", "december"]
        var map: [String: Int] = [:]
        for (index, name) in full.enumerated() {
            map[name] = index + 1
            map[String(name.prefix(3))] = index + 1
        }
        map["sept"] = 9
        return map
    }()

    // MARK: - Tokenizing

    /// Lowercased words, with punctuation dropped — commas and the period after "1998."
    /// are noise, and the transcriber's placement of them is not something to depend on.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "’" && $0 != "'" })
            .map(String.init)
    }

    /// Preamble the owner actually says before dating an entry. Stripped only from the
    /// front, so it can never expose a mid-sentence year to the bare-year rule.
    ///
    /// `the` is in here and is also the first word of "the 4th of March" — harmless,
    /// because `dayOfMonthYear` reads the ordinal directly rather than requiring `the`.
    private static let filler: Set<String> = [
        "okay", "ok", "um", "umm", "uh", "uhh", "er", "erm", "hmm", "mmm",
        "so", "well", "alright", "right", "now", "and", "this", "is", "it", "it’s", "it's",
        "the", "entry", "for", "from", "dated", "date", "on", "in",
        "today", "was", "were", "i", "i’m", "i'm", "im", "let", "let’s", "let's", "lets",
        "me", "see", "recording", "my", "we", "here",
    ]

    private static func dropLeadingFiller(_ tokens: [String]) -> [String] {
        var index = 0
        // A month name is never filler, whatever the list says — "may" is the one word
        // that could plausibly end up in both.
        while index < tokens.count, filler.contains(tokens[index]), monthNames[tokens[index]] == nil {
            index += 1
        }
        return Array(tokens[index...])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
