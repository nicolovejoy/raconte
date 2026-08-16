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

    /// Which of the screen's three jobs it is doing right now.
    ///
    /// Added 2026-08-15 with the receipt (owner ruling, option B): "just stopped" used to
    /// be indistinguishable from "idle", because the coordinator is replaced by a fresh
    /// idle one the moment a capture finalizes. That is precisely why the finished
    /// transcript had nowhere to go and ended up loose on the landing screen. A capture
    /// ending is now a state the screen can be IN, not merely a phase it passed through.
    enum Mode: Equatable, Sendable {
        /// Arming the next reading: journal, backdate, two voices, last entry, library.
        case setup
        /// A capture is under way.
        case capturing
        /// A capture just finished and its receipt is up, awaiting dismissal.
        case receipt
    }

    var mode: Mode

    /// The single most recent entry, shown as one line on the landing screen.
    ///
    /// Was a scrolling list of three. Owner smoke, 2026-08-15: "I'd rather not have too
    /// many things scrolling around. Would be better just to see the most recent one and
    /// then have an obvious link to the Library." The list was also what made the setup
    /// band a scroll view that competed with the control bar for height, which is why its
    /// last row rendered sliced in half.
    var showsLastEntry: Bool

    /// The full-width way into the library, at the foot of the landing area.
    ///
    /// Replaces the "See all" link that sat in the Recent header's top-right corner —
    /// the least prominent element on screen for the only route to everything else
    /// (owner: an obvious link to the Library, "not just up in the top right").
    var showsLibraryDoor: Bool

    /// The Two-voices toggle. Already `.disabled` outside `.idle` (it can only be honoured
    /// before recording starts, since the frame-0 opening-voice marker is written at
    /// start), so hiding it during a capture removes a control that could not be used
    /// anyway rather than taking away a capability.
    var showsMultiVoiceField: Bool

    /// Whether the LIVE transcript band is on screen at all.
    ///
    /// Only ever during a capture. It used to linger after one, because the coordinator
    /// deliberately holds the finished text (so the panel doesn't blank the instant you
    /// stop) and nothing cleared it until the next recording began — which left the words
    /// stranded on the landing screen as loose, untappable text. The finished transcript
    /// now belongs to the receipt, which is a different thing in a different place.
    var showsLiveTranscript: Bool

    /// Whether the receipt owns the middle of the screen.
    var showsReceipt: Bool

    /// Whether the setup band renders the one-line `CompactBackdateSummary` (tap to open
    /// an editor sheet) instead of the full inline `BackdateField`.
    ///
    /// Added for approach 2 of the 2026-08-16 IA discussion (owner: "there's two
    /// scrollable sections above [the bar]... I would rather have none, especially during
    /// the recording"). The full `BackdateField` — a toggle plus a precision date picker —
    /// is not phase-gated (it writes through to the live capture mid-recording), so before
    /// this it was squeezed into `setupHeightWhileCapturing` and forced to scroll
    /// internally: a second scroll view stacked above the transcript's own. The backdate
    /// is bounded content — a toggle and a date — so it should never need to scroll; only
    /// the transcript is genuinely unbounded. Backdating stays reachable through the
    /// compact summary's sheet, it just stops needing inline scroll space to do it.
    var usesCompactBackdateField: Bool

    /// Whether launch-recovered-capture banners are on screen.
    ///
    /// They are about PAST orphaned recordings, unrelated to whatever is happening now —
    /// hiding them during a capture loses nothing (the state they're built from,
    /// `visibleRecovered`, is untouched, so they reappear once idle again), and removes
    /// the last piece of unbounded-in-principle content from the setup band while
    /// recording, alongside `usesCompactBackdateField`.
    var showsRecoveryBanners: Bool

    /// Whether the transcript fills the height available above the control bar (with its
    /// own scroll) instead of being capped.
    ///
    /// The cap existed to stop the transcript shoving the controls down. With the controls
    /// pinned, that pressure is gone and the cap only wastes screen: the transcript is the
    /// one thing worth looking at while reading aloud.
    var transcriptFillsAvailableHeight: Bool

    /// `hasReceipt` is the screen's own state, not the machine's: a capture that has
    /// finalized leaves the coordinator `.idle` (a fresh one is spawned), so the phase
    /// alone cannot distinguish "just finished a reading" from "opened the app".
    static func make(phase: CaptureState, hasReceipt: Bool = false) -> CaptureLayoutModel {
        switch phase {
        // A capture is under way — including the phases either side of an interruption,
        // which must NOT change the layout, or the screen would reflow exactly when the
        // owner is trying to get back to reading.
        //
        // Checked BEFORE `hasReceipt` on purpose: a live capture always outranks a
        // leftover receipt. If a stale receipt could survive into a recording it would
        // cover the live transcript with the previous entry's words, which is a worse
        // version of the bug this whole state exists to fix.
        case .preparing, .recording, .interrupted, .resuming, .stopping:
            return .init(mode: .capturing,
                         showsLastEntry: false,
                         showsLibraryDoor: false,
                         showsMultiVoiceField: false,
                         showsLiveTranscript: true,
                         showsReceipt: false,
                         usesCompactBackdateField: true,
                         showsRecoveryBanners: false,
                         transcriptFillsAvailableHeight: true)

        case .idle, .captured, .finalizing, .complete:
            // Just stopped. The receipt takes the middle; the arming controls step aside,
            // because nothing here is about the NEXT reading until this one is dismissed.
            // Backdating is not lost — the receipt's "Open" leads to the entry, where the
            // date is editable on a screen built for it.
            if hasReceipt {
                return .init(mode: .receipt,
                             showsLastEntry: false,
                             showsLibraryDoor: false,
                             showsMultiVoiceField: false,
                             showsLiveTranscript: false,
                             showsReceipt: true,
                             usesCompactBackdateField: false,
                             showsRecoveryBanners: false,
                             transcriptFillsAvailableHeight: false)
            }
            // The landing screen: arm the next reading, glance at the last one, or leave
            // for the library.
            return .init(mode: .setup,
                         showsLastEntry: true,
                         showsLibraryDoor: true,
                         showsMultiVoiceField: true,
                         showsLiveTranscript: false,
                         showsReceipt: false,
                         usesCompactBackdateField: false,
                         showsRecoveryBanners: true,
                         transcriptFillsAvailableHeight: false)
        }
    }
}
