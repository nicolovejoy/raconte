import SwiftUI

/// The Search place (#194): a search field, a journal chip and a date chip under it, and the
/// results as rows that open their entry.
///
/// Everything the list shows is `SearchScreenModel`'s: the view sets the text and the two
/// filters and reads back `results`, `hasQuery`, `showsNoMatches` and `unavailableReason`.
/// Between a keystroke and its answer the list keeps whatever results are on hand and shows
/// neither the hint nor "No matches".
///
/// A result opens its entry the way a library row does, as a `NavigationLink` value on the
/// detail stack, so the stack does the push in its own transaction.
struct SearchView: View {
    @Bindable var model: SearchScreenModel
    let library: LibraryScreenModel
    let router: AppRouter

    @FocusState private var fieldFocused: Bool
    @State private var editingCustomDates = false
    @State private var showsIndexing = false

    /// How long a reconcile must have been running before "Indexing…" shows. The launch scan
    /// and every sync landing run a short one, and a footer bound straight to
    /// `searchIndexing` would flicker on each.
    static let indexingFooterDelay: Duration = .milliseconds(750)

    var body: some View {
        List {
            if let reason = model.unavailableReason {
                unavailableRow(reason)
            } else {
                if !model.hasQuery {
                    Text("Search your transcripts")
                        .font(TypeRole.body.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .listRowBackground(InkTone.paper.color)
                        .accessibilityIdentifier("search.empty")
                } else if model.showsNoMatches {
                    Text("No matches")
                        .font(TypeRole.body.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .listRowBackground(InkTone.paper.color)
                        .accessibilityIdentifier("search.noMatches")
                } else {
                    ForEach(model.results) { result in
                        resultLink(result)
                    }
                }
                if showsIndexing {
                    Text("Indexing…")
                        .font(TypeRole.label.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .listRowBackground(InkTone.paper.color)
                        .accessibilityIdentifier("search.indexing")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(InkTone.paper.color)
        .accessibilityIdentifier("search.field")
        .safeAreaInset(edge: .top) {
            if model.unavailableReason == nil { chips }
        }
        .navigationTitle("Search")
        .searchable(text: $model.text, placement: .automatic, prompt: "Search transcripts")
        .searchFocused($fieldFocused)
        // Arrival (`SearchScreenModel.arrived`, fired by the router) seeds the scope and asks
        // for focus; this only honours the ask. `onAppear` also fires on Back from an opened
        // result, which is not an arrival, so this does not focus the field there. (iOS's own
        // search controller still restores a field that was active when the result opened:
        // measured on the simulator with every line of focus code here removed.)
        .onAppear {
            if model.takeFieldFocusRequest() { fieldFocused = true }
        }
        .onChange(of: router.searchFieldFocusRequest) { _, _ in fieldFocused = true }
        .task(id: library.searchIndexing) {
            guard library.searchIndexing else {
                showsIndexing = false
                return
            }
            try? await Task.sleep(for: Self.indexingFooterDelay)
            guard !Task.isCancelled else { return }
            showsIndexing = true
        }
        // On the screen's outer view, never a Section (a Section's sheet never presents).
        .sheet(isPresented: $editingCustomDates) {
            SearchCustomDatesSheet(initial: model.dateFilter) { model.dateFilter = $0 }
        }
    }

    private func resultLink(_ result: SearchResult) -> some View {
        NavigationLink(value: LibraryDestination.entry(result.id)) {
            SearchResultRow(result: result)
        }
        // On the link, not the row: a NavigationLink merges its label into one element.
        .accessibilityIdentifier("search.result.\(result.id)")
        .listRowBackground(InkTone.paper.color)
    }

    private func unavailableRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Search is unavailable")
                .font(TypeRole.body.font)
                .foregroundStyle(InkTone.ink.color)
            Text(reason)
                .font(TypeRole.footnote.font)
                .foregroundStyle(InkTone.inkSecondary.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.unavailable")
        .listRowBackground(InkTone.paper.color)
    }

    // MARK: Chips

    /// Text-only labels: macOS paints an `Image` in a `Menu` label at its intrinsic size (#69).
    private var chips: some View {
        HStack(spacing: 8) {
            Menu {
                journalItems
            } label: {
                chipLabel(SearchScreenModel.journalScopeTitle(model.journalScope, in: library.journals))
            }
            .accessibilityIdentifier("search.chip.journal")

            Menu {
                dateItems
            } label: {
                chipLabel(model.dateFilter.title)
            }
            .accessibilityIdentifier("search.chip.date")

            Spacer(minLength: 0)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(InkTone.paper.color)
    }

    private func chipLabel(_ title: String) -> some View {
        Text(title)
            .font(TypeRole.secondary.font)
            .lineLimit(1)
    }

    @ViewBuilder
    private var journalItems: some View {
        Button("All journals") { model.journalScope = .all }
            .accessibilityIdentifier("search.chip.journal.all")
        if !library.journals.isEmpty {
            Divider()
        }
        // `library.journals` is already in display order.
        ForEach(library.journals) { journal in
            Button(journal.name) { model.journalScope = .journal(journal.id) }
                .accessibilityIdentifier("search.chip.journal.item.\(journal.id)")
        }
    }

    @ViewBuilder
    private var dateItems: some View {
        Button("Any time") { model.dateFilter = .anyTime }
            .accessibilityIdentifier("search.chip.date.anyTime")
        Button("This year") { model.dateFilter = .thisYear }
            .accessibilityIdentifier("search.chip.date.thisYear")
        Button("Last year") { model.dateFilter = .lastYear }
            .accessibilityIdentifier("search.chip.date.lastYear")
        Divider()
        Button("Custom…") { editingCustomDates = true }
            .accessibilityIdentifier("search.chip.date.custom")
    }
}

/// The date chip's Custom… sheet: an optional start and an optional end, each a
/// `PrecisionDatePicker` (the field `JournalSpanEditor` uses), so either end can be a day, a
/// month or a year. Done writes `SearchDateFilter.choosing(from:to:)` — custom, or Any time
/// with both ends off; each bound is a whole unit. An end before the start is refused with a
/// message, never swapped.
struct SearchCustomDatesSheet: View {
    let initial: SearchDateFilter
    let onDone: (SearchDateFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasFrom = false
    @State private var fromDate = Date()
    @State private var fromPrecision: DatePrecision = .year
    @State private var hasUntil = false
    @State private var untilDate = Date()
    @State private var untilPrecision: DatePrecision = .year

    private let calendar = Calendar.gregorianCurrent

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("From", isOn: $hasFrom)
                        .accessibilityIdentifier("search.dates.hasFrom")
                    if hasFrom {
                        PrecisionDatePicker(date: $fromDate, precision: $fromPrecision, idPrefix: "searchFrom")
                    }
                }
                Section {
                    Toggle("Until", isOn: $hasUntil)
                        .accessibilityIdentifier("search.dates.hasUntil")
                    if hasUntil {
                        PrecisionDatePicker(date: $untilDate, precision: $untilPrecision, idPrefix: "searchUntil")
                    }
                    if isInverted {
                        Text("The end is before the start.")
                            .font(TypeRole.footnote.font)
                            .foregroundStyle(InkTone.warning.color)
                            .accessibilityIdentifier("search.dates.inverted")
                    }
                }
            }
            .navigationTitle("Custom Dates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(.choosing(from: from, to: until))
                        dismiss()
                    }
                    .disabled(isInverted)
                    .accessibilityIdentifier("search.dates.done")
                }
            }
        }
        .onAppear(perform: populate)
        #if os(macOS)
        // An unsized macOS sheet collapses to its intrinsic height (JournalPickerSheet).
        .frame(minWidth: 400, minHeight: 360)
        #endif
    }

    private var from: PartialDate? {
        hasFrom ? PartialDate(from: fromDate, precision: fromPrecision, calendar: calendar) : nil
    }

    private var until: PartialDate? {
        hasUntil ? PartialDate(from: untilDate, precision: untilPrecision, calendar: calendar) : nil
    }

    /// `JournalSpan` owns the unit-wise rule for an end before a start.
    private var isInverted: Bool {
        guard let from, let until else { return false }
        return (try? JournalSpan(start: from, end: until)) == nil
    }

    private func populate() {
        guard case .custom(let from, let until) = initial else { return }
        if let from {
            hasFrom = true
            fromDate = from.anchorDate(calendar: calendar)
            fromPrecision = from.precision
        }
        if let until {
            hasUntil = true
            untilDate = until.anchorDate(calendar: calendar)
            untilPrecision = until.precision
        }
    }
}
