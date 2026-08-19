import SwiftUI

/// Everything about a journal that is not its entries (journal-editing IA design, Surfaces
/// item 3). Pushed, not presented: it holds enough to make a sheet cramped, and this
/// project has had repeated trouble with sheets on macOS — #68's empty cover picker, the
/// Debug modal with no dismiss affordance that also blocked ⌘Q, and the backdate sheet
/// that had to become a popover before Escape and click-away worked.
///
/// **Writes through on commit, never behind a Done button.**
/// `PlaceRouting.detailPath(afterSelecting:from:path:)` always returns `[]`, so ANY
/// sidebar click, and on the Mac ⌘1-4, pops this screen with no warning and no chance to
/// intervene. A Done-button-shaped batch of unsaved edits would be silently lost. Same
/// discipline `BackdateField`/`BackdateEditorContent` already use: each field commits
/// itself. Two commit paths, deliberately redundant:
/// - Losing focus (the field the owner just left, via `focusedField`'s `onChange`) — the
///   ordinary case, fires the instant a real tap moves elsewhere on THIS screen.
/// - `onDisappear` — the safety net for the case this screen exists to guard against: the
///   screen is torn down by a sidebar/⌘-place switch before a focus-loss event has any
///   chance to fire. Fires an unstructured `Task`, not `.task` (which SwiftUI cancels on
///   disappear) — the same shape that let a transcript-editor draft survive its entry
///   being popped from underneath it (nav branch, Gate B).
struct JournalEditorView: View {
    let model: LibraryScreenModel
    let journalID: String

    @State private var draftName = ""
    @State private var draftMainLabel = ""
    @State private var draftAlternativeLabel = ""
    @State private var renameFailed = false
    @State private var voiceLabelsFailed = false
    @State private var spanFailed = false
    @FocusState private var nameFocused: Bool

    private var journal: Journal? { model.journals.first { $0.id == journalID } }
    private var entryCount: Int {
        model.allEntries.filter { $0.journalID == journalID }.count
    }

    var body: some View {
        if let journal {
            Form {
                Section("Name") {
                    TextField("Journal name", text: $draftName)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .accessibilityIdentifier("journalEditor.name")
                }

                // Focus for the two label fields lives entirely inside the section (one
                // shared enum, two cases) — it notifies us only that SOME field lost
                // focus, via `onFieldCommit`, so this view never needs to know which.
                JournalVoiceLabelsSection(mainLabel: $draftMainLabel,
                                          alternativeLabel: $draftAlternativeLabel,
                                          onFieldCommit: commitVoiceLabels)

                JournalSpanEditor(initial: journal.span) { newSpan in
                    commitSpan(newSpan)
                }

                // Task 8 inserts the cover section here.

                Section {
                    // The one place the stored span and what is ACTUALLY in the journal
                    // are visible together (design, Display rules). Read-only on purpose:
                    // the derived range is a fact about the entries, not a setting. Routes
                    // through the model's own derived-range primitive rather than
                    // recomputing `JournalDateRange` here — `dateLine(forJournal:)` is
                    // the span-first blend `SidebarView`/`JournalHeaderCard` show; this
                    // row is deliberately the OTHER half, since Task 7's span section is
                    // the one place the stored span itself becomes editable.
                    Text(derivedSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("journalEditor.derived")
                }
            }
            .navigationTitle(journal.name)
            .onAppear {
                draftName = journal.name
                draftMainLabel = journal.voiceLabels[VoiceDisplay.mainVoice] ?? ""
                draftAlternativeLabel = journal.voiceLabels[VoiceDisplay.other(VoiceDisplay.mainVoice)] ?? ""
            }
            // Focus loss is a commit, not a discard — see the type comment above.
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }
            // Safety net, see the type comment above: a sidebar click clears
            // `router.detailPath` synchronously, tearing this screen down without ever
            // routing focus through the `onChange` above. Unstructured `Task`, so it
            // outlives the view.
            .onDisappear {
                commitName()
                commitVoiceLabels()
            }
            .alert("Couldn’t rename this journal", isPresented: $renameFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert("Couldn’t save voice labels", isPresented: $voiceLabelsFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert("Couldn’t save this date range", isPresented: $spanFailed) {
                Button("OK", role: .cancel) {}
            }
        } else {
            // Deleted underneath us. Never a blank push — same treatment ContentView
            // gives a missing entry (issue #32's rule).
            ContentUnavailableView("Journal Unavailable",
                                   systemImage: "books.vertical",
                                   description: Text("This journal is no longer in your library."))
                .accessibilityIdentifier("journalEditor.unavailable")
        }
    }

    private var derivedSummary: String {
        let count = entryCount == 1 ? "1 entry" : "\(entryCount) entries"
        guard let derived = model.dateRange(forJournal: journalID) else {
            return "\(count) recorded so far."
        }
        return "\(count) recorded so far, covering \(derived.formatted())."
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let journal, !trimmed.isEmpty, trimmed != journal.name else { return }
        Task {
            if await model.renameJournal(journalID, to: trimmed) == false {
                renameFailed = true
                draftName = journal.name
            }
        }
    }

    /// `JournalSpanEditor` already refused an inverted pair itself (never calls this with
    /// one) — the only failure reachable here is the store rejecting an unknown journal
    /// id, i.e. this journal was deleted out from under an open editor. No draft to reset
    /// on failure: the span editor owns its own field state, not this view.
    private func commitSpan(_ span: JournalSpan?) {
        guard journal != nil else { return }
        Task {
            if await model.setJournalSpan(journalID, span: span) == false {
                spanFailed = true
            }
        }
    }

    private func commitVoiceLabels() {
        guard let journal else { return }
        let main = draftMainLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = draftAlternativeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var labels: [String: String] = [:]
        if !main.isEmpty { labels[VoiceDisplay.mainVoice] = main }
        if !alternative.isEmpty { labels[VoiceDisplay.other(VoiceDisplay.mainVoice)] = alternative }
        guard labels != journal.voiceLabels else { return }
        Task {
            if await model.setJournalVoiceLabels(journalID, labels: labels) == false {
                voiceLabelsFailed = true
                draftMainLabel = journal.voiceLabels[VoiceDisplay.mainVoice] ?? ""
                draftAlternativeLabel = journal.voiceLabels[VoiceDisplay.other(VoiceDisplay.mainVoice)] ?? ""
            }
        }
    }
}
