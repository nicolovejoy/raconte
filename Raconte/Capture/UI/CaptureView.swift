import SwiftUI

/// The capture screen: journal + backdate on top, the live transcript or the receipt in
/// the middle, the control bar pinned to the bottom (#118).
struct CaptureView: View {
    let model: CaptureScreenModel

    /// Task 10 (#18): the picker's presentation state lives here, on the view, not on
    /// `CaptureScreenModel` — presentation is view-lifecycle-safe (repo invariant:
    /// nothing that must survive `CaptureView` being navigated away from may live on
    /// the view). `JournalHeaderView` only flips this flag; the sheet itself is
    /// attached below at the outer `ZStack` level.
    @State private var showingJournalPicker = false
    /// Sheet-then-alert dance (same shape as `EntryDetailView.pendingInfoAction`): a
    /// tap on `JournalPickerSheet`'s "New Journal…" row sets this while the sheet is
    /// still dismissing, and the sheet's own `onDismiss:` promotes it into the alert
    /// once iOS has actually finished tearing the sheet down.
    @State private var pendingNewJournalPrompt = false
    @State private var showingNewJournalPrompt = false
    @State private var draftJournalName = ""

    private var control: RecordControlModel {
        RecordControlModel.make(phase: model.coordinator.phase,
                                canResume: model.coordinator.canResume)
    }

    private var markers: MarkerControlsModel {
        MarkerControlsModel.make(phase: model.coordinator.phase)
    }

    private var layout: CaptureLayoutModel {
        CaptureLayoutModel.make(phase: model.coordinator.phase,
                                hasReceipt: model.receipt != nil)
    }

