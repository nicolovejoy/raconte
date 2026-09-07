import SwiftUI

/// The sidebar's live-recording indicator (design §5's visibility guarantee, nav T6),
/// factored out of `SidebarRowView` for containment (#67 item 3): this is the ONLY view
/// in the app that reads `CaptureCoordinator.elapsed`. Before this existed, `SidebarView`
/// read `elapsed` directly to build the whole Capture row, which — since `elapsed` is an
/// `@Observable` published property read on every body evaluation — re-evaluated the
/// ENTIRE sidebar (the list, every row, every journal's date-line lookup) once per second
/// while a capture was running. SwiftUI's fine-grained `@Observable` invalidation means a
/// view only re-runs when ITS OWN body reads a property that changed; moving the read
/// down into this small, isolated view confines the once-a-second cost to just this
/// badge. `SidebarView`/`SidebarRowView` still read `phase` (to decide whether to embed
/// this view at all), but phase changes only a handful of times per capture — nothing
/// like the once-a-second cadence of `elapsed`.
struct CaptureLiveBadge: View {
    let services: AppServices

    private var row: CaptureSidebarRow {
        CaptureSidebarRow.make(phase: services.capture.coordinator.phase,
                               elapsed: services.capture.coordinator.elapsed)
    }

    var body: some View {
        if row.isLive, let elapsedText = row.elapsedText {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(elapsedText)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.capture.live")
            .accessibilityLabel("Recording, \(elapsedText)")
        }
    }
}
