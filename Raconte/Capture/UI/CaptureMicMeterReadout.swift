import SwiftUI

/// #155: the one view on the capture screen that reads `coordinator.micLevel`.
/// `micLevel` is assigned by `CaptureCoordinator.tick()` roughly ten times a second,
/// in the same loop as `elapsed`; reading it from `CaptureView.body` re-evaluated
/// the whole screen at that rate. Sibling of `CaptureStatusReadout`, same shape.
struct CaptureMicMeterReadout: View {
    let coordinator: CaptureCoordinator

    var body: some View {
        MicMeter(level: coordinator.micLevel,
                 isLive: coordinator.phase == .recording)
    }
}
