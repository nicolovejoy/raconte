/// When to raise "Couldn't Use That Photo" after a camera shot fails to add (#182).
///
/// Two events race: the `fullScreenCover` coming down (its `isPresented` goes false in
/// the camera's completion closure, so the `.onChange` fires straight away) and the
/// add's verdict (an `await onPick` that does a disk write first). The alert must wait
/// for the cover — presenting while it is still dismissing drops the alert — but it
/// must not wait for a LATER cover: the old relay set a flag after the verdict and
/// consumed it from the `.onChange`, which had already fired, so a failure sat
/// unconsumed until the next camera round-trip and alerted against that shot.
///
/// Since #121 it is driven by whichever cover precedes a verdict (the framing cover), not
/// the camera cover; the method names are kept because `CameraErrorRelayTests` pin them.
///
/// Pure, so both orderings pin in `CameraErrorRelayTests`; the simulator has no camera.
struct CameraErrorRelay: Equatable {
    private var coverIsDown = true
    private var failureParked = false

    /// The camera went up. Anything parked belongs to a round-trip the owner moved past.
    mutating func cameraPresented() {
        coverIsDown = false
        failureParked = false
    }

    /// The cover's `isPresented` went false. True when a verdict already failed and
    /// was waiting for this — raise the alert now.
    mutating func coverDismissed() -> Bool {
        coverIsDown = true
        defer { failureParked = false }
        return failureParked
    }

    /// The add failed. True when the cover is already down — raise the alert now;
    /// otherwise it is parked for `coverDismissed`.
    mutating func addFailed() -> Bool {
        if coverIsDown { return true }
        failureParked = true
        return false
    }
}
