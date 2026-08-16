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
            // Resets the capture call site's `.tint(.white)` — issue #58 names this control.
            // On a segmented picker the tint fills the SELECTED segment while the same call
            // site's `.foregroundStyle(.white)` draws its label, so a white tint means a
            // white label on a white fill: the active precision is invisible, in every
            // appearance, on both platforms. The reset lives here rather than at the call
            // site because that white tint is also what makes the iOS `.compact` date chip
            // read on the near-black surface, and the owner reports that one works.
            .tint(Color.accentColor)
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
            // The Mac draws its own button and its own calendar sheet. iOS keeps the system
            // `.compact` chip below, which the owner reports reads and works well there.
            //
            // Two system styles have now been tried here and both failed for the same
            // underlying reason — the calendar was drawn in a presentation this app cannot
            // reach. `.compact` on macOS opens an AppKit POPOVER: the capture screen's
            // `.environment(\.colorScheme, .dark)` pin does not travel into it (see
            // `BackdateField`'s own comment) while the screen's inherited white foreground
            // plausibly does, so it renders white-on-light, anchored inside a scroll band
            // this screen clips — owner smoke, 2026-08-15: "I can't pick a date at all".
            // `.field` then removed the popup, but a typed field at the Mac's own small
            // default size is not a date picker: "pass, but the date-picker ux is better on
            // the iphone" (owner, same day, final smoke).
            //
            // So this stops asking the system for a presentation it will not let us style.
            // The button is ours — sized and coloured through `CaptureLabel`, and therefore
            // checked by `CaptureLabelTests` like every other label on this surface — and
            // the calendar opens in a sheet we paint in the capture surface's own near-black
            // with the scheme pinned and the foreground reset inside it. Nothing about how
            // it reads depends on whether a modifier propagates into a system-owned
            // presentation, which is precisely what neither previous attempt could promise.
            BackdateDayButton(date: $date, identifier: "\(idPrefix).backdateField")
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

    #if os(macOS)
    /// The Mac's day picker: a button this app draws, opening a calendar sheet this app
    /// paints. See the `.compact` branch above for why neither system style survived.
    ///
    /// Deliberately NOT used on iOS. The iPhone's `.compact` chip presents its calendar in a
    /// sheet the system styles correctly, and the owner reports it reads and works well —
    /// there is nothing to fix there, and replacing a good native control with a hand-rolled
    /// one would be a regression dressed as consistency.
    private struct BackdateDayButton: View {
        @Binding var date: Date
        let identifier: String

        @State private var showingCalendar = false

        var body: some View {
            Button {
                showingCalendar = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    Text(date.formatted(date: .long, time: .omitted))
                    Spacer(minLength: 0)
                }
                .captureLabel(.backdateDateButton)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .contentShape(Rectangle())
            }
            // `.plain`, so the button contributes no material of its own: the bordered
            // default paints a light Aqua capsule that would be the dark-on-dark bug all
            // over again on this near-black surface.
            .buttonStyle(.plain)
            // A button wrapping an icon + text is read out as two elements otherwise — the
            // flattening/splitting pair this screen has hit repeatedly.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Entry date, \(date.formatted(date: .long, time: .omitted))")
            .accessibilityIdentifier(identifier)
            .sheet(isPresented: $showingCalendar) { calendarSheet }
        }

        private var calendarSheet: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Entry date")
                    .font(.headline)
                DatePicker("Entry date", selection: $date, in: ...Date(),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                HStack {
                    Spacer()
                    Button("Done") { showingCalendar = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("\(identifier).done")
                }
            }
            .padding(20)
            .frame(minWidth: 340, alignment: .leading)
            // The three modifiers that make this sheet self-consistent no matter what does
            // or does not propagate into it from the capture screen.
            //
            // `Color.primary` first, because the leak is the known bug, not a theory: this
            // screen sets `.foregroundStyle(.white)` for its near-black surface, and that
            // white is inherited into nested builders — it is exactly what made the New
            // Journal text field white-on-white (owner smoke, 2026-08-15). Under the dark
            // pin below, `Color.primary` resolves to white, so the reset both neutralises
            // the leak and colours the sheet correctly rather than fighting it.
            //
            // The tint reset matters for the same reason it does on the segmented control:
            // the graphical calendar fills the selected day with the tint, and a white fill
            // under a white numeral is an unreadable selection.
            //
            // Then the surface itself. A sheet left on the system's own light material would
            // reintroduce the whole class — so it paints the capture background and pins the
            // scheme to match, which is the one combination that cannot disagree with itself.
            .foregroundStyle(Color.primary)
            .tint(Color.accentColor)
            .background(Color(white: CaptureSurface.backgroundWhite))
            .environment(\.colorScheme, .dark)
        }
    }
    #endif

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