    /// Issue #53, updated by #118 §3. Three bands, top to bottom: a fixed setup band
    /// (journal + backdate), the live transcript or the receipt, and a control bar pinned
    /// to the bottom.
    ///
    /// The single page-level `ScrollView` this replaces is what caused #53: the record
    /// button, voice switch and paragraph button sat inside it, *below* the transcript,
    /// so every word transcribed pushed them further down — and on a long reading the
    /// voice switch left the viewport altogether. Nothing hid it; it had scrolled away.
    ///
    /// The controls are now outside every scroll view, so no amount of transcript can
    /// move them. That property is what `CaptureControlsUITests` measures; the visibility
    /// rules per phase are `CaptureLayoutModel`'s.
    var body: some View {
        ZStack {
            InkTone.studio.color.ignoresSafeArea()

            VStack(spacing: 0) {
                if let receipt = model.receipt, layout.showsReceipt {
                    // Just stopped. The receipt owns everything above the bar; the arming
                    // controls step aside until it is dismissed.
                    receiptRegion(receipt)
                } else {
                    setupRegion
                    transcriptRegion
                    // Absorbs whatever the bands above do not want, so the bar stays welded
                    // to the bottom edge. Without it the stack sizes to its content and the
                    // ZStack centres the lot — which moved the record button 59 pt the
                    // moment recording started and the setup band shrank to its
                    // capture-time height. Only ever non-zero when neither the setup band
                    // nor the transcript is stretching, i.e. mid-capture with nothing
                    // transcribed yet.
                    Spacer(minLength: 0)
                }
                // Displaces the transcript/setup band above it, same as `errorBanner`
                // below — or the `Spacer(minLength: 0)` fallback when neither band is
                // stretching — so the control bar itself never moves.
                // `discardNotice` is set by plain property mutation on the model — no
                // `withAnimation` there, deliberately (animation is a view concern, not
                // the model's) — so the `.animation(value:)` below is what actually makes
                // the `.transition` run; without it the notice would pop in and out
                // instantly despite the transition declaration.
                if let notice = model.discardNotice {
                    Text(notice)
                        .captureLabel(.discardNotice)
                        .accessibilityIdentifier("capture.discardNotice")
                        .transition(.opacity)
                }
                errorBanner
                controlBar
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            // Makes the discard notice's `.transition(.opacity)` real. `discardNotice`
            // changes via plain property mutation (no `withAnimation` on the model side,
            // deliberately — animation stays a view concern); this is what turns that
            // mutation into an animated diff instead of an instant pop.
            .animation(.easeInOut, value: model.discardNotice)
        }
        .foregroundStyle(InkTone.studioInk.color)
        .task { await model.bootstrap() }
        // Task 10 (#18): outer ZStack level, never nested inside `setupRegion`'s `VStack`
        // — repo memory: a `.sheet` attached inside a Form/List `Section` silently never
        // presents on iOS 26; this generalizes the same "attach at the screen's outer
        // view" rule to every sheet on this screen.
        // Presented PLAIN (no `.environment(\.colorScheme, .dark)`) — the sheet renders
        // on its own system material and follows ambient appearance, unlike the
        // near-black studio background behind it.
        .sheet(isPresented: $showingJournalPicker, onDismiss: {
            guard pendingNewJournalPrompt else { return }
            pendingNewJournalPrompt = false
            draftJournalName = ""
            showingNewJournalPrompt = true
        }) {
            JournalPickerSheet(
                journals: model.journals,
                covers: model.library.journalCovers,
                currentJournalID: model.selectedJournalID,
                dateLine: { model.library.dateLine(forJournal: $0) },
                entryCount: { id in model.library.allEntries.filter { $0.journalID == id }.count },
                onSelect: { model.selectJournal($0) },
                onNewJournal: { pendingNewJournalPrompt = true })
        }
        // `.foregroundStyle(Color.primary)` on the field: an alert draws on the
        // SYSTEM's own light material, but its content is a SwiftUI builder nested
        // inside `CaptureView`, which sets `.foregroundStyle(InkTone.studioInk.color)` for the
        // near-black capture surface. That white is inherited straight into the text
        // field — owner smoke, 2026-08-15: "the 'new folder' text field is white on
        // white, can't read what I type. but it does work." Exactly that: the binding
        // was fine, the text was invisible.
        .alert("New Journal", isPresented: $showingNewJournalPrompt) {
            TextField("Journal name", text: $draftJournalName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("capture.newJournalNameField")
            Button("Create") { Task { await model.createJournal(name: draftJournalName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Journal and backdate — the two things that describe the reading, in every mode
    /// that is not the receipt. Bounded content, so it never scrolls (approach 2 of the
    /// 2026-08-16 IA discussion: "I would rather have none, especially during the
    /// recording"). #118 §3 made Ready the same band as Recording: the last-entry card,
    /// the Two-voices toggle and the recovery banners left for Home, and the full inline
    /// backdate field left for the compact summary's sheet (§6 — backdate "whenever,
    /// basically", so the same one-line summary is on Ready and Recording alike).
    private var setupRegion: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalHeaderView(model: model, showingJournalPicker: $showingJournalPicker)
            CompactBackdateSummary(model: model)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The live transcript: shown only while a capture is under way
    /// (`layout.showsLiveTranscript`), free to take everything the setup band and the
    /// control bar leave behind — never shown when idle (Ready or the post-stop
    /// receipt), where the setup band and the receipt occupy this space instead.
    ///
    /// Its scroll view is now the ONLY one in this band — previously it was a same-axis
    /// scroll nested inside the page scroll, which is its own source of confused gestures.
    @ViewBuilder
    private var transcriptRegion: some View {
        // `layout.showsLiveTranscript` FIRST, not just "is there text". The transcription
        // session deliberately holds the finished text after a capture ends (so the panel
        // doesn't blank the instant you stop) and a fresh coordinator does not clear it —
        // it belongs to the session, not the coordinator. On the ordinary path the receipt
        // covers this region, so the stale text was never seen. Discard sets `receipt =
        // nil`, which uncovered it: owner smoke 2026-08-30, "the transcription stays,
        // though not in the journal is it visible" — the words stranded on the landing
        // screen, belonging to a recording that no longer exists. That is precisely the
        // #53-era defect `showsLiveTranscript` was added to prevent; this view was simply
        // not asking it.
        if layout.showsLiveTranscript,
           let transcription = model.transcription, !transcription.runs.isEmpty {
            ScrollView {
                LiveTranscriptText(runs: transcription.runs)
            }
            .frame(maxHeight: layout.transcriptFillsAvailableHeight ? .infinity : 160)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("capture.transcript")
        }
    }

    /// Capture errors, deliberately ABOVE the control bar rather than inside it.
    ///
    /// Its height depends on the message, and anything of variable height inside a
    /// bottom-anchored bar moves the controls. Here it displaces the transcript — the one
    /// band on this screen that is meant to flex — and the bar does not budge.
    @ViewBuilder
    private var errorBanner: some View {
        if let error = model.coordinator.lastError {
            Text(error)
                .captureLabel(.errorBanner)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
        }
    }

    /// Everything that operates the recorder, pinned outside every scroll view — the #53
    /// fix itself. Present in every phase so it never appears, disappears, or resizes
    /// under the owner's thumb mid-reading.
    ///
    /// Rebuilt 2026-08-15 to the owner-approved "Option B" mockup. The #53 version kept
    /// the controls still but took 331 pt — 38% of an iPhone 17 Pro — stacking timer,
    /// meter, record button, marker row and Done as five separate rows with 28 pt gaps.
    /// The owner's verdict: *"the bottom half stays put but it's so big I can't even see
    /// the full backdate interface let alone Two voices and Recents"*, and his ruling was
    /// a proportion — **at most a third of the screen**.
    ///
    /// Three rows now instead of five: the timer goes inline with the status text and
    /// Done, and the marker buttons move from their own row to FLANKING the record
    /// button. Every size comes from `CaptureControlBarMetrics`, which is where the
    /// ≤ ⅓ arithmetic can be tested.
    ///
    /// The background is opaque on purpose: the transcript region above this can grow
    /// to fill the available height during a capture, and a transparent bar would let
    /// its text slide under the record button.
    private var controlBar: some View {
        VStack(spacing: CaptureControlBarMetrics.rowSpacing) {
            statusRow

            MicMeter(level: model.coordinator.micLevel,
                     isLive: model.coordinator.phase == .recording)

            recordRow
        }
        .padding(.top, CaptureControlBarMetrics.topPadding)
        .padding(.bottom, CaptureControlBarMetrics.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(InkTone.studio.color)
        // Deliberately NO accessibilityIdentifier on this container. Putting one here
        // turns the bar into a single accessibility element that absorbs its children,
        // and `capture.record` / `capture.voiceSwitch` / `capture.paragraph` stop being
        // queryable at all — which broke every capture UI test the first time round. Same
        // flattening this file already hit on the NavigationLink rows and the Task-6
        // backdate row.
    }

    /// Timer, live dot, status text and Done, all on one line — two rows of the old bar
    /// collapsed into one.
    ///
    /// Height is FIXED rather than sized to content. The bar is anchored to the bottom
    /// edge, so anything inside it that grows pushes the record button upward: the #53
    /// build measured 151 pt of exactly that before reserving space in every phase. The
    /// status string is the variable-length part and `RecStatusLine` shrinks it instead of
    /// wrapping; Done is reserved here for the same reason it was reserved before.
    private var statusRow: some View {
        HStack(spacing: 12) {
            RecStatusLine(phase: model.coordinator.phase,
                          canResume: model.coordinator.canResume,
                          elapsed: model.coordinator.elapsed)

            Spacer(minLength: 8)

            // Reserved, not inserted: `.opacity(0)` keeps the space and the row height
            // constant while `.disabled` + `.accessibilityHidden` keep it unreachable by
            // touch and by VoiceOver in the phases where it is not really there.
            Button("Done") { Task { await model.done() } }
                .buttonStyle(.bordered)
                .tint(InkTone.record.color)
                .accessibilityIdentifier("capture.done")
                .opacity(control.showsDoneButton ? 1 : 0)
                .disabled(!control.showsDoneButton)
                .accessibilityHidden(!control.showsDoneButton)

            // Quiet, not red: sits beside a live red record control and must not compete
            // with it for the eye. No confirmation dialog — recoverable from the trash
            // for 30 days, so a confirm would cost a tap for nothing. Identifier on the
            // leaf button only (repo trap: a container identifier flattens the bar).
            //
            // `.captureLabel(.discardButton)`, not a raw `.font` — fix-round-1 (task 3
            // review): a raw `.callout` renders at 16 pt on iOS but only 12 pt on macOS,
            // 4 pt under `CaptureSurface.minimumControlPointSize`, and a raw font also
            // sits outside `CaptureLabelTests`' floor sweep entirely, the same miss
            // `errorBanner`'s own comment already records for `.footnote` + `.red`.
            if layout.showsDiscardButton {
                Button("Discard") { Task { await model.discardCurrentCapture() } }
                    .buttonStyle(.plain)
                    .captureLabel(.discardButton)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("capture.discard")
                    .accessibilityLabel("Discard recording")
            }
        }
        .frame(height: CaptureControlBarMetrics.statusRowHeight)
        .padding(.horizontal, CaptureControlBarMetrics.horizontalPadding)
    }

    /// The voice switch, the record button, and the paragraph button on one line, with the
    /// marks pushed out toward the screen edges.
    ///
    /// The owner's refinement on the mockup, verbatim: *"just make sure we separate the
    /// clickable buttons as much as we can within that paradigm… BN and paragraph marker
    /// could move towards the side just a bit"*. Hence the tighter inset here than on the
    /// status row: Stop keeps the widest exclusion zone the row can give it, so a marker
    /// tap during a reading cannot land on the one button that ends the recording.
    private var recordRow: some View {
        // The REAL markers model in every phase, with no `reservedForLayout` substitution:
        // each marker slot is a fixed size that holds its space whether or not the control
        // is shown, so the row's geometry no longer depends on what is visible in it.
        RecordControlsRow(model: model, markers: markers) {
            RecordButton(model: control, action: primaryAction)
                .accessibilityIdentifier("capture.record")
        }
        .frame(height: CaptureControlBarMetrics.recordDiameter)
        .padding(.horizontal, CaptureControlBarMetrics.controlRowHorizontalPadding)
    }

    /// The post-stop receipt (owner ruling 2026-08-15, capture-landing option B).
    ///
    /// Everything above the control bar for as long as it is up. What the owner lost
    /// before was any sense that a reading had FINISHED: the transcript simply stayed on
    /// screen as loose text under a sliced Recent list, belonging to nothing and leading
    /// nowhere. Here the same words are headed, dated, set in the reading serif with their
    /// voice marks, and the whole block is the door to the entry (#118 §3: "Record
    /// another" is gone — the bar's own record button starts the next reading, so the
    /// screen offers one record control in one position).
    private func receiptRegion(_ receipt: CaptureReceipt) -> some View {
        // One scroll view, OUTSIDE the link: long prose scrolls, and a tap anywhere on
        // the card opens the entry. A `ScrollView` inside a link's label loses one of
        // the two gestures on macOS.
        ScrollView {
            NavigationLink(value: LibraryDestination.entry(receipt.captureID)) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(receipt.dateText)
                                .captureLabel(.receiptDate)
                                .accessibilityIdentifier("capture.receipt.date")
                            Spacer()
                            Text("Saved")
                                .captureLabel(.receiptSavedChip)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(InkTone.studioSaved.color))
                        }
                        Text(receipt.summaryLine)
                            .captureLabel(.receiptSummary)
                            .monospacedDigit()
                            .accessibilityIdentifier("capture.receipt.summary")
                    }

                    receiptProse(receipt)

                    // The card's own caption, not a separate button: owner at smoke —
                    // "Open isn't super clear here… show the entry in a box that's clearly
                    // 'click to open'-able or (view/edit)."
                    HStack(spacing: 4) {
                        Spacer()
                        Text("View / edit")
                            .captureLabel(.receiptSummary)
                        Image(systemName: "chevron.right")
                            .captureLabel(.receiptSummary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(InkTone.studioCard.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(InkTone.studioHairline.color, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            // Dismissed on the way out, not on the way back: returning from the entry
            // you were just reading to a receipt about it is a loop with no exit that
            // feels like progress. (`reconcileReceipt` covers the trash path if this
            // gesture does not fire — #62.)
            .simultaneousGesture(TapGesture().onEnded { model.dismissReceipt() })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open entry from \(receipt.dateText)")
            .accessibilityIdentifier("capture.receipt.open")
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The receipt's prose, or one calm line saying why there is none.
    ///
    /// Absent, unreadable and present-but-empty stay three distinct answers (issue #11's
    /// rule) rather than collapsing into a blank box — and none of them is an error, which
    /// is why they read as statements and not warnings. The recording is safe in all three.
    @ViewBuilder
    private func receiptProse(_ receipt: CaptureReceipt) -> some View {
        if let unavailable = receipt.proseUnavailableText {
            Text(unavailable)
                .captureLabel(.receiptSummary)
                .accessibilityIdentifier("capture.receipt.prose")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                switch receipt.body {
                case .attributed(let paragraphs):
                    // `VoiceAttributedText` is the SAME renderer the detail screen
                    // uses, so the marks the owner asked to see "manifest" here are
                    // exactly the ones he'll see when he opens the entry.
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        VoiceAttributedText.paragraph(
                            paragraph, voiceLabels: model.selectedJournalVoiceLabels)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .plain(let text):
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .absent, .unreadable, .empty:
                    // Unreachable: `proseUnavailableText` is non-nil for all three, so
                    // the branch above handled them. Stated rather than defaulted, so
                    // a new display case has to be decided here instead of silently
                    // rendering nothing.
                    EmptyView()
                }
            }
            // Serif, per the 2026-08-09 type ruling: the reading surface is New York,
            // and this is a reading surface.
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("capture.receipt.prose")
        }
    }

    private func primaryAction() {
        switch control.action {
        case .record: Task { await model.record() }
        case .done: Task { await model.done() }
        case .resume: Task { await model.resume() }
        case .none: break
        }
    }
}

/// "Recording into: <journal>" (M3 T3, phone mockup). Task 10 (#18) replaced the old
/// `Menu` switcher with a plain `Button` that opens `JournalPickerSheet`, presented
/// from `CaptureView`'s own root ZStack level — the sheet's presentation state is
/// `CaptureView`'s, not this view's, since `CaptureView` can be navigated away from at
/// any time (repo invariant: nothing view-lifecycle-scoped may own state that must
/// survive that). "New Journal…" still ends in an `.alert` text field, also lifted to
/// `CaptureView` so the sheet-then-alert dance follows the established
/// dismiss-then-present pattern (`EntryDetailView`'s `pendingInfoAction`). Selection and
/// creation only (spec ruling 6, #69) — renaming, cover photo, and voice labels moved to
/// the journal editor.
struct JournalHeaderView: View {
    let model: CaptureScreenModel
    @Binding var showingJournalPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording into")
                .captureLabel(.journalHeaderCaption)

            Button {
                showingJournalPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(model.selectedJournalName)
                        .captureLabel(.journalName)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.up.chevron.down")
                        .captureLabel(.journalPickerChevron)
                }
                .foregroundStyle(InkTone.studioInk.color)
            }
            .buttonStyle(.plain)
            // #65: the container identifier was overwriting its descendants', which made
            // `capture.journalPicker` invisible to XCUITest (confirmed in a live AX dump).
            // `.combine` flattens the label into ONE element that keeps both an explicit
            // label and this identifier, instead of the identifier being swallowed. Kept
            // after the Menu→Button switch (Task 10) since a plain `Button` label is
            // still more than one child element (`Text` + `Image`).
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording into \(model.selectedJournalName)")
            .accessibilityIdentifier("capture.journalPicker")
            // This control had NO color-scheme pin at all before (issue #58) — its
            // label was already explicit `.white`/gray, but nothing pinned the button's
            // own rendering. `.environment(\.colorScheme, .dark)`, never
            // `.preferredColorScheme`: that modifier governs "the nearest enclosing
            // presentation, such as a popover or window" (Apple's own wording), and
            // `CaptureView` is pushed inline into the app's navigation — there is no
            // sheet or popover boundary between this button and the window — so a
            // `preferredColorScheme` pin here would resolve to the WHOLE WINDOW, forcing
            // Library/Detail/Trash dark for every macOS light-mode user, not just this
            // button (fix-round-1 finding). `.environment` has no such reach: it stops at
            // this subtree. Scoped to the `Button` only, not the enclosing `VStack` below.
            // `JournalPickerSheet` itself renders on system material and must NOT inherit
            // this pin (Task 10 brief note) — it is presented from `CaptureView`, entirely
            // outside this scope.
            .environment(\.colorScheme, .dark)

            // The one honest case where nothing is selected. Says what it costs — the
            // recording is unaffected, only its filing — rather than raising an alarm.
            if model.registryUnreadable {
                Text("Your journals couldn’t be read. This entry will record normally "
                     + "and stay where it is until they’re back.")
                    .captureLabel(.journalsUnreadable)
                    .accessibilityIdentifier("capture.journalsUnreadable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("capture.journalHeader")
    }
}

/// Optional backdate — off by default, so an un-backdated entry never has a date
/// materialized into its sidecar (`EntryMetadata.originalDate == nil` means "use the
/// capture's own date"). Settable before or during recording (M3 T3); the model pushes
/// every change straight to the live capture's `entry.json` when one is in progress.
/// The backdate toggle plus its precision date picker, with no styling applied.
/// `CompactBackdateSummary`'s sheet presents it in the system's own light/dark
/// appearance — the same convention `JournalHeaderView`'s cover/voice-labels sheets
/// already use, and the reason this content is factored out on its own (approach 2,
/// 2026-08-16 IA discussion: the sheet needs the identical write-through bindings, just
/// un-styled).
struct BackdateEditorContent: View {
    let model: CaptureScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Both bindings write through synchronously — no `Task` per change. Two
            // spins of the date wheel then reach the sidecar-write chain in the order
            // the user made them, which a Task per change could not guarantee.
            Toggle(isOn: Binding(
                get: { model.backdateEnabled },
                set: { model.setBackdateEnabled($0) }
            )) {
                Text("Backdate this entry")
                    .captureLabel(.backdateToggle)
            }
            .accessibilityIdentifier("capture.backdateToggle")
            // `.switch`, not the platform-default checkbox: a checkbox's outline-only
            // chrome is low-contrast against near-black in light mode; the switch style
            // always paints a distinctly-colored track + thumb, so legibility doesn't
            // depend on the color-scheme pin below actually reaching the control.
            .toggleStyle(.switch)

            // Always rendered, disabled until the toggle is on — a conditional picker
            // with a hidden label left no visible "place to set the date" (smoke
            // feedback, 2026-08-02). The row itself is the affordance.
            VStack(alignment: .leading, spacing: 4) {
                Text("Entry date")
                    .captureLabel(.backdateFieldCaption)
                PrecisionDatePicker(
                    date: Binding(get: { model.backdateDate }, set: { model.setBackdateDate($0) }),
                    precision: Binding(get: { model.backdatePrecision }, set: { model.setBackdatePrecision($0) }),
                    idPrefix: "capture")
            }
            .disabled(!model.backdateEnabled)
            .opacity(model.backdateEnabled ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one-line backdate summary, on Ready and Recording alike (#118 §6). Tapping opens
/// the same write-through editor in a sheet, unstyled (system light/dark material), the
/// same convention `JournalHeaderView`'s other sheets already use.
struct CompactBackdateSummary: View {
    let model: CaptureScreenModel
    @State private var showingEditor = false

    var body: some View {
        Button {
            showingEditor = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(Self.summaryText(enabled: model.backdateEnabled,
                                      date: model.backdateDate,
                                      precision: model.backdatePrecision))
                    .captureLabel(.backdateSummary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(InkTone.studioInk.color)
        .accessibilityIdentifier("capture.backdateSummary")
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                Form {
                    BackdateEditorContent(model: model)
                }
                .navigationTitle("Backdate")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingEditor = false }
                            .accessibilityIdentifier("capture.backdateSheetDone")
                    }
                }
            }
            // Reset the capture screen's inherited .white foreground — same reasoning as
            // `JournalHeaderView`'s cover/voice-labels sheets, which render on the
            // system's own light material, not the near-black capture surface.
            .foregroundStyle(Color.primary)
        }
    }

    /// Pulled out as its own pure function, same reasoning as
    /// `EntryDetailView.navigationTitleText`: a name a test can call directly.
    static func summaryText(enabled: Bool, date: Date, precision: DatePrecision,
                            calendar: Calendar = .gregorianCurrent) -> String {
        guard enabled else { return "Not backdated" }
        let partial = PartialDate(from: date, precision: precision, calendar: calendar)
        return "Backdated to \(partial.formatted(calendar: calendar))"
    }
}

/// The recorder's control row: the voice switch, the record button, and the paragraph
/// button, side by side with the marks pushed toward the screen edges.
///
/// The structure-marker controls (T6 §14, design §5) are a thumb-reach voice switch
/// showing the *active* voice, and a paragraph button always present while recording
/// (owner decision 7 — paragraphs are structure in a single-voice reading too). Visibility
/// and enablement still come from the pure `MarkerControlsModel`; everything here is
/// presentation plus the two coordinator calls.
///
/// They used to occupy a row of their own beneath the record button, which cost the bar
/// 44 pt plus a gap for two small buttons. Taking the record button as a centre slot lets
/// all three share one row — the change that made the owner's ≤ ⅓ ruling reachable — and
/// keeps the haptics, the enablement rule and the voice-label resolution in the one place
/// that already owned them.
struct RecordControlsRow<Center: View>: View {
    let model: CaptureScreenModel
    let markers: MarkerControlsModel

    @ViewBuilder let center: () -> Center

    /// One player per row instance, reused across every marker tap for the capture's
    /// lifetime — the CHHapticEngine it lazily owns is worth keeping warm rather than
    /// spinning up per tap.
    @State private var haptics = MarkerHapticsPlayer()

    /// #63: the dash-dot as light. Current white-overlay opacity per marker kind — the
    /// tapped button's surface pulses `MarkerFlash.steps` when its marker lands. Keyed by
    /// kind because that is what `coordinator.lastMarkerKind` reports; each kind has
    /// exactly one button.
    @State private var flashBrightness: [StructureMarker.Kind: Double] = [:]
    /// The in-flight pulse. A new marker cancels and replaces it — rapid taps each get a
    /// fresh dash rather than queueing a light show.
    @State private var flashTask: Task<Void, Never>?

    /// `coordinator.currentVoice` before a capture opens (or before its frame-0 `bn`
    /// marker lands) is `nil`; the main voice (`bn`) is the truth for that window, not
    /// a placeholder (plan §0.3.12) — same rule the pre-`VoiceDisplay` ternary encoded.
    private var effectiveVoice: String {
        model.coordinator.currentVoice ?? VoiceDisplay.mainVoice
    }

    /// The voice the capture is currently in, spoken in the selected journal's own
    /// labels when it has configured them (owner ruling 2026-08-12) — else exactly
    /// today's fallback, the uppercased id ("BN"/"LN"), via `VoiceDisplay`'s one
    /// label-resolution rule rather than a local copy of it.
    private var activeVoice: String {
        VoiceDisplay.accessibilityName(forVoice: effectiveVoice, voiceLabels: model.selectedJournalVoiceLabels)
    }

    /// A tap switches to the *other* voice — the label states where you are, the tap
    /// says where you're going. The flip rule lives once, in `VoiceDisplay.other`.
    private var otherVoice: String {
        VoiceDisplay.other(effectiveVoice)
    }

    /// A broken marker log means every tap can only no-op; a live-looking control over a
    /// dead path is the design §7 failure-state violation (plan §0.3.12). The failure is
    /// *reported* through `coordinator.lastError`, already rendered red below the button.
    private var isEnabled: Bool {
        markers.isEnabled && !model.coordinator.markerLoggingBroken
    }

    /// One marker button: fixed size, hidden-but-present when its phase says it isn't
    /// there, and dimmed when it's there but can't be tapped.
    ///
    /// **The fixed width is load-bearing.** The record button is centred by equal spacers,
    /// so the two flanking slots have to be equal. Intrinsic widths would not be: "¶" is
    /// far narrower than "BN", and the voice button's label CHANGES mid-capture — to
    /// "LN", or to whatever the journal's own voice labels are, which can be any length.
    /// Sizing to content would slide the Stop button sideways on every voice mark, which
    /// is #53 all over again in the horizontal axis.
    ///
    /// **Hidden, never absent**, for the same reason: a slot that disappears when a
    /// capture is single-voice, or between phases, lets the record button drift off
    /// centre. `.opacity(0)` keeps the geometry while `.disabled` + `.accessibilityHidden`
    /// keep the control unreachable by touch and by VoiceOver when it is not really there.
    /// This replaces `MarkerControlsModel.reservedForLayout`, which reserved a whole ROW's
    /// height back when the marks had a row of their own.
    /// An ABSENT marker button still occupies its slot — as an empty space of exactly the
    /// same size, not as a hidden button.
    ///
    /// `.opacity(0)` + `.accessibilityHidden(true)` was tried first and is not enough:
    /// XCUITest still finds an accessibility-hidden `Button` by identifier, so the control
    /// remained queryable (and, more to the point, VoiceOver-reachable) in a phase where it
    /// does nothing. A `Color.clear` of the same fixed size keeps the geometry without
    /// keeping the control.
    ///
    /// Since #118 §4 both `showsVoiceControl` and `showsParagraphControl` are constant
    /// `true` in every `CaptureState` (`MarkerControlsModel.make(phase:)`), so the `else`
    /// branch below is currently unreachable — `isShown` and the branch stay because the
    /// design only mandated dropping the `multiVoice:` parameter that used to feed it, not
    /// the mechanism itself.
    @ViewBuilder
    private func markerButton(_ title: String,
                              identifier: String,
                              accessibilityLabel: String? = nil,
                              isShown: Bool,
                              flashKind: StructureMarker.Kind,
                              action: @escaping () -> Void) -> some View {
        if isShown {
            Button(action: action) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: CaptureControlBarMetrics.markerButtonWidth,
                   height: CaptureControlBarMetrics.markerButtonHeight)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            // #63: the dash-dot, lit — a white pulse over the tapped button when its
            // marker LANDS (driven off `markerCount`, like the haptic — a failed append
            // flashes nothing). Purely decorative, so it must never intercept the next
            // tap or say anything to VoiceOver.
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(InkTone.studioInk.color)
                    .opacity(flashBrightness[flashKind] ?? 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(accessibilityLabel ?? title)
        } else {
            Color.clear
                .frame(width: CaptureControlBarMetrics.markerButtonWidth,
                       height: CaptureControlBarMetrics.markerButtonHeight)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            markerButton(activeVoice,
                         identifier: "capture.voiceSwitch",
                         isShown: markers.showsVoiceControl,
                         flashKind: .voice) {
                model.markVoice(otherVoice)
            }

            // Pushes the marks apart as far as the row allows — the owner's refinement,
            // so the Stop button keeps the widest possible exclusion zone around it.
            Spacer(minLength: 12)

            // The record button. Deliberately NOT inside the `.disabled` that gates the
            // marks: a broken marker log must never take Stop down with it.
            center()

            Spacer(minLength: 12)

            // "¶" alone on screen — the mockup's glyph — but spoken as "Paragraph".
            markerButton("¶",
                         identifier: "capture.paragraph",
                         accessibilityLabel: "Paragraph",
                         isShown: markers.showsParagraphControl,
                         flashKind: .paragraph) {
                model.coordinator.markParagraph()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // `.environment(\.colorScheme, .dark)` ONLY, never `.preferredColorScheme` —
        // see the matching comment on `JournalHeaderView` (issue #58 fix-round-1 finding:
        // nothing presents `CaptureView` as a sheet or popover, so `preferredColorScheme`
        // here would resolve to the whole window).
        .environment(\.colorScheme, .dark)
        // The owner is reading a page, not watching the screen: confirmation has to
        // be felt (design §5). Watching `markerCount`, which counts what reached
        // disk — a failed append is felt as the absence of a buzz.
        //
        // The `old, new` guard, not a bare "any change" trigger: `markerCount` resets
        // to 0 at capture teardown (the coordinator is respawned per capture), and an
        // unguarded trigger fires on that reset too — a phantom buzz on Done
        // (plan §0.3.4). Firing only on an *increase* is what keeps teardown silent.
        //
        // CoreHaptics via `MarkerHapticsPlayer`, not `.sensoryFeedback(.impact, …)`:
        // device feedback (2026-08-07) was "a weak single dot" — the dash-dot pattern
        // (`MarkerHaptic`) needs a real duration on the first beat, which
        // `.sensoryFeedback`/`UIImpactFeedbackGenerator` cannot express.
        .onChange(of: model.coordinator.markerCount) { old, new in
            if new > old {
                haptics.play()
                playFlash(model.coordinator.lastMarkerKind)
            }
        }
    }

    /// Steps the tapped button's overlay through `MarkerFlash.steps` — the same rhythm
    /// the haptic is buzzing, at the same trigger. On the Mac this pulse IS the marker
    /// confirmation (#63: no haptic engine in use there); on iOS it rides along.
    private func playFlash(_ kind: StructureMarker.Kind?) {
        guard let kind else { return }
        flashTask?.cancel()
        // Synchronously, before the new pulse: a cancelled task stops mid-step without
        // cleaning up, so a rapid cross-button tap must not leave the previous button's
        // light stuck on.
        flashBrightness = [:]
        flashTask = Task { @MainActor in
            var cursor = 0.0
            for step in MarkerFlash.steps {
                do {
                    try await Task.sleep(for: .seconds(step.relativeTime - cursor))
                    flashBrightness[kind] = step.brightness
                    try await Task.sleep(for: .seconds(step.duration))
                    flashBrightness[kind] = 0
                    cursor = step.relativeTime + step.duration
                } catch { return } // cancelled: a newer marker owns the light now
            }
        }
    }
}
