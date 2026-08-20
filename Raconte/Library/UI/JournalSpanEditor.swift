import SwiftUI

/// `PrecisionDatePicker` speaks (`Date`, `DatePrecision`); the registry speaks
/// `PartialDate`. This is that conversion, kept out of the view so it can be tested —
/// getting it wrong looks right on screen and is wrong on disk.
enum JournalSpanEditorModel {
    static func span(startDate: Date, startPrecision: DatePrecision,
                     endDate: Date, endPrecision: DatePrecision,
                     isOpenEnded: Bool,
                     calendar: Calendar = .gregorianCurrent) throws -> JournalSpan? {
        let start = PartialDate(from: startDate, precision: startPrecision, calendar: calendar)
        guard !isOpenEnded else { return try JournalSpan(start: start, end: nil) }
        let end = PartialDate(from: endDate, precision: endPrecision, calendar: calendar)
        return try JournalSpan(start: start, end: end)
    }
}

/// The span the paper journal covers (spec ruling 2), editable in `JournalEditorView`
/// (Task 6). Three states, no dead end between them:
/// - **No span** — the "This journal covers a date range" toggle is off. Nothing is
///   dialed in; `dateLine` falls back to the derived range.
/// - **Open-ended** — a start is set, "Still being written" is on. The natural state for
///   a journal currently in progress: the owner knows where it started, not where (or
///   whether) it will end.
/// - **Closed** — start and end both set.
/// Turning the top toggle off clears the span back to nil from any state (never a one-way
/// door); turning "Still being written" off/on preserves whatever end date was last
/// entered rather than resetting it, so toggling it by accident costs nothing.
///
/// **Inverted input (end before start) is refused with a visible message, never silently
/// swapped or clamped** — this project's rule is "say what is true, refuse nothing" as a
/// promise to the user (never silently discard their input), which here means: show
/// exactly why the pair doesn't parse, and decline to persist it, rather than guessing
/// what they meant. The last valid span already on disk stays there untouched until the
/// pair becomes valid again.
struct JournalSpanEditor: View {
    let initial: JournalSpan?
    let onChange: (JournalSpan?) -> Void

    @State private var hasSpan = false
    @State private var startDate = Date()
    @State private var startPrecision: DatePrecision = .year
    @State private var isOpenEnded = true
    @State private var endDate = Date()
    @State private var endPrecision: DatePrecision = .year
    @State private var errorText: String?
    /// Guards the burst of `onChange` firings `onAppear` itself triggers while seeding
    /// state from `initial` — without it, opening the editor on an already-spanned
    /// journal would immediately re-write the exact value it just read.
    @State private var isPopulating = true

    private let calendar = Calendar.gregorianCurrent

    var body: some View {
        Section {
            Toggle("This journal covers a date range", isOn: $hasSpan)
                .accessibilityIdentifier("journalSpanEditor.hasSpan")

            if hasSpan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    PrecisionDatePicker(date: $startDate, precision: $startPrecision,
                                        idPrefix: "journalSpanStart")
                }

                Toggle("Still being written", isOn: $isOpenEnded)
                    .accessibilityIdentifier("journalSpanEditor.openEnded")

                if !isOpenEnded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("End").font(.caption).foregroundStyle(.secondary)
                        PrecisionDatePicker(date: $endDate, precision: $endPrecision,
                                            idPrefix: "journalSpanEnd")
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("journalSpanEditor.error")
                }
            }
        } header: {
            Text("Date Range")
        } footer: {
            if hasSpan {
                Text("The range the paper journal itself covers, independent of how much you’ve read in so far.")
            }
        }
        .onAppear { populate() }
        .onChange(of: hasSpan) { _, _ in commit() }
        .onChange(of: startDate) { _, _ in commit() }
        .onChange(of: startPrecision) { _, _ in commit() }
        .onChange(of: isOpenEnded) { _, _ in commit() }
        .onChange(of: endDate) { _, _ in commit() }
        .onChange(of: endPrecision) { _, _ in commit() }
        // Safety net for the same reason `JournalEditorView` needs one: a sidebar/⌘-place
        // switch tears this view down synchronously, with no guaranteed onChange in
        // between. Unstructured `Task`, not `.task`, so the write outlives the pop.
        .onDisappear { commit() }
    }

    private func populate() {
        if let initial {
            hasSpan = true
            startDate = initial.start.anchorDate(calendar: calendar)
            startPrecision = initial.start.precision
            if let end = initial.end {
                isOpenEnded = false
                endDate = end.anchorDate(calendar: calendar)
                endPrecision = end.precision
            } else {
                isOpenEnded = true
            }
        } else {
            hasSpan = false
            startDate = Date()
            startPrecision = .year
            isOpenEnded = true
            endDate = Date()
            endPrecision = .year
        }
        errorText = nil
        isPopulating = false
    }

    private func commit() {
        guard !isPopulating else { return }

        guard hasSpan else {
            errorText = nil
            onChange(nil)
            return
        }

        do {
            let span = try JournalSpanEditorModel.span(
                startDate: startDate, startPrecision: startPrecision,
                endDate: endDate, endPrecision: endPrecision,
                isOpenEnded: isOpenEnded, calendar: calendar)
            errorText = nil
            onChange(span)
        } catch {
            // Refuse, don't swap: the pair the owner just entered doesn't parse as a
            // range, so nothing is written — whatever span was valid before stays on
            // disk untouched.
            errorText = "The end date is before the start date. Fix one of them to save this range."
        }
    }
}
