import SwiftUI

/// One entry, full detail (M3 T4, phone mockup): both dates clearly labeled, journal,
/// duration, playback (the same `CapturePlayback` / `PlaybackProgressLine` machinery —
/// playback lives only here since M3 T4.5 removed it from the capture screen's recent
/// section), and the committed transcript as serif prose. Journal and backdate are
/// editable here through
/// `LibraryScreenModel`, which owns the one `EntryMetadataStore` instance both this screen
/// and the library list read and write through.
///
/// Holds its own `item` rather than reading `model.item(captureID)` directly: after a
/// journal reassignment the entry may fall outside the library's current filter scope and
/// vanish from `model.items` entirely, but the detail screen the owner is looking at must
/// keep showing it. `refresh()` adopts the model's copy when it still has one and otherwise
/// keeps the last-known state.
struct EntryDetailView: View {
    let model: LibraryScreenModel
    let captureID: String

    @State private var item: EntryListItem
    @State private var playback: CapturePlayback?
    @State private var transcript = EntryTranscript(state: .absent, text: nil, degradations: [])
    @State private var showingBackdatePicker = false
    @State private var backdateDraft = Date()
    @State private var backdatePrecisionDraft: DatePrecision = .day
    @State private var showingTrashConfirmation = false

    @Environment(\.dismiss) private var dismiss

    init(model: LibraryScreenModel, item: EntryListItem) {
        self.model = model
        self.captureID = item.captureID
        _item = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                datesSection
                journalSection
                playbackSection
                transcriptSection
                trashSection
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.formattedEffectiveDate())
        .task { await refresh() }
        // No `deinit` on `CapturePlayback` stops the audio, and a `@State` value outlives
        // the pop by however long SwiftUI holds it — without this, backing out of a
        // playing entry keeps playing.
        .onDisappear { playback?.stop() }
        .sheet(isPresented: $showingBackdatePicker) { backdateSheet }
        .confirmationDialog("Move this entry to the trash?",
                            isPresented: $showingTrashConfirmation,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
                .accessibilityIdentifier("detail.confirmTrash")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore it from the Trash for \(TrashPolicy.retentionDays) days.")
        }
    }

    /// Both loads are off the main actor: the transcript is an O(records) parse and
    /// `CapturePlayback`'s convenience init walks the whole captures tree. Opening an
    /// entry used to do both synchronously while the screen was on screen.
    private func refresh() async {
        if let latest = model.item(captureID) { item = latest }
        transcript = await model.transcript(for: captureID)
        if playback == nil {
            playback = await CapturePlayback.load(capturesRoot: model.capturesRoot,
                                                  captureID: captureID)
        }
    }

    // MARK: - Dates

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledRow("Entry date", item.formattedEffectiveDate(dayStyle: .long))
                .accessibilityIdentifier("detail.originalDate")
            labeledRow("Recorded", item.capturedAt.formatted(date: .long, time: .shortened))
                .accessibilityIdentifier("detail.capturedAt")

            // No standalone Clear (owner, 2026-08-02): a set backdate is typed intent,
            // and one stray tap must not erase it. Clearing lives inside the sheet as
            // an explicit destructive action.
            Button(item.isBackdated ? "Change backdate…" : "Backdate this entry…") {
                // `anchorDate`, not `effectiveDate`: both currently agree (there is no
                // "unnormalized" `Date` left to prefer — `PartialDate` never carried
                // more precision than it declares), but anchoring explicitly here keeps
                // this call site correct if `effectiveDate` ever grows a different rule.
                backdateDraft = item.originalDate?.anchorDate(calendar: .gregorianCurrent) ?? item.capturedAt
                backdatePrecisionDraft = item.originalDatePrecision
                showingBackdatePicker = true
            }
            .accessibilityIdentifier("detail.backdateButton")
            .font(.caption)
        }
    }

    private var backdateSheet: some View {
        NavigationStack {
            PrecisionDatePicker(date: $backdateDraft, precision: $backdatePrecisionDraft,
                                idPrefix: "detail", dayPickerStyle: .graphical)
                .padding()
                .accessibilityIdentifier("detail.backdatePicker")
                .navigationTitle("Backdate")
                .toolbar {
                    if item.isBackdated {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove backdate", role: .destructive) {
                                showingBackdatePicker = false
                                Task { await model.setBackdate(captureID, to: nil); await refresh() }
                            }
                            .accessibilityIdentifier("detail.clearBackdateButton")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let date = backdateDraft
                            let precision = backdatePrecisionDraft
                            showingBackdatePicker = false
                            Task { await model.setBackdate(captureID, to: date, precision: precision); await refresh() }
                        }
                        .accessibilityIdentifier("detail.backdateSave")
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingBackdatePicker = false }
                    }
                }
        }
    }

    // MARK: - Journal

    private var journalSection: some View {
        HStack {
            Text("Journal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            // No "Unfiled" choice, deliberately: the M3 decision is that nil journalID
            // exists only for legacy/degraded entries, and no UI path creates it. An
            // already-unfiled entry still *displays* as "Unfiled" until it's filed.
            Menu {
                ForEach(model.journals) { journal in
                    Button(journal.name) {
                        Task { await model.moveEntry(captureID, toJournal: journal.id); await refresh() }
                    }
                }
            } label: {
                Text(item.journal?.name ?? "Unfiled")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("detail.journalPicker")
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: (playback?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.play")

            if let playback {
                PlaybackProgressLine(playback: playback, idPrefix: "detail")
            }
        }
    }

    private func togglePlayback() {
        guard let playback else { return }
        if playback.isPlaying { playback.pause() } else { playback.play() }
    }

    // MARK: - Transcript

    /// Absent / unreadable / present-but-empty are three distinct, calm answers — issue
    /// #11's rule, one layer up from the log reader that first drew this line. A short
    /// tail is a fourth: the text is real and there may simply be less of it than was
    /// spoken, which the library row already marks and this screen used not to.
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            switch transcript.state {
            case .absent:
                Text("This entry was not transcribed.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.absent")
            case .unreadable:
                Text("The transcript could not be read.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.unreadable")
            case .present:
                if let text = transcript.text, !text.isEmpty {
                    Text(text)
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("detail.transcript.text")
                } else {
                    Text("No speech was transcribed.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.transcript.empty")
                }
            }

            if transcript.isTruncated {
                Text("The end of this transcript is missing — the app closed before it "
                     + "finished writing. The recording itself is complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.truncated")
            }
        }
    }

    // MARK: - Trash

    /// Bottom of the screen, quiet, and behind a confirmation — but present on every
    /// entry on every platform, per the M3 decision that deletion works anywhere.
    private var trashSection: some View {
        Button("Move to Trash", role: .destructive) { showingTrashConfirmation = true }
            .font(.caption)
            .accessibilityIdentifier("detail.trashButton")
    }

    /// Stop playback and pop **before** the write. `ContentView`'s destination renders
    /// this screen only while `library.item(captureID)` resolves, and the rescan inside
    /// `trashEntry` republishes the lists — leaving the pop until afterwards means the
    /// screen the owner is looking at is briefly a view of an entry that is no longer in
    /// the list it was pushed from.
    private func moveToTrash() {
        playback?.stop()
        dismiss()
        Task { await model.trashEntry(captureID) }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}
