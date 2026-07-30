import SwiftUI

/// Pure formatting + status-text helpers for the capture screen (design §6: testable
/// without hardware).
enum RecFormat {
    /// Elapsed time as "M:SS", or "H:MM:SS" once past an hour. Zero-padded seconds
    /// (and minutes when hours are shown). Negative input clamps to zero.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The line under the timer describing what the app is doing. Mirrors the machine
    /// phase; the interrupted case distinguishes "tap Resume" from an in-flight retry.
    static func statusText(phase: CaptureState, canResume: Bool) -> String {
        switch phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing — don't speak yet"
        case .recording: return "Recording"
        case .interrupted: return canResume ? "Interrupted — tap Resume" : "Interrupted — reconnecting…"
        case .resuming: return "Resuming — don't speak yet"
        case .stopping: return "Saving…"
        case .captured, .complete: return "Saved"
        case .finalizing: return "Finalizing…"
        }
    }
}

/// The elapsed-time readout + status line shown above the record button.
struct RecStatusLine: View {
    let phase: CaptureState
    let canResume: Bool
    let elapsed: TimeInterval

    private var isLive: Bool { phase == .recording }

    var body: some View {
        VStack(spacing: 6) {
            Text(RecFormat.clock(elapsed))
                .font(.system(size: 44, weight: .light).monospacedDigit())
                .foregroundStyle(isLive ? Color.red : Color(white: 0.9))
            HStack(spacing: 8) {
                if phase == .recording || phase == .interrupted {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .opacity(phase == .interrupted ? 0.5 : 1)
                }
                Text(RecFormat.statusText(phase: phase, canResume: canResume))
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.6))
            }
        }
    }
}
