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
        switch dayPickerStyle {
        case .compact:
            DatePicker("Entry date", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityIdentifier("\(idPrefix).backdateField")
        case .graphical:
            DatePicker("Entry date", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("\(idPrefix).backdateField")
        }
    }

    private var monthPicker: some View {
        Picker("Month", selection: componentBinding(.month)) {
            ForEach(1...12, id: \.self) { month in
                Text(calendar.monthSymbols[month - 1]).tag(month)
            }
        }
        .accessibilityIdentifier("\(idPrefix).backdateMonth")
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
