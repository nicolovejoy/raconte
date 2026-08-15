import Foundation

/// Which parts of the capture screen are on screen in a given phase, and whether the live
/// transcript is capped or free to fill the space above the controls (issue #53).
///
/// Exists because #53 is a LAYOUT defect with a behavioural cause: the record button, the
/// voice switch and the paragraph button used to live inside the page's single scroll
/// view, below content that grows. A live transcript appearing pushed them down by roughly
/// its own height, and on a long entry it pushed the voice switch clean off screen — the
/// owner reported the switch as "disappeared", which was really "scrolled out of view".
/// Voice marking became impossible mid-entry on exactly the long readings that need it.
///
/// The fix is structural (the controls move into a bar pinned to the bottom, outside the
/// scroll), and this type is the testable half: what is visible when. Same pattern and
/// file neighbourhood as `MarkerControlsModel`, and the same rule — the `switch` is
/// exhaustive with no `default`, so a new `CaptureState` breaks the build here instead of
/// silently deciding a section's fate.
struct CaptureLayoutModel: Equatable, Sendable {
    /// The "Recent" list. A browse affordance, and browsing is not something anyone does
    /// mid-reading; hiding it while capturing is what frees the height for the transcript.
    var showsRecentList: Bool

    /// The Two-voices toggle. Already `.disabled` outside `.idle` (it can only be honoured
    /// before recording starts, since the frame-0 opening-voice marker is written at
    /// start), so hiding it during a capture removes a control that could not be used
    /// anyway rather than taking away a capability.
    var showsMultiVoiceField: Bool

    /// Whether the transcript fills the height available above the control bar (with its
    /// own scroll) instead of being capped.
    ///
    /// The cap existed to stop the transcript shoving the controls down. With the controls
    /// pinned, that pressure is gone and the cap only wastes screen: the transcript is the
    /// one thing worth looking at while reading aloud.
    var transcriptFillsAvailableHeight: Bool

    /// Height the setup band keeps while a capture is under way, in points.
    ///
    /// Enough for the journal header plus the backdate row, and scrollable for the rest.
    /// A fixed slice rather than letting the setup band and the transcript both stretch:
    /// two greedy views split the space between them by rules nobody chose, and the point
    /// of #53 is that this screen's geometry stops being emergent.
    static let setupHeightWhileCapturing: Double = 200

    static func make(phase: CaptureState) -> CaptureLayoutModel {
        switch phase {
        // A capture is under way — including the phases either side of an interruption,
        // which must NOT change the layout, or the screen would reflow exactly when the
        // owner is trying to get back to reading.
        case .preparing, .recording, .interrupted, .resuming, .stopping:
            return .init(showsRecentList: false,
                         showsMultiVoiceField: false,
                         transcriptFillsAvailableHeight: true)

        // Idle, and the brief post-capture tail before a fresh idle coordinator replaces
        // this one. The setup layout returns: this is when browsing recents and arming
        // the next reading's two-voice setting are the things you actually want.
        case .idle, .captured, .finalizing, .complete:
            return .init(showsRecentList: true,
                         showsMultiVoiceField: true,
                         transcriptFillsAvailableHeight: false)
        }
    }
}
