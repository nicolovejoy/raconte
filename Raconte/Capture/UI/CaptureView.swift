import SwiftUI

/// The Milestone 1 capture screen: recovery banners, elapsed timer + status, mic meter,
/// the one big round record button, and a recent-recordings list. Dark-first, minimal
/// chrome (design language: quiet personal journal; polish is Milestone 5).
struct CaptureView: View {
    let model: CaptureScreenModel

    private var control: RecordControlModel {
        RecordControlModel.make(phase: model.coordinator.phase,
                                canResume: model.coordinator.canResume)
    }

    private var markers: MarkerControlsModel {
        MarkerControlsModel.make(phase: model.coordinator.phase,
                                 multiVoice: model.multiVoiceEnabled)
    }

    private var layout: CaptureLayoutModel {
        CaptureLayoutModel.make(phase: model.coordinator.phase,
                                hasReceipt: model.receipt != nil)
    }

    /// Issue #53. Three bands, top to bottom: a scrolling setup region, the live
    /// transcript, and a control bar pinned to the bottom.
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
            Color(white: 0.05).ignoresSafeArea()

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
                errorBanner
                controlBar
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .task { await model.bootstrap() }
    }

    /// Journal, backdate, two-voices, recovery banners, recents, build stamp — everything
    /// that is setup or browsing rather than operating the recorder.
    ///
    /// Two different renderings by design (approach 2 of the 2026-08-16 IA discussion —
    /// owner: "there's two scrollable sections above [the bar]... I would rather have
    /// none, especially during the recording"). Idle is a browsing screen, so one honest
    /// scroll region is fine. While capturing, nothing left in this band is unbounded —
    /// journal name, backdate, build stamp — so nothing here scrolls at all;
    /// `CaptureLayoutModel.usesCompactBackdateField`/`showsRecoveryBanners` strip the band
    /// down to that bounded content instead of squeezing the full band into a fixed-height
    /// box that then had to scroll internally, which is what stacked a second scroll view
    /// above the transcript's own.
    @ViewBuilder
    private var setupRegion: some View {
        if layout.usesCompactBackdateField {
            VStack(alignment: .leading, spacing: 12) {
                JournalHeaderView(model: model)
                CompactBackdateSummary(model: model)
                // Not DEBUG-gated: a wireless install is exactly when you can't tell
                // which build you're holding, and TestFlight has the same problem.
                Text(BuildInfo.stamp)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityIdentifier("capture.buildStamp")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    JournalHeaderView(model: model)
                    BackdateField(model: model)

                    if layout.showsMultiVoiceField {
                        MultiVoiceField(model: model)
                    }

                    if layout.showsRecoveryBanners {
                        ForEach(model.visibleRecovered) { rec in
                            RecoveryBanner(recording: rec,
                                           capturesRoot: model.capturesRoot,
                                           onKeep: { model.keep(rec.captureID) },
                                           onDelete: { model.delete(rec.captureID) })
                        }
                    }

                    if layout.showsLastEntry {
                        lastEntrySection
                    }

                    // Not DEBUG-gated: a wireless install is exactly when you can't tell
                    // which build you're holding, and TestFlight has the same problem.
                    Text(BuildInfo.stamp)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .accessibilityIdentifier("capture.buildStamp")
                }
                .padding(24)
            }
        }
    }

    /// The live transcript: capped when idle, and free to take everything the setup band
    /// and the control bar leave behind during a capture.
    ///
    /// Its scroll view is now the ONLY one in this band — previously it was a same-axis
    /// scroll nested inside the page scroll, which is its own source of confused gestures.
    @ViewBuilder
    private var transcriptRegion: some View {
        if let transcription = model.transcription, !transcription.displayText.isEmpty {
            ScrollView {
                Text(transcription.displayText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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
    /// The background is opaque on purpose: the setup band scrolls behind this, and a
    /// transparent bar would let text slide under the record button.
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
        .background(Color(white: 0.05))
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
                .tint(.red)
                .accessibilityIdentifier("capture.done")
                .opacity(control.showsDoneButton ? 1 : 0)
                .disabled(!control.showsDoneButton)
                .accessibilityHidden(!control.showsDoneButton)
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

    /// The single most recent entry (M3 T4.5, cut down 2026-08-15), sourced from
    /// `model.library` — the SAME scan/store the Library screen reads — and rendered with
    /// the same `LibraryEntryRow` the library list uses.
    ///
    /// One, not three, and not a list. Owner smoke: "I'd rather not have too many things
    /// scrolling around. Would be better just to see the most recent one and then have an
    /// obvious link to the Library." Three rows were also what turned the setup band into a
    /// scroll view tall enough to compete with the control bar for height, which is why
    /// its last row rendered sliced through the middle of a sentence.
    @ViewBuilder
    private var lastEntrySection: some View {
        if let item = model.library.recent.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last entry")
                    .captureLabel(.recentHeader)
                NavigationLink(value: LibraryDestination.entry(item.captureID)) {
                    LibraryEntryRow(item: item)
                }
                .accessibilityIdentifier("capture.recentRow")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The post-stop receipt (owner ruling 2026-08-15, capture-landing option B).
    ///
    /// Everything above the control bar for as long as it is up. What the owner lost
    /// before was any sense that a reading had FINISHED: the transcript simply stayed on
    /// screen as loose text under a sliced Recent list, belonging to nothing and leading
    /// nowhere. Here the same words are headed, dated, set in the reading serif with their
    /// voice marks, and have two doors out of them.
    private func receiptRegion(_ receipt: CaptureReceipt) -> some View {
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
                        .background(Capsule().fill(Color.green.opacity(0.22)))
                }
                Text(receipt.summaryLine)
                    .captureLabel(.receiptSummary)
                    .monospacedDigit()
                    .accessibilityIdentifier("capture.receipt.summary")
            }

            receiptProse(receipt)

            HStack(spacing: 12) {
                NavigationLink(value: LibraryDestination.entry(receipt.captureID)) {
                    Text("Open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // Dismissed on the way out, not on the way back: returning from the entry
                // you were just reading to a receipt about it is a loop with no exit that
                // feels like progress.
                .simultaneousGesture(TapGesture().onEnded { model.dismissReceipt() })
                .accessibilityIdentifier("capture.receipt.open")

                Button("Record another") { model.dismissReceipt() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("capture.receipt.dismiss")
            }
            .controlSize(.large)
            // Never `.preferredColorScheme` on this screen — see `BackdateField`.
            .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
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
            Spacer(minLength: 0)
        } else {
            ScrollView {
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
                .font(.system(.callout, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

/// "Recording into: <journal>" (M3 T3, phone mockup). A `Menu` doubles as the switcher
/// — tap to pick any existing journal — plus "Rename…" and "New Journal…", both taken
/// through an `.alert` text field so this stays a menu-and-alert screen, no navigation
/// push, matching M1/M2's quiet-chrome style.
struct JournalHeaderView: View {
    let model: CaptureScreenModel

    @State private var showingNewJournalPrompt = false
    @State private var showingRenamePrompt = false
    @State private var showingCoverPicker = false
    @State private var showingVoiceLabels = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording into")
                .captureLabel(.journalHeaderCaption)

            Menu {
                ForEach(model.journals) { journal in
                    Button {
                        model.selectJournal(journal.id)
                    } label: {
                        if journal.id == model.selectedJournalID {
                            Label(menuTitle(for: journal), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: journal))
                        }
                    }
                }
                Divider()
                Button("Rename “\(model.selectedJournalName)”…") {
                    draftName = model.selectedJournalName
                    showingRenamePrompt = true
                }
                Button("New Journal…") {
                    draftName = ""
                    showingNewJournalPrompt = true
                }
                if model.selectedJournalID != nil {
                    Button("Cover Photo…") { showingCoverPicker = true }
                        .accessibilityIdentifier("capture.coverPhotoMenuItem")
                    Button("Voice Labels…") { showingVoiceLabels = true }
                        .accessibilityIdentifier("capture.voiceLabelsMenuItem")
                }
            } label: {
                HStack(spacing: 6) {
                    JournalCoverThumbnail(data: model.selectedJournalCover, size: 34)
                        .accessibilityIdentifier("capture.journalCoverThumbnail")
                    // `captureLabel`, not a raw `.font(.title3…)`. The raw style rendered
                    // this at 15 pt on the Mac — below the 16 pt floor — on the very
                    // platform the "font too small" report came from, while
                    // `CaptureLabel.journalName` sat in the model declaring 22 pt and
                    // passing every check in `CaptureLabelTests`. The model said one thing
                    // and the screen did another; `testEveryLabelCaseIsActuallyAppliedToAView`
                    // is what now makes that disagreement impossible.
                    Text(model.selectedJournalName)
                        .captureLabel(.journalName)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.up.chevron.down")
                        .captureLabel(.journalPickerChevron)
                }
                .foregroundStyle(.white)
            }
            .accessibilityIdentifier("capture.journalPicker")
            // This control had NO color-scheme pin at all before (issue #58) — its
            // label was already explicit `.white`/gray, but nothing pinned the menu's
            // own rendering. `.environment(\.colorScheme, .dark)`, never
            // `.preferredColorScheme`: `CaptureView` is the app's one permanently-
            // mounted NavigationStack root (`ContentView.swift`), with no sheet/popover
            // boundary around it, so `preferredColorScheme` here would resolve to the
            // whole window — forcing Library/Detail/Trash dark for every macOS
            // light-mode user, not just this menu (fix-round-1 finding). Scoped to the
            // `Menu` only, not the enclosing `VStack` below, which also anchors this
            // view's `.sheet`/`.alert` presentations (cover picker, voice labels,
            // rename/new journal prompts) — those must keep following the system's
            // normal appearance. The menu's own dropdown *content* (journal list,
            // Rename/New Journal/Cover Photo/Voice Labels items) is a transient popup
            // and out of scope for #58 — it renders on its own material background,
            // not the near-black screen.
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
        // `.foregroundStyle(Color.primary)` on both fields, for the same reason the
        // `.sheet` below resets it: an alert draws on the SYSTEM's own light material,
        // but its content is a SwiftUI builder nested inside `CaptureView`, which sets
        // `.foregroundStyle(.white)` for the near-black capture surface. That white is
        // inherited straight into the text field — owner smoke, 2026-08-15: "the 'new
        // folder' text field is white on white, can't read what I type. but it does
        // work." Exactly that: the binding was fine, the text was invisible.
        .alert("New Journal", isPresented: $showingNewJournalPrompt) {
            TextField("Journal name", text: $draftName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("capture.newJournalNameField")
            Button("Create") { Task { await model.createJournal(name: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Journal", isPresented: $showingRenamePrompt) {
            TextField("Journal name", text: $draftName)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("capture.renameJournalNameField")
            Button("Rename") { Task { await model.renameCurrentJournal(to: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingCoverPicker) {
            // Reset the capture screen's inherited .white foreground —
            // it renders invisible on the system sheet background.
            JournalCoverPickerSheet(
                journalName: model.selectedJournalName,
                currentCover: model.selectedJournalCover,
                onPick: { data in
                    do { try await model.setCurrentJournalCover(imageData: data); return true }
                    catch { return false }
                },
                onRemove: { await model.removeCurrentJournalCover() })
            .foregroundStyle(Color.primary)
        }
        .sheet(isPresented: $showingVoiceLabels) {
            // Same foreground reset as the cover sheet above — system sheet background.
            JournalVoiceLabelsSheet(
                journalName: model.selectedJournalName,
                currentLabels: model.journals.first(where: { $0.id == model.selectedJournalID })?
                    .voiceLabels ?? [:],
                onSave: { labels in await model.setCurrentJournalVoiceLabels(labels) })
            .foregroundStyle(Color.primary)
        }
    }

    /// Journal name plus its derived date range in parentheses (issue #14 part 2), e.g.
    /// "1987 (1987)" or "Trip to France (March – July 1998)". Omitted for an empty
    /// journal — appending "()" to a journal nobody has recorded into yet is noise.
    private func menuTitle(for journal: Journal) -> String {
        guard let range = model.library.dateRange(forJournal: journal.id) else { return journal.name }
        return "\(journal.name) (\(range.formatted()))"
    }
}

/// Optional backdate — off by default, so an un-backdated entry never has a date
/// materialized into its sidecar (`EntryMetadata.originalDate == nil` means "use the
/// capture's own date"). Settable before or during recording (M3 T3); the model pushes
/// every change straight to the live capture's `entry.json` when one is in progress.
/// The backdate toggle plus its precision date picker, with no styling applied. Two
/// callers style this content for two different surfaces: `BackdateField` pins it to the
/// near-black capture background (issue #58, the idle setup band's inline field);
/// `CompactBackdateSummary`'s sheet leaves it in the system's own light/dark appearance —
/// the same convention `JournalHeaderView`'s cover/voice-labels sheets already use, and
/// the reason this content is factored out rather than duplicated (approach 2, 2026-08-16
/// IA discussion: the sheet needs the identical write-through bindings, just un-styled).
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

struct BackdateField: View {
    let model: CaptureScreenModel

    var body: some View {
        BackdateEditorContent(model: model)
            // Belt-and-suspenders alongside the `.environment` pin below (issue #58): an
            // explicit foreground/tint at this call site (not inside
            // `BackdateEditorContent`, which `CompactBackdateSummary`'s light-background
            // sheet also uses and must not force) so the toggle's and date field's own
            // text/highlight read correctly even if the environment pin doesn't reach
            // every native subview.
            .tint(.white)
            .foregroundStyle(.white)
            // The capture screen's background is near-black regardless of the app's color
            // scheme; an ambient-scheme system control renders dark-on-dark in light mode
            // (smoke feedback 2026-08-02, issue #58). `.environment(\.colorScheme, .dark)`
            // ONLY — never `.preferredColorScheme`, which governs "the nearest enclosing
            // presentation, such as a popover or window" (Apple's own wording): this view
            // lives inside `CaptureView`, the app's one permanently-mounted NavigationStack
            // root (`ContentView.swift`), with no sheet/popover boundary around it, so a
            // `preferredColorScheme` pin here would resolve to the WHOLE WINDOW — forcing
            // Library/Detail/Trash dark for every macOS light-mode user, all the time. The
            // scoped `.environment` pin has no such reach; a control's own transient popup
            // (the calendar/segment dropdown) is explicitly out of scope for #58 — it
            // renders on its own material background, not the near-black screen.
            .environment(\.colorScheme, .dark)
    }
}

/// One-line, non-scrolling stand-in for `BackdateField` while capturing (approach 2,
/// 2026-08-16 IA discussion). Owner: "there's two scrollable sections above [the bar]...
/// I would rather have none, especially during the recording." The full field is bounded
/// (a toggle and a date), so it never needed a scroll region — it just needed to stop
/// being drawn as one. Tapping opens the same write-through editor in a sheet, unstyled
/// (system light/dark material), the same convention `JournalHeaderView`'s other sheets
/// already use.
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
        .foregroundStyle(.white)
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

/// Whether this is a two-voice reading (T6 §14, design §5) — the setup-area gate for the
/// voice switch. Pre-record only: the frame-0 `bn` opener can only be written at recording
/// start, so enabling mid-capture has no coherent meaning in this build (plan §0.3.5).
///
/// The toggle reads `multiVoiceEnabled`, which is *computed* — the in-session per-journal
/// override, else the journal's most recent entry on disk. Unlike the backdate toggle this
/// one auto-enables from carry-over: a wrong voice attribute is visible and editable in T7,
/// where a wrong backdate is a quiet data error (the deliberate divergence, design §2).
struct MultiVoiceField: View {
    let model: CaptureScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.multiVoiceEnabled },
                set: { model.setMultiVoiceEnabled($0) }
            )) {
                Text("Two voices")
                    .captureLabel(.multiVoiceToggle)
            }
            .accessibilityIdentifier("capture.multiVoiceToggle")
            .disabled(model.coordinator.phase != .idle)
            .opacity(model.coordinator.phase == .idle ? 1 : 0.45)
            // Same `.switch` reasoning as `BackdateField`'s toggle — not itself named
            // in issue #58, but the same control class on the same background.
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.environment(\.colorScheme, .dark)` ONLY, never `.preferredColorScheme` —
        // see the matching comment on `BackdateField` (issue #58 fix-round-1 finding):
        // `CaptureView` is the app's permanently-mounted NavigationStack root with no
        // sheet/popover boundary, so `preferredColorScheme` here would resolve to the
        // whole window, not this subtree.
        .environment(\.colorScheme, .dark)
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
    /// remained queryable (and, more to the point, VoiceOver-reachable) in phases where it
    /// does nothing. `CaptureUITests.testVoiceControlsFollowTheMultiVoiceToggle` — which
    /// asserts the voice switch does not exist during a single-voice capture — caught it,
    /// and is the pin for it. A `Color.clear` of the same fixed size keeps the geometry
    /// without keeping the control.
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
                    .fill(.white)
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
                model.coordinator.markVoice(otherVoice)
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
        // see the matching comment on `BackdateField` (issue #58 fix-round-1
        // finding: `CaptureView` is the permanently-mounted NavigationStack root,
        // so `preferredColorScheme` here would resolve to the whole window).
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
