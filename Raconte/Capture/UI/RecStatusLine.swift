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

/// The elapsed-time readout and status text, on ONE line.
///
/// It used to be a two-line stack with a 44 pt clock above a 15 pt status — roughly 78 pt
/// of a 331 pt bar, and the largest single item in the bar the owner rejected as too tall
/// (smoke, 2026-08-15). The clock was literally taller than the record button beneath it.
/// Laid out inline it costs about 34 pt, and the row has room left over for Done, which
/// removes another row entirely (approved mockup, Option B).
///
/// Sizes come from `CaptureControlBarMetrics` rather than being written here, because the
/// ruling this shape exists to satisfy — the bar takes at most a third of the screen — is
/// a property of the sum, and a sum needs its terms in one place to be checkable.
struct RecStatusLine: View {
    let phase: CaptureState
    let canResume: Bool
    let elapsed: TimeInterval

    private var isLive: Bool { phase == .recording }

    var body: some View {
        HStack(spacing: 8) {
            Text(RecFormat.clock(elapsed))
                .font(.system(size: CaptureControlBarMetrics.clockPointSize,
                              weight: .regular).monospacedDigit())
                .foregroundStyle(isLive ? Color.red : Color(white: 0.9))
                // The UI test's anchor for "where does the bar start" — the topmost thing
                // in the topmost row. An identifier on a `Text` is safe; one on a
                // CONTAINER flattens its children out of the accessibility tree, which is
                // the trap this file has now hit three times.
                //
                // Renamed from `capture.clock` (nav T6): a SwiftUI element carries exactly
                // ONE accessibility identifier — chaining a second `.accessibilityIdentifier`
                // call on this same `Text` would silently replace the first, not add a
                // second address — so this is a rename, not an addition. It is still the
                // topmost element of the topmost row (`CaptureControlsUITests
                // .assertBarFitsWithinAThird` uses it purely as a position anchor and is
                // updated to the new name); it is also nav T6's fallback address for the
                // elapsed reading on iPhone, where the split view is collapsed and the
                // sidebar's own `sidebar.capture.live` element does not exist while the
                // capture screen itself is on screen. Identifier only — no size/spacing/
                // geometry change (invariant 8).
                .accessibilityIdentifier("capture.elapsed")

            if phase == .recording || phase == .interrupted {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(phase == .interrupted ? 0.5 : 1)
            }

            Text(RecFormat.statusText(phase: phase, canResume: canResume))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.78))
                // The status string varies a lot in length ("Recording" against
                // "Interrupted — reconnecting…"). The bar is anchored to the bottom edge,
                // so a string that wraps to a second line grows the bar UPWARD and moves
                // the record button under the owner's thumb. Shrink, never wrap.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
