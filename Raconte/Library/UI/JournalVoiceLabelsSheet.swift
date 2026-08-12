import SwiftUI

/// Per-journal voice-label settings (T7 Mark Voices, issue #56). Default is NO labels —
/// main voice renders italic, alternative regular, with no prefix at all (`VoiceDisplay`).
/// Labels are opt-in per journal: filling either field turns on the `"BN: …"`-style
/// prefix for that voice, alongside the style, for journals that read as a named
/// conversation instead of an unlabelled two-hand transcript.
///
/// Mirrors `JournalCoverPickerSheet`'s closure shape: dumb and store-free, it hands the
/// trimmed dictionary up to `onSave` and lets the caller own persistence and failure.
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
                Section {
                    TextField("No label", text: $mainLabel)
                        .accessibilityIdentifier("journalVoiceLabels.mainField")
                } header: {
                    Text("Main voice label (italic)")
                }
                Section {
                    TextField("No label", text: $alternativeLabel)
                        .accessibilityIdentifier("journalVoiceLabels.alternativeField")
                } header: {
                    Text("Alternative voice label")
                } footer: {
                    Text("Leave empty to distinguish voices by style alone.")
                }
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
            mainLabel = currentLabels["bn"] ?? ""
            alternativeLabel = currentLabels["ln"] ?? ""
        }
    }

    /// Empty fields mean no label — dropped from the dict entirely rather than sent as
    /// `""`, matching `JournalStore.setVoiceLabels`'s own trim-and-drop rule.
    private func trimmedLabels() -> [String: String] {
        var labels: [String: String] = [:]
        let main = mainLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = alternativeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !main.isEmpty { labels["bn"] = main }
        if !alternative.isEmpty { labels["ln"] = alternative }
        return labels
    }
}
