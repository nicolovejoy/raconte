import SwiftUI

/// The two label fields themselves (T7 Mark Voices, issue #56), with no save/write
/// discipline of its own — `JournalEditorView` (Task 6), its one caller, writes each
/// field through on focus loss.
struct JournalVoiceLabelsSection: View {
    /// Current labels, keyed "bn" (main voice) / "ln" (alternative voice).
    @Binding var mainLabel: String
    @Binding var alternativeLabel: String
    /// Fires when either field loses focus. `JournalEditorView` (Task 6) uses this to
    /// write through immediately — focus state stays fully inside this view (two
    /// fields, one shared enum) so the parent never has to know which of the two just
    /// lost it. The no-op default is a convenience for a read-only mount; no caller
    /// relies on it today.
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
