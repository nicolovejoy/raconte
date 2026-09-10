import SwiftUI

/// #157: the moment between "pick a folder" and "write my whole private journal into it".
/// Names the destination, lists every journal with its entry count, offers the unfiled bucket
/// when there is one, and commits with a button that says exactly how many entries will land.
/// Every toggle starts ON — a full export is still the default path, this is a scope
/// selector in front of it. Nothing is written until `onExport` fires.
struct ExportConfirmationSheet: View {
    let destinationName: String
    let inventory: ExportInventory
    let onCancel: () -> Void
    let onExport: (ExportScope) -> Void

    @State private var selectedJournalIDs: Set<String>
    @State private var includeUnfiled: Bool

    init(destinationName: String, inventory: ExportInventory,
         onCancel: @escaping () -> Void, onExport: @escaping (ExportScope) -> Void) {
        self.destinationName = destinationName
        self.inventory = inventory
        self.onCancel = onCancel
        self.onExport = onExport
        _selectedJournalIDs = State(initialValue: Set(inventory.journals.map(\.id)))
        _includeUnfiled = State(initialValue: inventory.unfiledCount > 0)
    }

    /// `.all` when nothing was deselected, so a default confirm is byte-identical to the
    /// pre-#157 export (`testAllScopeWritesTheSamePackageAsTheUnscopedCall`).
    private var scope: ExportScope {
        let everyJournal = selectedJournalIDs.count == inventory.journals.count
        let everyUnfiled = includeUnfiled || inventory.unfiledCount == 0
        if everyJournal && everyUnfiled { return .all }
        return .selected(journalIDs: selectedJournalIDs, includeUnfiled: includeUnfiled)
    }

    private var entryCount: Int { inventory.entryCount(for: scope) }

    private var confirmTitle: String {
        entryCount == 1 ? "Export 1 entry" : "Export \(entryCount) entries"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: destinationName)
                        .accessibilityIdentifier("about.export.destination")
                } footer: {
                    Text("The package is plain files: transcripts are readable text and audio plays anywhere. Choose the destination with that in mind.")
                        .font(TypeRole.footnote.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                }

                Section("Journals") {
                    ForEach(inventory.journals) { row in
                        Toggle("\(row.name) · \(row.entryCount)", isOn: Binding(
                            get: { selectedJournalIDs.contains(row.id) },
                            set: { on in
                                if on { selectedJournalIDs.insert(row.id) } else { selectedJournalIDs.remove(row.id) }
                            }))
                        .accessibilityIdentifier("about.export.journal.\(row.id)")
                    }
                    if inventory.unfiledCount > 0 {
                        Toggle("Unfiled entries · \(inventory.unfiledCount)", isOn: $includeUnfiled)
                            .accessibilityIdentifier("about.export.unfiled")
                    }
                }
            }
            .font(TypeRole.body.font)
            .navigationTitle("Export archive")
            .accessibilityIdentifier("about.export.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("about.export.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onExport(scope) }
                        .disabled(entryCount == 0)
                        .accessibilityIdentifier("about.export.confirm")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

#Preview {
    ExportConfirmationSheet(
        destinationName: "Archive 2026",
        inventory: ExportInventory(
            journals: [.init(id: "a", name: "1987 Journal", entryCount: 12),
                       .init(id: "b", name: "Trip to France", entryCount: 3)],
            unfiledCount: 2, totalEntries: 17),
        onCancel: {}, onExport: { _ in })
}
