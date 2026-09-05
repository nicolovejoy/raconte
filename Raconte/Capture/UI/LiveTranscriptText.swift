import SwiftUI

/// The live transcript (#118 §5): committed text at full strength, the hypothesis dimmed,
/// merged by frame position. Dims on `isProvisional`, never on position — the consolidator
/// merges out-of-order results, so a hypothesis can land mid-text, and "dim the tail" is
/// wrong on exactly the case the consolidator exists to handle.
///
/// Serif, matching the receipt: the same words in the same face from the moment they
/// appear. `CaptureProse.font` is shared with `receiptProse` for that reason.
struct LiveTranscriptText: View {
    let runs: [ConsolidatedTranscriptRun]

    var body: some View {
        Text(Self.attributed(runs, ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Pure, so the dim-in-the-middle rule is testable without a renderer. Runs are joined
    /// with single spaces; the separator takes the colour of the run before it.
    static func attributed(_ runs: [ConsolidatedTranscriptRun], ink: Color, dim: Color) -> AttributedString {
        var out = AttributedString()
        for run in runs where !run.text.isEmpty {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var space = AttributedString(" ")
                space.foregroundColor = out.runs.last?.foregroundColor
                out.append(space)
            }
            out.append(piece)
        }
        return out
    }
}

/// The one reading face on the capture screen — receipt prose and live transcript.
/// iOS keeps the semantic style so Dynamic Type still scales it; macOS is pinned to the
/// screen's legibility floor, because `.callout` is 12 pt there (see
/// `CaptureSurface.minimumControlPointSize`).
enum CaptureProse {
    static let font: Font = {
        #if os(macOS)
        .system(size: CaptureSurface.minimumControlPointSize, design: .serif)
        #else
        .system(.callout, design: .serif)
        #endif
    }()
}
