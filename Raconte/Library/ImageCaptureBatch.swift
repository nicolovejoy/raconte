import Foundation

/// #134: the running tally behind the camera's take-another loop in
/// `ImageCapturePickerSheet`. Photographing several pages of a journal for one entry used
/// to be one trip through the sheet per page; now a landed shot returns to the sheet with
/// this count, the camera row re-titled, and the toolbar button turned from Cancel into
/// Done (a photo that has already landed cannot be cancelled from here).
///
/// Only successful shots are recorded: the sheet's failure and cancel branches never call
/// `recordLanded()`, so there is no failed-state to keep consistent. Pure, so the copy rules
/// are pinned in `ImageCaptureBatchTests` — the simulator has no camera to drive.
struct ImageCaptureBatch: Equatable, Sendable {
    private(set) var added = 0

    mutating func recordLanded() { added += 1 }

    var hasLanded: Bool { added > 0 }

    var cameraButtonTitle: String { hasLanded ? "Take Another…" : "Take Photo…" }

    var dismissButtonTitle: String { hasLanded ? "Done" : "Cancel" }

    var summary: String { added == 1 ? "1 photo added" : "\(added) photos added" }
}
