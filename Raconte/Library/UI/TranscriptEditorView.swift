import SwiftUI

/// The transcript editor, v1 (T7 Task 4). A thin binding over `TranscriptEditorModel` — the
/// `EntryDetailView.transcriptDisplay` precedent: every rule lives in the model, where
/// `RaconteTests` can reach it, and this file only draws.
///
/// **One flattened text view** (T7 plan ruling Q2) over the chain's current text. No
/// per-paragraph views, no inline BN/LN or ¶ decorations, no markers at all — marker
/// correction is its own mode (Task 6). Structure disappears while editing and reappears on
/// save. That is v1's biggest visible compromise and it is deliberate.
///
/// **No Cancel** (ruling Q1). Design §2.5 has no discard, so a Cancel that actually meant
/// Done would be a lie; navigating away IS Done. The undo story is revision history + revert
/// (Task 8), which is what the footer points at.
///
/// A full-screen push rather than a sheet (ruling Q9, keyboard-first on iPad/Mac): ⌘S
/// flushes, ⌘Return and Esc finish. No find/replace, no word count, and no editor-owned undo
/// stack in v1 — the system text view's own undo is whatever it is.
struct TranscriptEditorView: View {
    @Bindable var model: TranscriptEditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var textFocused: Bool

    /// `done()` refused. The screen stays, and says why.
    @State private var saveFailed = false

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("editor.loading")
            case .readOnly(let editability):
                readOnlyBody(editability)
            case .editing, .failed:
                editingBody
            }
        }
        .navigationTitle("Edit transcript")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)      // ⌘Return
                    .accessibilityIdentifier("editor.done")
            }
        }
        .background {
            // Keyboard-only affordances (ruling Q9). Invisible rather than `.hidden()`:
            // a hidden view is removed from the hierarchy and its shortcut goes with it.
            VStack {
                Button("Save now") { Task { await model.flush() } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Finish") { finish() }
                    .keyboardShortcut(.cancelAction)       // Esc
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task { await model.open() }
        // Ruling Q1: navigating away IS Done. This screen is a `navigationDestination` push,
        // so system Back and interactive swipe-back are always available and neither routes
        // through the Done button. Without this, popping inside the 2 s debounce window
        // dropped the last keystrokes entirely — the armed window holds `[weak self]` and the
        // model's only strong reference is the detail screen's `@State`. `finishIfNeeded()`
        // is idempotent, so the `dismiss()` in `finish()` landing here next is a no-op.
        .onDisappear {
            Task { await model.finishIfNeeded() }
        }
        // Leaving `.active` is one of the three flush triggers (§12.1), alongside the
        // debounce firing and Done. It is a flush, never a close: only `done()` and the
        // store's own stale/hour rules may close a draft.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await model.flush() }
        }
        .alert("Couldn’t save this edit", isPresented: $saveFailed) {
            Button("OK") { saveFailed = false }
        } message: {
            Text("Your words are still here on screen. Try Done again.")
        }
    }

    // MARK: - Editing

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.resumedFromDraft {
                notice("Picking up where you left off — this is your unsaved edit, "
                       + "not the recording’s transcript.")
                    .accessibilityIdentifier("editor.resumedNotice")
            }

            if model.draftClosedBeneathSession {
                notice("This edit was saved as a revision while you were away. "
                       + "Anything you type now continues from there.")
                    .accessibilityIdentifier("editor.recoveredNotice")
            }

            if case .failed(let reason) = model.state {
                notice("The last save didn’t take: \(reason)")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("editor.saveError")
            }

            TextEditor(text: $model.text)
                .font(.system(.body, design: .serif))
                .focused($textFocused)
                .defaultFocus($textFocused, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("editor.text")
                .onChange(of: model.text) { _, _ in model.textChanged() }

            Text("Every version is kept. Earlier ones stay in this entry’s history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("editor.historyNote")
        }
        .padding(16)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Read-only

    /// Sentences, not a disabled text box. A degraded chain additionally offers the
    /// `live.jsonl` text — labeled as the un-edited machine transcript, never as "the
    /// transcript" (ruling Q5).
    private func readOnlyBody(_ editability: EntryChainSnapshot.Editability) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(TranscriptEditorModel.readOnlySentence(editability))
                    .accessibilityIdentifier("editor.readOnlyReason")

                if let machineTranscript = model.machineTranscript {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The un-edited machine transcript")
                            .font(.headline)
                        Text(machineTranscript)
                            .font(.system(.body, design: .serif))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("editor.machineTranscript")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Finish

    /// Await the write, then dismiss — never the reverse. The 2026-08-03 detail-trash bug
    /// was exactly a pop-first-write-later, which made the failure invisible on device.
    private func finish() {
        Task {
            if await model.finishIfNeeded() {
                dismiss()
            } else {
                saveFailed = true
            }
        }
    }
}
