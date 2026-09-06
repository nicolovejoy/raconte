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
/// discipline `BackdateEditorContent` already uses: each field commits
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
    @State private var showingCoverPicker = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteFailed = false
    @FocusState private var nameFocused: Bool

    private var journal: Journal? { model.journals.first { $0.id == journalID } }
    private var entryCount: Int {
        model.entryCount(forJournal: journalID)
    }
    private var trashedCount: Int {
        model.trashed.filter { $0.journalID == journalID }.count
    }

    /// #80, owner ruling 1 (empty = zero live AND zero trashed entries) / ruling 2
    /// (always visible, reason spelled out when refused). The logic itself lives in
    /// `JournalDeleteEligibility.blockedReason` — pure, exhaustively unit-tested,
    /// including the trashed-only case this view alone cannot pin. See that type's doc
    /// comment for the drift risk against `LibraryScreenModel.isJournalEmpty`.
    private var deleteBlockedReason: String? {
        JournalDeleteEligibility.blockedReason(
            journalCount: model.journals.count,
            entryCount: entryCount,
            trashedCount: trashedCount,
            // The model's own rule, not a second copy of it (gate findings Important 2
            // and 3): without this the row would offer Delete while the authoritative
            // guard refuses it, which reads as a broken button.
            hasIndeterminateContent: model.hasIndeterminateContent(forJournal: journalID))
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

                // Field order: name -> cover -> span -> voice labels -> derived (design
                // doc, editor field order). Task 7 originally mounted span above voice
                // labels but below cover's intended slot; its review flagged the miss
                // without fixing it, so this task also moves span/voice-labels into the
                // right order while landing the cover row.
                Section("Cover") {
                    if let cover = model.journalCovers[journalID] {
                        JournalCoverPreview(data: cover)
                            .listRowInsets(EdgeInsets())
                        Button("Replace…") { showingCoverPicker = true }
                            .accessibilityIdentifier("journalEditor.cover.replace")
                        Button("Remove", role: .destructive) {
                            Task { await model.removeJournalCover(journalID) }
                        }
                        .accessibilityIdentifier("journalEditor.cover.remove")
                    } else {
                        Button("Add a cover photo…") { showingCoverPicker = true }
                            .accessibilityIdentifier("journalEditor.cover.add")
                    }
                }

                JournalSpanEditor(initial: journal.span) { newSpan in
                    commitSpan(newSpan)
                }

                // Focus for the two label fields lives entirely inside the section (one
                // shared enum, two cases) — it notifies us only that SOME field lost
                // focus, via `onFieldCommit`, so this view never needs to know which.
                JournalVoiceLabelsSection(mainLabel: $draftMainLabel,
                                          alternativeLabel: $draftAlternativeLabel,
                                          onFieldCommit: commitVoiceLabels)

                Section {
                    // The one place the stored span and what is ACTUALLY in the journal
                    // are visible together (design, Display rules). Read-only on purpose:
                    // the derived range is a fact about the entries, not a setting. Routes
                    // through the model's own derived-range primitive rather than
                    // recomputing `JournalDateRange` here — `dateLine(forJournal:)` is
                    // the span-first blend `SidebarView`/`LibraryCoverBand` show; this
                    // row is deliberately the OTHER half, since Task 7's span section is
                    // the one place the stored span itself becomes editable.
                    Text(derivedSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("journalEditor.derived")
                }

                // Owner-ruled shape (#80, ruling 2): a destructive row at the bottom of
                // the editor behind a confirmation dialog — NOT a sidebar swipe action.
                // The row itself stays on-screen and queryable even when refused; only
                // `.disabled` changes, with the footer explaining why. Never absent —
                // an absent control cannot be discovered, let alone understood.
                Section {
                    Button("Delete Journal", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .disabled(deleteBlockedReason != nil)
                    .accessibilityIdentifier("journalEditor.delete")
                } footer: {
                    if let reason = deleteBlockedReason {
                        Text(reason)
                            .accessibilityIdentifier("journalEditor.delete.reason")
                    }
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
            // Attached to the Form itself, never to a `Section` — a `.confirmationDialog`
            // (like `.sheet`, below) attached to a `Section` silently never presents on
            // iOS 26; this project has already paid for that trap once (#68's cover
            // sheet class of bug). `journal.name` here reads the live value at the
            // moment the dialog is shown, since it is still non-nil whenever this
            // button was reachable to tap.
            .confirmationDialog("Delete \u{201C}\(journal.name)\u{201D}?",
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete Journal", role: .destructive) {
                    Task {
                        if await model.deleteJournal(journalID) == false {
                            deleteFailed = true
                        }
                    }
                }
                .accessibilityIdentifier("journalEditor.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: {
                // Deliberately NOT "this can't be undone" (gate finding, Minor 2): owner
                // ruling 3 accepts that another device which edits this journal while
                // offline will re-push it and bring it back — last-writer-wins on the
                // record's existence, no delete tombstone (`SyncRecordExchange
                // .acceptRemoteJournalDeletion`). Promising irreversibility here would be
                // literally untrue.
                Text("The journal is removed from this device and your others.")
            }
            .alert("Couldn’t delete this journal", isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            }
            // #68: this sheet renders EMPTY on macOS — the PhotosPicker row is absent,
            // so the Mac currently has no way to set a cover at all now that the
            // capture-screen route is gone. Accepted by the owner (spec ruling 9) and
            // tracked separately; do not paper over it here.
            .sheet(isPresented: $showingCoverPicker) {
                // Reset the inherited foreground — the sheet draws on system material,
                // the same treatment the capture screen gave it before Task 1 removed
                // that route.
                JournalCoverPickerSheet(
                    journalName: journal.name,
                    currentCover: model.journalCovers[journalID],
                    onPick: { data in
                        do {
                            try await model.setJournalCover(journalID, imageData: data)
                            return true
                        } catch {
                            return false
                        }
                    },
                    onRemove: { await model.removeJournalCover(journalID) })
                    .foregroundStyle(Color.primary)
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
    ///
    /// Value-changed guard mirrors `commitName`/`commitVoiceLabels` above (gate F1, for
    /// #70): `JournalSpanEditor.commit()` fires unconditionally from `onDisappear`, so
    /// simply opening a journal's editor and navigating away — for an unrelated reason,
    /// e.g. a rename — would otherwise re-stamp `modified["span"]` with `now()` for a
    /// value that never changed. That stamp can then beat a genuinely older but real span
    /// edit from an offline peer in the LWW merge, discarding it. `JournalStore.setSpan`
    /// carries the same guard as a second, store-layer chokepoint (any caller, not just
    /// this view).
    private func commitSpan(_ span: JournalSpan?) {
        guard let journal, journal.span != span else { return }
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
