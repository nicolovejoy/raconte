import SwiftUI

/// The two label fields themselves (T7 Mark Voices, issue #56), with no save/write
/// discipline of its own — `JournalVoiceLabelsSheet` batches them behind Save/Cancel,
/// `JournalEditorView` (Task 6) writes each field through on focus loss. Extracted so
/// the two callers share one body rather than two copies drifting apart (standing rule:
/// call shared primitives, never copy them).
struct JournalVoiceLabelsSection: View {
    /// Current labels, keyed "bn" (main voice) / "ln" (alternative voice).
    @Binding var mainLabel: String
    @Binding var alternativeLabel: String
    /// Fires when either field loses focus. No-op default: `JournalVoiceLabelsSheet`
    /// batches both fields behind its own Save button and has no use for a per-field
    /// signal. `JournalEditorView` (Task 6) uses this to write through immediately —
    /// focus state stays fully inside this view (two fields, one shared enum) so the
    /// parent never has to know which of the two just lost it.
    var onFieldCommit: () -> Void = {}

    private enum Field: Hashable { case main, alternative }
    @FocusState private var focusedField: Field?

    var body: some View {
        Group {
            Section {
                TextField("No label", text: $mainLabel)
                    .focused($focusedField, equals: .main)
                    .accessibilityIdentifier("journalVoiceLabels.mainField")
            } header: {
                Text("Main voice label (italic)")
            }
            Section {
                TextField("No label", text: $alternativeLabel)
                    .focused($focusedField, equals: .alternative)
                    .accessibilityIdentifier("journalVoiceLabels.alternativeField")
            } header: {
                Text("Alternative voice label")
            } footer: {
                Text("Leave empty to distinguish voices by style alone.")
            }
        }
        .onChange(of: focusedField) { oldField, _ in
            if oldField != nil { onFieldCommit() }
        }
    }
}

/// Per-journal voice-label settings (T7 Mark Voices, issue #56). Default is NO labels —
/// main voice renders italic, alternative regular, with no prefix at all (`VoiceDisplay`).
/// Labels are opt-in per journal: filling either field turns on the `"BN: …"`-style
/// prefix for that voice, alongside the style, for journals that read as a named
/// conversation instead of an unlabelled two-hand transcript.
///
/// Mirrors `JournalCoverPickerSheet`'s closure shape: dumb and store-free, it hands the
/// trimmed dictionary up to `onSave` and lets the caller own persistence and failure.
/// No production caller remains after Task 6 (the editor replaced the capture-screen
/// route Task 1 removed), kept for the shape's own sake and any future re-mount.
struct JournalVoiceLabelsSheet: View {
    let journalName: String
    /// Current labels, keyed "bn" (main voice) / "ln" (alternative voice).
    let currentLabels: [String: String]
    /// Returns false when the save didn't take — the sheet stays up instead of
    /// dismissing over a silent no-op.
    let onSave: ([String: String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var mainLabel: String = ""
    @State private var alternativeLabel: String = ""
    @State private var saveError = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                JournalVoiceLabelsSection(mainLabel: $mainLabel, alternativeLabel: $alternativeLabel)
            }
            .navigationTitle("Voice Labels for “\(journalName)”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            let labels = trimmedLabels()
                            if await onSave(labels) { dismiss() } else { saveError = true }
                            isSaving = false
                        }
                    }
                    .accessibilityIdentifier("journalVoiceLabels.save")
                    .disabled(isSaving)
                }
            }
            .alert("Couldn’t Save Voice Labels", isPresented: $saveError) {
                Button("OK", role: .cancel) {}
            }
        }
        .onAppear {
            mainLabel = currentLabels[VoiceDisplay.mainVoice] ?? ""
            alternativeLabel = currentLabels[VoiceDisplay.other(VoiceDisplay.mainVoice)] ?? ""
        }
    }

    /// Empty fields mean no label — dropped from the dict entirely rather than sent as
    /// `""`, matching `JournalStore.setVoiceLabels`'s own trim-and-drop rule.
    private func trimmedLabels() -> [String: String] {
        var labels: [String: String] = [:]
        let main = mainLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = alternativeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !main.isEmpty { labels[VoiceDisplay.mainVoice] = main }
        if !alternative.isEmpty { labels[VoiceDisplay.other(VoiceDisplay.mainVoice)] = alternative }
        return labels
    }
}
