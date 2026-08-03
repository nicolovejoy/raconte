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

    /// A century-plus back from today, forward through the current year — wide enough
    /// for a paper journal from any point in a lifetime, without an unbounded wheel.
    private var yearRange: ClosedRange<Int> {
        let current = calendar.component(.year, from: Date())
        return (current - 120)...current
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
                date = calendar.date(from: comps) ?? date
            })
    }
}
