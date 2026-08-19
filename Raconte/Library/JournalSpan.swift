import Foundation

enum JournalSpanError: Error, Equatable {
    /// End is before start, judged at each endpoint's own unit (see `JournalSpan`).
    case inverted
}

/// The span the PAPER journal covers, as its owner knows it — independent of how much of
/// it has been read in so far (spec ruling 2). A half-transcribed 1998 journal must not
/// advertise itself as an Aug 2026 journal, which is what the DERIVED `JournalDateRange`
/// would say.
///
/// **Endpoints are units, not instants.** `PartialDate` is `Comparable` by `anchorDate`,
/// which fills absent components with the first — "2001" anchors to 1 Jan 2001. Comparing
/// against that raw anchor would put every entry after 1 Jan 2001 outside a "1998 – 2001"
/// journal. So `start` expands to the EARLIEST instant of its precision's unit, and
/// containment against `end` is checked up to (but excluding) the first instant of the
/// unit immediately AFTER `end`'s.
struct JournalSpan: Sendable, Equatable, Hashable {
    let start: PartialDate
    /// Nil means open-ended: a journal still being written.
    let end: PartialDate?

    init(start: PartialDate, end: PartialDate?) throws {
        if let end, Self.lowerBound(start, calendar: .gregorianCurrent)
                    >= Self.exclusiveUpperBound(end, calendar: .gregorianCurrent) {
            throw JournalSpanError.inverted
        }
        self.start = start
        self.end = end
    }

    func contains(_ date: Date, calendar: Calendar = .gregorianCurrent) -> Bool {
        guard date >= Self.lowerBound(start, calendar: calendar) else { return false }
        guard let end else { return true }
        return date < Self.exclusiveUpperBound(end, calendar: calendar)
    }

    func formatted(calendar: Calendar = .gregorianCurrent) -> String {
        let startText = start.formatted(calendar: calendar)
        guard let end else { return "\(startText) –" }
        let endText = end.formatted(calendar: calendar)
        return startText == endText ? startText : "\(startText) – \(endText)"
    }

    // MARK: Unit expansion

    /// The first instant of the unit this partial date names.
    static func lowerBound(_ value: PartialDate, calendar: Calendar) -> Date {
        calendar.startOfDay(for: value.anchorDate(calendar: calendar))
    }

    /// The instant immediately AFTER the unit this partial date names ends — midnight at
    /// the start of the following day/month/year. `calendar.dateInterval(of:for:)`'s own
    /// `.end` is already exclusive; comparing against it with a strict `<` covers every
    /// instant of the unit, including its final sub-second, without manufacturing a
    /// synthetic "last instant" by subtracting a fixed 1.0 second (which under-covers:
    /// `23:59:59.000–23:59:59.999` of the unit's true last day would be wrongly excluded).
    /// `dateInterval(of:for:)` gives the unit's real length, so February 2024 correctly
    /// ends on the 29th.
    static func exclusiveUpperBound(_ value: PartialDate, calendar: Calendar) -> Date {
        let anchor = calendar.startOfDay(for: value.anchorDate(calendar: calendar))
        let unit: Calendar.Component
        switch value.precision {
        case .day: unit = .day
        case .yearMonth: unit = .month
        case .year: unit = .year
        }
        guard let interval = calendar.dateInterval(of: unit, for: anchor) else { return anchor }
        return interval.end
    }
}

extension JournalSpan: Codable {
    private enum CodingKeys: String, CodingKey { case start, end }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Not `self.init(start:end:)`-bypassed: the invariant must hold for values that
        // arrive off disk, not only ones minted in the editor.
        try self.init(start: try container.decode(PartialDate.self, forKey: .start),
                      end: try container.decodeIfPresent(PartialDate.self, forKey: .end))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        // Only when present, so an open-ended span does not carry a null.
        try container.encodeIfPresent(end, forKey: .end)
    }
}
