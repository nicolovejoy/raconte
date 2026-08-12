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
    /// The editor is a full-screen push, not a sheet (T7 Task 4, ruling Q9). Its model is
    /// built once, in `init`, rather than inside the destination builder: a builder that
    /// re-mints it on every body evaluation would restart the editing session under the
    /// owner's cursor, and a builder that could return nothing would push a blank page
    /// (issue #32's lesson).
    @State private var showingEditor = false
    /// A save the editor refused on its way out (Gate A Critical 1). The editor's own screen
    /// has already popped by then, so the detail screen is the only surface left that can say
    /// so — the same reason `trashFailed`/`moveFailed`/`backdateFailed` live here.
    @State private var editSaveFailed = false
    @State private var editSaveFailureReason = ""
    @State private var editorModel: TranscriptEditorModel
    /// Mark voices is its OWN mode (T7 Mark Voices, issue #56, Task 6 — replaces the
    /// old "Correct markers" screen) — a separate pushed screen, never inline in the
    /// editor. Same "built once in init" reasoning as `editorModel` above.
    @State private var showingVoiceMarking = false
    @State private var voiceMarkingModel: VoiceMarkingModel
    /// The whole undo story (T7 Task 8, ruling Q1) — a separate pushed screen, same
    /// "built once in init" reasoning as `editorModel`/`voiceMarkingModel` above.
    @State private var showingRevisionHistory = false
    @State private var revisionHistoryModel: RevisionHistoryModel

    /// Sidecar writes that reported failure. Each names what didn't save — the same
    /// swallowed-`try?` family as `TrashView.permanentDeleteFailed`, which the owner hit
    /// on device with a "Move to Trash" that silently didn't take.
    @State private var trashFailed = false
    @State private var moveFailed = false
    @State private var backdateFailed = false

    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(model: LibraryScreenModel, item: EntryListItem) {
        self.model = model
        self.captureID = item.captureID
        _item = State(initialValue: item)
        _editorModel = State(initialValue: TranscriptEditorModel(captureID: item.captureID,
                                                                 store: model))
        _voiceMarkingModel = State(initialValue: VoiceMarkingModel(captureID: item.captureID,
                                                                    store: model))
        _revisionHistoryModel = State(initialValue: RevisionHistoryModel(captureID: item.captureID,
                                                                          store: model))
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
        .navigationDestination(isPresented: $showingEditor) {
            TranscriptEditorView(model: editorModel)
        }
        // The editor writes through the store directly and deliberately does NOT rescan on
        // every debounce fire; the library rows catch up once, here, when it closes.
        .onChange(of: showingEditor) { _, shown in
            guard !shown else { return }
            Task {
                // BEFORE the reload, not after: on Back the editor's own `onDisappear` starts
                // its close concurrently, and a rescan that overtook it would re-render the
                // PRE-edit transcript — the owner backs out and watches the edit vanish, with
                // the stale-draft sweep no help (it will not touch a seconds-old draft).
                // `finishIfNeeded()` is idempotent, so whichever path gets here first wins and
                // the other is a no-op.
                if !(await editorModel.finishIfNeeded()),
                   let reason = editorModel.unreportedSaveFailure {
                    editSaveFailureReason = reason
                    editorModel.acknowledgeSaveFailure()
                    editSaveFailed = true
                }
                await model.rescan()
                await refresh()
            }
        }
        .navigationDestination(isPresented: $showingVoiceMarking) {
            VoiceMarkingView(model: voiceMarkingModel, voiceLabels: item.journal?.voiceLabels ?? [:])
        }
        // Every marking action writes and commits immediately (no draft, no debounce —
        // see `VoiceMarkingModel`'s doc comment), so unlike the editor there is nothing
        // to finish on the way out; a refresh once the screen closes is enough for the
        // transcript section to pick up the new voices.
        .onChange(of: showingVoiceMarking) { _, shown in
            guard !shown else { return }
            Task {
                await model.rescan()
                await refresh()
            }
        }
        .navigationDestination(isPresented: $showingRevisionHistory) {
            RevisionHistoryView(model: revisionHistoryModel)
        }
        // A revert changes `current` — refresh once the panel closes so the transcript
        // section shows what reverting actually landed, same reasoning as the marker
        // correction close above.
        .onChange(of: showingRevisionHistory) { _, shown in
            guard !shown else { return }
            Task {
                await model.rescan()
                await refresh()
            }
        }
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
        .alert("Your edit didn’t save", isPresented: $editSaveFailed) {
            // Offered first because it is the only thing that recovers the words: the editor
            // model lives as long as this screen, so re-entering still has them (`open()`
            // preserves unsaved text). Leaving this entry is what loses them.
            Button("Back to my edit") { showingEditor = true }
            Button("Not now", role: .cancel) {}
        } message: {
            // This copy is only true because `open()` keeps unsaved words on re-entry even
            // when the entry has become read-only — otherwise the button offered here would
            // be the thing that erased them (re-review Important).
            Text("\(editSaveFailureReason)\n\nYour words are still here, unsaved. Reopen the "
                 + "editor to see them and try again — they’ll be lost if you leave this entry.")
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
        // T7 prereq #41 (fix round 1: Important 1 + 2, one fix): a draft-free capture —
        // the overwhelmingly common case — must never hop the revision-store actor
        // before the read below, so it can't queue behind an in-flight launch corpus
        // walk (the exact regression the T6c comment three lines down already warns
        // about). Only when a draft exists does this pay the actor cost, and then it
        // promotes BEFORE closing: closing first would mint a `.userEdit` that
        // permanently blocks the `.machineLive` baseline from ever entering the chain
        // (`promoteIfNeeded` skips unconditionally once any canonical file exists). See
        // `LibraryScreenModel.recoverStaleDraftBeforeRead`.
        await model.recoverStaleDraftBeforeRead(captureID)
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
    /// Voice-attributed paragraphs (T7 plan step 3, restyled per owner ask 2026-08-08;
    /// labels made per-journal and opt-in by T7 Mark Voices, issue #56 — see
    /// `VoiceDisplay`): a voice label is prefixed inline to the prose, one line, only
    /// when the entry's journal has configured a non-empty label for that voice
    /// (`VoiceDisplay.label`) — the DEFAULT render has no prefix at all. The main voice's
    /// paragraphs render in italic regardless (`VoiceDisplay.isItalic`) as a stand-in for
    /// the print-vs-cursive distinction his physical journals use — no per-voice typeface
    /// yet. **`hasApproximateBoundary` affordance (T7 Task 9.3):** a paragraph adjacent
    /// to an approximate cut gets a small, subtle trailing mark — a hint, not an error
    /// state; the split itself is never wrong, only its exact position within a word-gap
    /// is uncertain. The mark sits BESIDE the paragraph's selectable text, not inside it
    /// (Gate B Minor 2), so copying the prose never picks up an asterisk nobody typed and
    /// VoiceOver gets a labelled element instead of a bare "star". Reads whatever
    /// `TranscriptAttribution` already computed; nothing here re-derives marker/correction
    /// state.
    ///
    /// **Parked (T7 Task 9.2, ruled — Q12): cross-paragraph text selection.**
    /// `.textSelection(.enabled)` is per-`Text`, one call per paragraph below, so a drag
    /// that starts in one paragraph and ends in another selects nothing past the first
    /// paragraph's boundary — a real regression against the old single flattened
    /// `Text(text)` (still visible in the `.plain` case above, where selection spans the
    /// whole transcript). Per-paragraph rendering is what makes voice labels and italics
    /// possible per paragraph in the first place, and SwiftUI's `Text` has no API for
    /// "select across these siblings" short of a custom text view. Explicitly not fixed
    /// in T7 — noted here so the next reader finds a documented trade, not a bug to
    /// rediscover.
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
                // Read once per render, not per paragraph: labels are a property of the
                // entry's journal, not of any one paragraph. Unfiled/dangling ->
                // defaults (no labels), same as everywhere else `item.journal` is
                // optional.
                let voiceLabels = item.journal?.voiceLabels ?? [:]
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        // The base identifier is unchanged for the common (non-approximate)
                        // case — nothing that already greps for
                        // "detail.transcript.paragraph.<i>" breaks. The suffix is additive,
                        // giving a future UI test something concrete to assert on without a
                        // snapshot harness.
                        // Gate B Minor 2: the approximate-boundary mark is a SIBLING of the
                        // selectable text, never concatenated into it. Concatenated, copying
                        // a paragraph yielded "…prose *" — a character the owner never wrote,
                        // pasted into wherever he was quoting himself — and VoiceOver read a
                        // bare "star" after the prose with nothing to say what it meant. As a
                        // sibling the text copies clean and the mark carries its own label.
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            // T7 Mark Voices (#56): VoiceOver must not lose the voice
                            // distinction just because visual labels are off — the
                            // common case now that labels are opt-in. Applied only when
                            // a voice is actually in force; an unattributed paragraph
                            // keeps its default accessibility text (its own prose).
                            //
                            // Task 6 review Important 2: this used to be `.accessibility
                            // Label` on the inner `Text` conditionally, inside a `Group`
                            // with no element boundary of its own. With exactly one
                            // paragraph — the common case pre-Mark-Voices, and post-flip
                            // whenever a paragraph merges into its neighbour's voice —
                            // iOS's accessibility tree flattened the whole `Group` (and
                            // its explicit label) into the OUTER `detail.transcript.text`
                            // `VStack`, exposing an auto-derived label from the raw
                            // prose instead: VoiceOver lost the voice distinction on
                            // exactly the entries this comment promises it must not.
                            // Fixed two ways together: `.accessibilityElement(children:
                            // .combine)` forces this `Group` to be its own
                            // independently-exposed element regardless of sibling count
                            // (paired with `.contain` on the outer `VStack`, below, so it
                            // stops treating a single child as mergeable into itself);
                            // and the label is now set directly on the `Group` itself,
                            // unconditionally, rather than conditionally on the inner
                            // `Text` — `.combine`'s own label-concatenation heuristic
                            // was observed (via a UI test) to derive its label from the
                            // `Text`'s literal content rather than an explicit override
                            // set on a descendant, so the override has to sit on the
                            // element boundary itself to reliably survive.
                            Group {
                                attributedParagraph(paragraph, voiceLabels: voiceLabels)
                            }
                                .font(.system(.body, design: .serif))
                                .textSelection(.enabled)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(paragraph.voice.map {
                                    "\(VoiceDisplay.accessibilityName(forVoice: $0, voiceLabels: voiceLabels)): \(paragraph.text)"
                                } ?? paragraph.text)
                                .accessibilityIdentifier(paragraph.hasApproximateBoundary
                                    ? "detail.transcript.paragraph.\(index).approximate"
                                    : "detail.transcript.paragraph.\(index)")
                            if paragraph.hasApproximateBoundary {
                                Text("*")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("approximate boundary")
                                    .accessibilityIdentifier(
                                        "detail.transcript.paragraph.\(index).approximateMark")
                            }
                        }
                    }
                }
                // Task 6 review Important 2, continued: `.accessibilityElement(children:
                // .combine)` on each paragraph's `Group` (above) makes THAT view its own
                // element, but with only one paragraph this outer `VStack` still had
                // exactly one accessibility-bearing child and no boundary of its own —
                // iOS kept flattening past the `Group`'s boundary and exposing this
                // `VStack`'s identifier/auto-label instead. `.contain` tells the system
                // this view is a CONTAINER of its children's own elements, never a
                // candidate to be merged down into one itself, regardless of how many
                // paragraphs there are.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail.transcript.text")
            }

            // The detail screen stays the reader: it gains an Edit affordance and nothing
            // else. The transcript above is never editable in place.
            Button("Edit transcript…") { showingEditor = true }
                .font(.caption)
                .accessibilityIdentifier("detail.editButton")

            // Its own mode, not inline here (T7 Mark Voices, issue #56, Task 6 — replaces
            // the old "Correct markers" screen): tap a paragraph to flip its voice, or
            // drag a range of words to mark it.
            Button("Mark voices…") { showingVoiceMarking = true }
                .font(.caption)
                .accessibilityIdentifier("detail.markVoicesButton")

            // The whole undo story (T7 Task 8, ruling Q1) — the editor has no discard
            // and no revert button, so this is the only way back.
            Button("Revision history…") { showingRevisionHistory = true }
                .font(.caption)
                .accessibilityIdentifier("detail.revisionHistoryButton")

            if transcript.isTruncated {
                Text("The end of this transcript is missing — the app closed before it "
                     + "finished writing. The recording itself is complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.transcript.truncated")
            }
        }
    }

    /// Builds one paragraph's `Text`: an inline, bold-secondary voice-label prefix
    /// concatenated onto the prose — SwiftUI `Text` concatenation is the only way to mix
    /// styling within one line — then italicized as a whole when
    /// `VoiceDisplay.isItalic(voice:)` says so. The prefix appears ONLY when
    /// `VoiceDisplay.label` finds a non-nil, non-empty configured label for the
    /// paragraph's voice in `voiceLabels` (T7 Mark Voices, issue #56, owner ruling: the
    /// default render has no label at all — voices are told apart by italic vs regular
    /// until the owner opts a journal into labels). Unattributed paragraphs
    /// (`voice == nil`) never get a prefix.
    ///
    /// **`hasApproximateBoundary` is NOT rendered here (Gate B Minor 2).** The small
    /// asterisk used to be concatenated onto the end of this `Text`, which put a character
    /// the owner never wrote inside the SELECTABLE run — copying a paragraph yielded
    /// "…prose *" — and gave VoiceOver a bare "star" to read. It now lives beside this text
    /// as a sibling in the call site's `HStack`, with its own accessibility label, so this
    /// function returns exactly the owner's words. Still consumed exactly as
    /// `TranscriptAttribution` computed it (raw taps, snapping and Task 6's marker
    /// corrections are folded in upstream — see `EntryTranscript.snappedMarkers`); nothing
    /// here re-derives marker/correction state.
    ///
    /// `Text` concatenation keeps each segment's own explicit modifiers
    /// (font/color/italic) regardless of the outer `.font(.system(.body, design:
    /// .serif))` the call site applies, which is the mechanism the voice label relies on.
    private func attributedParagraph(_ paragraph: TranscriptAttribution.Paragraph,
                                     voiceLabels: [String: String]) -> Text {
        let body = Text(paragraph.text)
        let combined: Text
        if let label = VoiceDisplay.label(forVoice: paragraph.voice, voiceLabels: voiceLabels) {
            let prefix = Text("\(label): ")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            combined = prefix + body
        } else {
            combined = body
        }
        return VoiceDisplay.isItalic(voice: paragraph.voice) ? combined.italic() : combined
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
