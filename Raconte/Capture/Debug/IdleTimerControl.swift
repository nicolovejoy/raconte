import Foundation
#if os(iOS)
import UIKit
#endif

/// Seam over "keep the screen awake while capturing" — the one piece of UIKit the
/// capture model needs, isolated so `CaptureScreenModel` can hold the display-awake
/// hold as model state (nav T2) instead of a view-lifecycle `.onChange`/`.onAppear`/
/// `.onDisappear` trio that only fires while `CaptureView` happens to be mounted.
@MainActor
protocol IdleTimerControlling: AnyObject {
    func setIdleTimerDisabled(_ disabled: Bool)
}

/// Live implementation. iOS has an idle timer to disable; macOS has none — the
/// no-op keeps `CaptureScreenModel` platform-agnostic rather than `#if os(iOS)`-gating
/// the call site.
@MainActor
final class PlatformIdleTimer: IdleTimerControlling {
    func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
