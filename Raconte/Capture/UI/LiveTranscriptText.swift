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
    /// #136: the frames of this capture's ¶ taps — the same coordinator state
    /// `CaptureCoordinator.paragraphFrames` exposes. Recomputed on every render from
    /// `runs`, so a provisional run that gets re-ranged moves the break with it.
    var paragraphFrames: [Int64] = []

    var body: some View {
        Text(Self.attributed(runs, paragraphFrames: paragraphFrames,
                             ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Pure, so the dim-in-the-middle rule is testable without a renderer. Runs are joined
    /// with single spaces, except at a paragraph break (#136), which renders as a blank
    /// line ("\n\n") instead — same nearer-edge cut rule the detail screen uses
    /// (`TranscriptAttribution.cutIndex(forFrame:ranges:)`), so live and post-hoc agree on
    /// where a break falls.
    static func attributed(_ runs: [ConsolidatedTranscriptRun], paragraphFrames: [Int64] = [],
                           ink: Color, dim: Color) -> AttributedString {
        let visible = runs.filter { !$0.text.isEmpty }
        let ranges = visible.map(\.range)
        let breaks = Set(paragraphFrames.map { TranscriptAttribution.cutIndex(forFrame: $0, ranges: ranges) })
        var out = AttributedString()
        for (index, run) in visible.enumerated() {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var separator = AttributedString(breaks.contains(index) ? "\n\n" : " ")
                separator.foregroundColor = out.runs.last?.foregroundColor
                out.append(separator)
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
