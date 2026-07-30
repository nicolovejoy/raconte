import SwiftUI

/// A minimal horizontal mic-level bar driven by `CaptureCoordinator.micLevel` (0…1).
/// Red while capturing (audio flowing), neutral otherwise so it never implies the app
/// is live when it isn't (affordance rule: red == capturing only).
struct MicMeter: View {
    /// Latest RMS level, 0…1.
    let level: Float
    /// True only while audio is actually flowing (phase == recording).
    let isLive: Bool

    private var clamped: CGFloat { CGFloat(min(1, max(0, level))) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.18))
                Capsule()
                    .fill(isLive ? Color.red : Color(white: 0.4))
                    .frame(width: geo.size.width * clamped)
                    .animation(.linear(duration: 0.08), value: clamped)
            }
        }
        .frame(height: 8)
        .frame(maxWidth: 260)
        .accessibilityHidden(true)
    }
}
