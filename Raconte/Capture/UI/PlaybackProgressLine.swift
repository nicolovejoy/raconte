import SwiftUI

/// Dual-surface: renders on paper (entry detail) AND inside `RecoveryBanner` on the studio
/// surface. It takes the paper `label` role deliberately — 12 pt on macOS is closer to the
/// studio floor than the old 10 pt. The `ink` parameter lets the studio caller override the
/// figures' colour, since paper's appearance-following `inkSecondary` fails the studio floor.
///
/// Elapsed / total + a draggable position handle for an active `CapturePlayback`
/// (issue #3: no position feedback; issue #6: no way to move the playhead).
/// Shown once playback has started; ticks via the observable `currentTime`.
///
/// `Slider(onEditingChanged:)` rather than a custom `DragGesture`: one
/// implementation on both platforms, the begin/end signal the scrub needs, and
/// free `.adjustable` accessibility for UI tests. The seek fires on drag *end*
/// only — each raw-segment seek re-reads and re-schedules every later segment.
struct PlaybackProgressLine: View {
    let playback: CapturePlayback
    var tint: Color = .accentColor
    /// Accessibility-identifier namespace: `"finished"` / `"recovery"`.
    var idPrefix: String = "finished"
    /// The figures' colour. Paper default (entry detail, appearance-following); the studio
    /// caller (`RecoveryBanner`) passes `CaptureLabel.secondaryInkColor` — dark-appearance
    /// `inkSecondary` on the studio ground would be under the 7.0 capture floor.
    var ink: Color = InkTone.inkSecondary.color

    /// Non-nil only mid-drag; the slider reads the live position otherwise.
    @State private var scrubValue: Double?

    /// Decoded duration, never the manifest's frame count — AAC priming makes
    /// them differ, and the handle has to be able to reach the end.
    private var total: Double { max(playback.duration, 0.01) }

    var body: some View {
        HStack(spacing: 8) {
            Text(CaptureCoordinator.formatDuration(scrubValue ?? playback.currentTime))
                .accessibilityIdentifier("\(idPrefix).position")

            Slider(value: Binding(get: { scrubValue ?? min(playback.currentTime, total) },
                                  set: { scrubValue = $0 }),
                   in: 0...total,
                   onEditingChanged: { editing in
                       if editing {
                           playback.beginScrubbing()
                       } else {
                           playback.endScrubbing(at: scrubValue ?? playback.currentTime)
                           scrubValue = nil
                       }
                   })
                .tint(tint)
                .controlSize(.mini)
                .accessibilityIdentifier("\(idPrefix).scrubber")
                .accessibilityLabel("Playback position")

            Text(CaptureCoordinator.formatDuration(playback.duration))
                .accessibilityIdentifier("\(idPrefix).total")
        }
        .font(TypeRole.label.font.monospacedDigit())
        .foregroundStyle(ink)
    }
}
