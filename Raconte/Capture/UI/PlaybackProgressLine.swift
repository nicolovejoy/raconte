import SwiftUI

/// Elapsed / total + thin progress bar for an active `CapturePlayback` (issue #3:
/// play/pause alone gives no position feedback). Shown once playback has started;
/// ticks via `CapturePlayback`'s observable `currentTime`.
struct PlaybackProgressLine: View {
    let playback: CapturePlayback
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Text(CaptureCoordinator.formatDuration(playback.currentTime))
            ProgressView(value: min(playback.currentTime, playback.duration),
                         total: max(playback.duration, 0.01))
                .tint(tint)
            Text(CaptureCoordinator.formatDuration(playback.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color(white: 0.7))
    }
}
