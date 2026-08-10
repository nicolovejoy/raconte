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

    /// Sidecar writes that reported failure. Each names what didn't save — the same
    /// swallowed-`try?` family as `TrashView.permanentDeleteFailed`, which the owner hit
    /// on device with a "Move to Trash" that silently didn't take.
    @State private var trashFailed = false
    @State private var moveFailed = false
    @State private var backdateFailed = false

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
        .alert("Couldn’t move this entry to the trash", isPresented: $trashFailed) {
            Button("OK") { trashFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
        .alert("Couldn’t move this entry", isPresented: $moveFailed) {
            Button("OK") { moveFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
        .alert("Couldn’t save the backdate", isPresented: $backdateFailed) {
            Button("OK") { backdateFailed = false }
        } message: {
            Text("The change didn’t save. Try again.")
        }
    }

    /// Both loads are off the main actor: the transcript is an O(records) parse and
    /// `CapturePlayback`'s convenience init walks the whole captures tree. Opening an
    /// entry used to do both synchronously while the screen was on screen.
    private func refresh() async {
        if let latest = model.item(captureID) { item = latest }
        // T7 prereq #41: recover any stale draft BEFORE the read below — a recovered
        // edit must be visible in the very first text this screen shows, not only after
        // the next launch's corpus-wide pass.
        await model.closeStaleDraftIfNeeded(captureID)
        transcript = await model.transcript(for: captureID)
        // T6c: promote AFTER the first read, not before — `promoteCorpus()` runs the
        // whole corpus with no yield on the actor, so promoting first would make
        // opening an entry during the launch pass block on the entire walk (review
        // finding 3). The read above already shows the live.jsonl-fallback text
        // immediately; only re-read (and only pay the promote cost) when this specific
        // capture actually gets a fresh canonical revision out of it.
        if case .promoted = await model.promoteIfNeeded(captureID) {
            transcript = await model.transcript(for: captureID)
        }
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

            // M3 issue #15. Shown only while the detected date is still the one in force
            // — the moment the owner edits it this is his date, not the recording's, and
            // saying otherwise would be wrong rather than merely stale.
            if item.backdateWasDetected {
                Text("Detected from the recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.detectedDate")
            }
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
                                Task {
                                    if !(await model.setBackdate(captureID, to: nil)) { backdateFailed = true }
                                    await refresh()
                                }
                            }
                            .accessibilityIdentifier("detail.clearBackdateButton")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let date = backdateDraft
                            let precision = backdatePrecisionDraft
                            showingBackdatePicker = false
                            Task {
                                if !(await model.setBackdate(captureID, to: date, precision: precision)) {
                                    backdateFailed = true
                                }
                                await refresh()
                            }
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
                        Task {
                            if !(await model.moveEntry(captureID, toJournal: journal.id)) { moveFailed = true }
                            await refresh()
                        }
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

    /// The transcript section's rendering decision, factored out of the view (T7 plan
    /// step 3) so it's unit-testable without a snapshot harness: SwiftUI body rendering
    /// isn't otherwise reachable from `RaconteTests`. `transcriptSection` below is a
    /// thin `switch` over this with no logic of its own.
    enum TranscriptDisplay: Equatable {
        case absent
        case unreadable
        case empty
        case plain(String)
        case attributed([TranscriptAttribution.Paragraph])
    }

    /// Pure: no I/O, no `Environment`, no `@State` reads. Paragraphs win over plain text
    /// whenever they exist — the loader already collapses "markers with no transcript"
    /// to `paragraphs == nil` (hazard 4), so a non-empty `paragraphs` here always means
    /// there is something to show.
    static func transcriptDisplay(_ transcript: EntryTranscript) -> TranscriptDisplay {
        switch transcript.state {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .present:
            if let paragraphs = transcript.paragraphs, !paragraphs.isEmpty {
                return .attributed(paragraphs)
            }
            if let text = transcript.text, !text.isEmpty {
                return .plain(text)
            }
            return .empty
        }
    }

    /// Absent / unreadable / present-but-empty are three distinct, calm answers — issue
    /// #11's rule, one layer up from the log reader that first drew this line. A short
    /// tail is a fourth: the text is real and there may simply be less of it than was
    /// spoken, which the library row already marks and this screen used not to.
    ///
    /// Voice-attributed paragraphs (T7 plan step 3, restyled per owner ask 2026-08-08):
    /// the voice label is inline (`"BN: "` prefixed to the prose, one line) rather than
    /// a separate caption line, and BN paragraphs render in italic
    /// (`TranscriptAttribution.isItalic(voice:)`) as a stand-in for the
    /// print-vs-cursive distinction his physical journals use — no per-voice typeface
    /// yet. Still deferred: an affordance for `hasApproximateBoundary` (requirement 4's
    /// explicit v1 decision — an approximate cut renders exactly like a precise one;
    /// the flag exists so a later pass can add a badge without re-deriving anything).
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            switch Self.transcriptDisplay(transcript) {
            case .absent:
                Text("This entry was not transcribed.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.absent")
            case .unreadable:
                Text("The transcript could not be read.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.unreadable")
            case .empty:
                Text("No speech was transcribed.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.empty")
            case .plain(let text):
                Text(text)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.transcript.text")
            case .attributed(let paragraphs):
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        attributedParagraph(paragraph)
                            .font(.system(.body, design: .serif))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("detail.transcript.paragraph.\(index)")
                    }
                }
                .accessibilityIdentifier("detail.transcript.text")
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

    /// Builds one paragraph's `Text`: an inline, bold-secondary voice prefix
    /// (`"BN: "`) concatenated onto the prose — SwiftUI `Text` concatenation is the
    /// only way to mix styling within one line — then italicized as a whole when
    /// `TranscriptAttribution.isItalic(voice:)` says so. Unattributed paragraphs
    /// (`voice == nil`) get no prefix and are never italic.
    private func attributedParagraph(_ paragraph: TranscriptAttribution.Paragraph) -> Text {
        let body = Text(paragraph.text)
        let combined: Text
        if let voice = paragraph.voice {
            let label = Text("\(TranscriptAttribution.displayName(forVoice: voice)): ")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            combined = label + body
        } else {
            combined = body
        }
        return TranscriptAttribution.isItalic(voice: paragraph.voice) ? combined.italic() : combined
    }

    // MARK: - Trash

    /// Bottom of the screen, quiet, and behind a confirmation — but present on every
    /// entry on every platform, per the M3 decision that deletion works anywhere.
    private var trashSection: some View {
        Button("Move to Trash", role: .destructive) { showingTrashConfirmation = true }
            .font(.caption)
            .accessibilityIdentifier("detail.trashButton")
    }

    /// Stop playback, then await the write and pop only on success. This used to pop
    /// **before** the write, on the theory that `ContentView`'s destination renders this
    /// screen only while `library.item(captureID)` resolves and the rescan inside
    /// `trashEntry` republishes the lists — so waiting would briefly show a view of an
    /// entry no longer in the list it was pushed from. That concern doesn't apply here:
    /// with await-then-dismiss the entry is only delisted *after* `trashEntry` succeeds,
    /// so the screen is never showing a stale, already-gone entry. Pop-first also made
    /// the failure invisible on device — the screen was gone before the caller could
    /// know the write never took, which is the bug this function now exists to not have.
    private func moveToTrash() {
        playback?.stop()
        Task {
            if await model.trashEntry(captureID) {
                dismiss()
            } else {
                trashFailed = true
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
