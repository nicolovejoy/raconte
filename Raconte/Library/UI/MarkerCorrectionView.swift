import SwiftUI

/// Marker correction as its OWN mode (T7 Task 6, ruling Q11) — reached from the detail
/// screen, never inline in `TranscriptEditorView`. Thin binding over
/// `MarkerCorrectionModel`, per the editor's own precedent: no logic here, only layout.
struct MarkerCorrectionView: View {
    @Bindable var model: MarkerCorrectionModel

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .nothingToCorrect:
                ContentUnavailableView("Nothing to correct yet",
                                       systemImage: "waveform.badge.exclamationmark",
                                       description: Text("This entry has no markers and nothing transcribed."))
                    .accessibilityIdentifier("markerCorrection.empty")
            case .ready:
                List {
                    Section("Boundaries") {
                        if model.boundaries.isEmpty {
                            Text("No voice or paragraph markers yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.boundaries) { row in
                            boundaryRow(row)
                        }
                    }
                    Section("Add a boundary") {
                        ForEach(model.words) { row in
                            wordRow(row)
                        }
                    }
                }
            }
        }
        .navigationTitle("Correct markers")
        .task { await model.open() }
        .alert("Couldn’t save", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { shown in if !shown { model.acknowledgeError() } }
        )) {
            Button("OK") { model.acknowledgeError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func boundaryRow(_ row: MarkerCorrectionModel.BoundaryRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind == .voice ? "Voice: \(row.voice ?? "—")" : "Paragraph break")
                Text("frame \(row.frame)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Two plain buttons, not a picker/menu — there are only ever two voices
            // (owner decision 3, `StructureMarker.swift`), so a menu would be needless
            // indirection over a binary choice. Only the OTHER voice is offered: a
            // "correction" to the voice it already says would be a no-op write.
            if row.kind == .voice, row.voice != StructureMarker.Voice.bigNico {
                Button("bn") { Task { await model.correctVoice(row, to: StructureMarker.Voice.bigNico) } }
                    .accessibilityIdentifier("markerCorrection.correctVoice.bn.\(row.id)")
            }
            if row.kind == .voice, row.voice != StructureMarker.Voice.littleNico {
                Button("ln") { Task { await model.correctVoice(row, to: StructureMarker.Voice.littleNico) } }
                    .accessibilityIdentifier("markerCorrection.correctVoice.ln.\(row.id)")
            }
            Button {
                Task { await model.retract(row) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("markerCorrection.retract.\(row.id)")
        }
    }

    @ViewBuilder
    private func wordRow(_ row: MarkerCorrectionModel.WordRow) -> some View {
        Button {
            Task { await model.addBoundary(row) }
        } label: {
            Text(row.text)
                .foregroundStyle(row.isPlaceable ? .primary : .secondary)
        }
        .disabled(!row.isPlaceable)
        .accessibilityIdentifier("markerCorrection.word.\(row.id)")
    }
}
