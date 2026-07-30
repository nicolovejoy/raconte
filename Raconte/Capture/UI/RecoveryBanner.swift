import SwiftUI

/// "Recovered recording: MM:SS" banner shown for each capture rescued at launch
/// (design §3). Keep is the default (nothing auto-deletes a real recording); Play
/// streams it via `CapturePlayback` (finalized `.m4a` or raw-segment fallback);
/// Delete removes the capture directory.
struct RecoveryBanner: View {
    let recording: RecoveredRecording
    let capturesRoot: URL
    let onKeep: () -> Void
    let onDelete: () -> Void

    @State private var playback: CapturePlayback?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Recovered recording: \(recording.formattedDuration)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(white: 0.95))
                    .accessibilityIdentifier("recovery.title")
                Spacer()
            }
            HStack(spacing: 10) {
                Button(action: togglePlay) {
                    Label(isPlaying ? "Pause" : "Play",
                          systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Keep", action: onKeep)
                    .buttonStyle(.bordered)

                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)

                Spacer()
            }
            .font(.subheadline)

            if let playback {
                PlaybackProgressLine(playback: playback, tint: .orange)
            }
        }
        .padding(14)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var isPlaying: Bool { playback?.isPlaying ?? false }

    private func togglePlay() {
        let p = playback ?? CapturePlayback(capturesRoot: capturesRoot, captureID: recording.captureID)
        playback = p
        if p.isPlaying { p.pause() } else { p.play() }
    }
}
