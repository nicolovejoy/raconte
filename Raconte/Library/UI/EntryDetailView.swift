import SwiftUI

/// One entry, full detail (M3 T4, phone mockup): both dates clearly labeled, journal,
/// duration, playback (the same `CapturePlayback` / `PlaybackProgressLine` machinery
/// `FinishedRow` uses on the capture screen — no second implementation), and the
/// committed transcript as serif prose. Journal and backdate are editable here through
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
    @State private var transcriptState: EntryTranscriptState = .absent
    @State private var transcriptText: String?
    @State private var showingBackdatePicker = false
    @State private var backdateDraft = Date()

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
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.effectiveDate.formatted(date: .abbreviated, time: .omitted))
        .onAppear { refresh() }
        .sheet(isPresented: $showingBackdatePicker) { backdateSheet }
    }

    private func refresh() {
        if let latest = model.item(captureID) { item = latest }
        let loaded = model.transcriptText(for: captureID)
        transcriptState = loaded.state
        transcriptText = loaded.text
        if playback == nil {
            playback = CapturePlayback(capturesRoot: model.capturesRoot, captureID: captureID)
        }
    }

    // MARK: - Dates

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledRow("Entry date", item.effectiveDate.formatted(date: .long, time: .omitted))
                .accessibilityIdentifier("detail.originalDate")
            labeledRow("Recorded", item.capturedAt.formatted(date: .long, time: .shortened))
                .accessibilityIdentifier("detail.capturedAt")

            HStack(spacing: 12) {
                Button(item.isBackdated ? "Change backdate…" : "Backdate this entry…") {
                    backdateDraft = item.effectiveDate
                    showingBackdatePicker = true
                }
                .accessibilityIdentifier("detail.backdateButton")

                if item.isBackdated {
                    Button("Clear", role: .destructive) {
                        Task { await model.setBackdate(captureID, to: nil); refresh() }
                    }
                    .accessibilityIdentifier("detail.clearBackdateButton")
                }
            }
            .font(.caption)
        }
    }

    private var backdateSheet: some View {
        NavigationStack {
            DatePicker("Entry date", selection: $backdateDraft, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .padding()
                .accessibilityIdentifier("detail.backdatePicker")
                .navigationTitle("Backdate")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let date = backdateDraft
                            showingBackdatePicker = false
                            Task { await model.setBackdate(captureID, to: date); refresh() }
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
                        Task { await model.moveEntry(captureID, toJournal: journal.id); refresh() }
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
    /// #11's rule, one layer up from the log reader that first drew this line.
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            switch transcriptState {
            case .absent:
                Text("This entry was not transcribed.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.absent")
            case .unreadable:
                Text("The transcript could not be read.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.unreadable")
            case .present:
                if let transcriptText, !transcriptText.isEmpty {
                    Text(transcriptText)
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("detail.transcript.text")
                } else {
                    Text("No speech was transcribed.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.transcript.empty")
                }
            }
        }
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
