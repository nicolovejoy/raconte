import SwiftUI

/// Backdate entry point for both the capture screen (inline, compact) and the entry
/// detail sheet (full-screen, graphical) — M3 issue #14 part 1: paper journals are often
/// dated only to a year, or a year and month.
///
/// A segmented control picks the precision; the row below it changes shape to match —
/// a full `DatePicker` for `.day`, month + year wheels for `.yearMonth`, a year wheel
/// alone for `.year`. `date` always holds a complete `Date`; reducing precision does not
/// zero out the day/month components in place — `EntryMetadata.effectiveDate` is the one
/// place that normalizes for sorting/display, so a stale day component left over from a
/// previous `.day` selection is never read once the precision changes.
struct PrecisionDatePicker: View {
    @Binding var date: Date
    @Binding var precision: DatePrecision
    /// Accessibility-identifier namespace: `"capture"` / `"detail"`.
    var idPrefix: String
    /// The capture screen wants `.compact` inline; the detail sheet wants `.graphical`
    /// full-screen. Only affects the `.day` case — month/year wheels look the same both
    /// places.
    var dayPickerStyle: DayPickerStyle = .compact

    enum DayPickerStyle { case compact, graphical }

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Precision", selection: $precision) {
                Text("Day").tag(DatePrecision.day)
                Text("Month").tag(DatePrecision.yearMonth)
                Text("Year").tag(DatePrecision.year)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("\(idPrefix).backdatePrecision")

            switch precision {
            case .day:
                dayPicker
            case .yearMonth:
                HStack(spacing: 12) {
                    monthPicker
                    yearPicker
                }
            case .year:
                yearPicker
            }
        }
    }

    @ViewBuilder
    private var dayPicker: some View {
        // `in: ...Date()` disallows dialing a future day directly (disallow-future-
        // backdates) — the model-level `EntryMetadata.setOriginalDate` clamp is the real
        // guard, this just keeps the wheel from offering a value it will reject.
        switch dayPickerStyle {
        case .compact:
            #if os(macOS)
            // `.field`, not `.compact`, on the Mac — a typed date field with NO popover.
            //
            // Owner smoke, 2026-08-15: "date picker is not working great on mac, now I
            // can't pick a date at all". `.compact` on macOS is a small chip that opens a
            // calendar POPOVER, and a popover is its own presentation: the capture
            // screen's `.environment(\.colorScheme, .dark)` pin does not reach into it
            // (`BackdateField` says so in its own comment — the transient popup is
            // explicitly out of scope for #58), while the inherited white foreground may.
            // A popover that renders white-on-light is unreadable, and one anchored inside
            // this screen's clipped scroll band is worse.
            //
            // `.field` sidesteps the whole class: no popup to mis-render or mis-anchor,
            // and typing a date suits the Mac, where the owner has said he wants to work
            // from the keyboard. iOS keeps `.compact`, which he reports reads and works
            // well there.
            DatePicker("Entry date", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .accessibilityIdentifier("\(idPrefix).backdateField")
            #else
            DatePicker("Entry date", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityIdentifier("\(idPrefix).backdateField")
            #endif
        case .graphical:
            DatePicker("Entry date", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("\(idPrefix).backdateField")
        }
    }

    private var monthPicker: some View {
        Picker("Month", selection: componentBinding(.month)) {
            ForEach(1...monthUpperBound, id: \.self) { month in
                Text(calendar.monthSymbols[month - 1]).tag(month)
            }
        }
        .accessibilityIdentifier("\(idPrefix).backdateMonth")
    }

    /// 12 for any year before the current one; this month, for the current year — and
    /// always widened to include whatever month is currently selected (same reasoning as
    /// `yearRange` below: an unmatched `Picker` tag renders blank rather than clamping).
    private var monthUpperBound: Int {
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        let selectedYear = calendar.component(.year, from: date)
        guard selectedYear >= currentYear else { return 12 }
        return max(calendar.component(.month, from: now), calendar.component(.month, from: date))
    }

    private var yearPicker: some View {
        Picker("Year", selection: componentBinding(.year)) {
            ForEach(yearRange, id: \.self) { year in
                Text(String(year)).tag(year)
            }
        }
        .accessibilityIdentifier("\(idPrefix).backdateYear")
    }

    /// Two centuries back from today, forward through the current year — and always
    /// widened to include whatever year is currently selected. An unbounded `.day`
    /// `DatePicker` can land outside a fixed floor (an 1890s paper journal), which would
    /// otherwise leave this segmented `Picker`'s tag unmatched and undated.
    private var yearRange: ClosedRange<Int> {
        let current = calendar.component(.year, from: Date())
        let selected = calendar.component(.year, from: date)
        return min(current - 200, selected)...max(current, selected)
    }

    private func componentBinding(_ component: Calendar.Component) -> Binding<Int> {
        Binding(
            get: { calendar.component(component, from: date) },
            set: { newValue in
                var comps = calendar.dateComponents([.year, .month, .day], from: date)
                switch component {
                case .month: comps.month = newValue
                case .year: comps.year = newValue
                default: break
                }
                // Reduced precision must not carry a stale day/month component through
                // `Calendar.date(from:)`, which is lenient and rolls a nonexistent date
                // (Jan 31 + month=Feb) into the following month. Noon, not midnight —
                // parking a reduced-precision date at a midnight boundary flips its
                // displayed year/month under a more-westward timezone.
                if precision == .year {
                    comps = DateComponents(year: comps.year, month: 1, day: 1, hour: 12)
                } else if precision == .yearMonth {
                    comps = DateComponents(year: comps.year, month: comps.month, day: 1, hour: 12)
                }
                date = calendar.date(from: comps) ?? date
            })
    }
}
