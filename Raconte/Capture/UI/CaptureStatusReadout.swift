import SwiftUI

/// #155: the one view on the capture screen that reads `coordinator.elapsed`.
///
/// `elapsed` is assigned by `CaptureCoordinator.tick()` roughly ten times a second
/// (the loop runs every 100 ms), in step with `micLevel`. Reading it from
/// `CaptureView.body` (as `statusRow` did until #155) re-evaluated the entire screen —
/// control bar, meter, record row — on every tick. Reading it here confines that
/// invalidation to this leaf, exactly as `CaptureLiveBadge` does for the sidebar (#67
/// item 3, PR #153); `CaptureMicMeterReadout` does the same for `micLevel`. The
/// coordinator is passed by reference: the parent's body reads nothing tick-rate.
///
/// `RecStatusLine` stays the dumb renderer; the clock `Text` inside it keeps the
/// `capture.elapsed` identifier the UI tests anchor on.
struct CaptureStatusReadout: View {
    let coordinator: CaptureCoordinator

    var body: some View {
        RecStatusLine(phase: coordinator.phase,
                      canResume: coordinator.canResume,
                      elapsed: coordinator.elapsed)
    }
}
