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
    /// #164: this capture's voice taps (`CaptureCoordinator.voiceMarks`), placed by the
    /// same cut rule. Each one breaks the line and prefixes the voice's label.
    var voiceMarks: [LiveVoiceMark] = []
    /// The selected journal's configured labels; absent ones fall back to the uppercased
    /// id — the voice BUTTON's rule (`VoiceDisplay.accessibilityName`), so the band and
    /// the button always agree. The reading view's opt-in labels (#56) are a different
    /// surface with a different rule; this is a capture-time instrument.
    var voiceLabels: [String: String] = [:]

    var body: some View {
        Text(Self.attributed(runs, paragraphFrames: paragraphFrames, voiceMarks: voiceMarks,
                             voiceLabels: voiceLabels,
                             ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Pure, so the dim-in-the-middle rule is testable without a renderer. Runs are joined
    /// with single spaces, except at a paragraph break (#136) or a voice change (#164),
    /// which render as a blank line ("\n\n") instead — same nearer-edge cut rule the
    /// detail screen uses (`TranscriptAttribution.cutIndex(forFrame:ranges:)`), so live
    /// and post-hoc agree on where a break falls. A voice change also prefixes the run
    /// with "<label>: " in semibold; the later of two marks at one cut wins; a mark at
    /// index 0 labels the first run with no leading break.
    static func attributed(_ runs: [ConsolidatedTranscriptRun], paragraphFrames: [Int64] = [],
                           voiceMarks: [LiveVoiceMark] = [], voiceLabels: [String: String] = [:],
                           ink: Color, dim: Color) -> AttributedString {
        let visible = runs.filter { !$0.text.isEmpty }
        let ranges = visible.map(\.range)
        var breaks = Set(paragraphFrames.map { TranscriptAttribution.cutIndex(forFrame: $0, ranges: ranges) })
        var labels: [Int: String] = [:]
        for mark in voiceMarks {
            let index = TranscriptAttribution.cutIndex(forFrame: mark.frame, ranges: ranges)
            labels[index] = VoiceDisplay.accessibilityName(forVoice: mark.voice, voiceLabels: voiceLabels)
            breaks.insert(index)
        }
        var out = AttributedString()
        for (index, run) in visible.enumerated() {
            let colour = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var separator = AttributedString(breaks.contains(index) ? "\n\n" : " ")
                separator.foregroundColor = out.runs.last?.foregroundColor
                out.append(separator)
            }
            if let label = labels[index] {
                var prefix = AttributedString("\(label): ")
                prefix.foregroundColor = colour
                prefix.inlinePresentationIntent = .stronglyEmphasized
                out.append(prefix)
            }
            var piece = AttributedString(run.text)
            piece.foregroundColor = colour
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
