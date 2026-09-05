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

    #if os(macOS)
    /// Drives the Mac day-calendar popover. iOS never presents it.
    @State private var showingDayCalendar = false
    #endif

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
            // `BackdateEditorContent`'s own comment) while the screen's inherited white foreground
            // plausibly does, so it renders white-on-light, anchored inside a scroll band
            // this screen clips — owner smoke, 2026-08-15: "I can't pick a date at all".
            // `.field` then removed the popup, but a typed field at the Mac's own small
            // default size is not a date picker: "pass, but the date-picker ux is better on
            // the iphone" (owner, same day, final smoke).
            //
            // So this stops asking the system for a presentation it will not let us style.
            // The button is ours — sized and coloured through `CaptureLabel`, and therefore
            // checked by `CaptureLabelTests` like every other label on this surface — and
            // the calendar opens in a popover we paint in the capture surface's own
            // near-black, with the scheme pinned and the foreground reset inside it, and
            // month + year dropdowns above it. Nothing about how it reads depends on whether
            // a modifier propagates into a system-owned presentation, which is precisely what
            // neither previous attempt could promise.
            macDayButton
            #else
            DatePicker("Entry date", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityIdentifier("\(idPrefix).backdateField")
            #endif
        case .graphical:
            #if os(macOS)
            // The entry-detail backdate editor has the identical problem the capture screen
            // was just fixed for: a bare macOS `.graphical` calendar offers only prev/next
            // month arrows, so reaching a 1998 page means ~340 clicks. It is arguably the
            // MORE likely place to meet it, being where a date gets corrected after the fact.
            // iOS needs none of this — its graphical picker has the month/year control built
            // in — so the header is macOS-only, like the button above.
            VStack(alignment: .leading, spacing: 12) {
                dayCalendarHeader
                DatePicker("Entry date", selection: $date, in: ...Date(),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("\(idPrefix).backdateField")
            }
            #else
            DatePicker("Entry date", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("\(idPrefix).backdateField")
            #endif
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
    /// The Mac's day picker: a button this app draws, opening a calendar popover this app
    /// paints. See the `.compact` branch above for why neither system style survived.
    ///
    /// Deliberately NOT used on iOS. The iPhone's `.compact` chip presents its calendar in a
    /// sheet the system styles correctly, and the owner reports it reads and works well —
    /// there is nothing to fix there, and replacing a good native control with a hand-rolled
    /// one would be a regression dressed as consistency.
    private var macDayButton: some View {
        Button {
            showingDayCalendar = true
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
        // `.plain`, so the button contributes no material of its own: the bordered default
        // paints a light Aqua capsule that would be the dark-on-dark bug all over again on
        // this near-black surface.
        .buttonStyle(.plain)
        // A button wrapping an icon + text is read out as two elements otherwise — the
        // flattening/splitting pair this screen has hit repeatedly.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Entry date, \(date.formatted(date: .long, time: .omitted))")
        .accessibilityIdentifier("\(idPrefix).backdateField")
        // A POPOVER, not a sheet. Owner smoke, 2026-08-16: "the escape key doesn't close it,
        // or clicking outside… you have to click on the Done button, which is excessive."
        // Correct on every count, and all of it inherent to a sheet — on macOS a sheet is
        // modal to its window and closes only through its own controls. A popover dismisses
        // on Escape and on click-away for free, which is why it is the idiom the system's own
        // date chip uses. There is consequently no Done button: adding one back would restore
        // the exact step he called excessive.
        //
        // This does not reopen what the sheet was introduced to fix. The presentation that
        // could not be styled was the one the SYSTEM builds inside `.datePickerStyle(.compact)`;
        // the content below is an ordinary view hierarchy this file owns, so the background,
        // scheme pin and foreground reset apply to it exactly as they did to the sheet.
        .popover(isPresented: $showingDayCalendar, arrowEdge: .bottom) { dayCalendarPopover }
    }

    private var dayCalendarPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            dayCalendarHeader
            DatePicker("Entry date", selection: $date, in: ...Date(),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
        }
        .padding(16)
        .frame(minWidth: 320)
        // The three modifiers that make this popover self-consistent no matter what does or
        // does not propagate into it from the capture screen.
        //
        // `Color.primary` first, because the leak is the known bug, not a theory: this screen
        // sets `.foregroundStyle(.white)` for its near-black surface, and that white is
        // inherited into nested builders — it is exactly what made the New Journal text field
        // white-on-white (owner smoke, 2026-08-15). Under the dark pin below, `Color.primary`
        // resolves to white, so the reset both neutralises the leak and colours the popover
        // correctly rather than fighting it.
        //
        // The tint reset matters for the same reason it does on the segmented control: the
        // graphical calendar fills the selected day with the tint, and a white fill under a
        // white numeral is an unreadable selection.
        //
        // Then the surface itself, so nothing here rests on the system's own material.
        .foregroundStyle(Color.primary)
        .tint(Color.accentColor)
        .background(Color(white: CaptureSurface.backgroundWhite))
        .environment(\.colorScheme, .dark)
    }

    /// Month and year dropdowns above the calendar.
    ///
    /// Owner smoke, 2026-08-16: "if you want to pick a day in a past year it's not very
    /// straightforward, as there is no year picker in the day picker — you have to scroll
    /// back month by month." macOS's `.graphical` DatePicker offers only prev/next arrows, so
    /// an 1998 journal page is roughly 340 clicks away. His own workaround — drop to Year
    /// precision, pick the year, switch back to Day — is the proof that the controls already
    /// existed; they simply were not offered where the work happens.
    ///
    /// These are the SAME `monthPicker`/`yearPicker` the reduced precisions use, bound
    /// through `componentBinding` to the same `date` the calendar below reads, which is what
    /// makes the calendar follow them rather than sitting on a stale month.
    private var dayCalendarHeader: some View {
        HStack(spacing: 12) {
            monthPicker
            yearPicker
        }
    }
    #endif

    private func componentBinding(_ component: Calendar.Component) -> Binding<Int> {
        Binding(
            get: { calendar.component(component, from: date) },
            set: { date = Self.adjusted(date, setting: component, to: $0,
                                        precision: precision, calendar: calendar) })
    }

    /// Setting one component of a date, at a given precision — pure, so the calendar
    /// arithmetic below is testable without a view.
    ///
    /// `Calendar.date(from:)` is LENIENT: day 31 with the month set to February does not
    /// clamp, it rolls forward to March 3. The reduced precisions were always safe from that
    /// because they overwrite the day with 1 anyway — but `.day`, the one precision that
    /// KEEPS its day, was unguarded. That was harmless only for as long as no UI could change
    /// the month at `.day` precision. `dayCalendarHeader` now can, so the clamp is real work,
    /// not defensive decoration.
    ///
    /// Noon, not midnight, for the reduced precisions: parking a reduced-precision date on a
    /// midnight boundary flips its displayed year/month under a more-westward timezone.
    static func adjusted(_ date: Date,
                         setting component: Calendar.Component,
                         to newValue: Int,
                         precision: DatePrecision,
                         calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        switch component {
        case .month: comps.month = newValue
        case .year: comps.year = newValue
        default: break
        }
        switch precision {
        case .year:
            comps = DateComponents(year: comps.year, month: 1, day: 1, hour: 12)
        case .yearMonth:
            comps = DateComponents(year: comps.year, month: comps.month, day: 1, hour: 12)
        case .day:
            // Clamp into the target month rather than letting the roll-forward happen. The
            // day the owner is looking at on paper is the one thing here he actually knows;
            // silently moving him to the 3rd of the next month is the worst available answer.
            if let day = comps.day,
               let monthStart = calendar.date(from: DateComponents(year: comps.year,
                                                                   month: comps.month, day: 1)),
               let span = calendar.range(of: .day, in: .month, for: monthStart) {
                comps.day = min(day, span.upperBound - 1)
            }
        }
        return calendar.date(from: comps) ?? date
    }
}
