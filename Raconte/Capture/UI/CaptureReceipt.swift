import Foundation

/// What the capture screen shows in the beat right after you stop recording.
///
/// Owner smoke, 2026-08-15: after Done, the finished transcript stayed on screen as loose,
/// unheaded, untappable text below a sliced Recent list — "a really messed up user
/// experience that has not been engineered correctly". The text was there on purpose
/// (`LiveTranscriptionCoordinator.lastCompletedText` is held so the panel doesn't blank the
/// instant a capture ends) but nothing ever gave it a job, and the #53 rebuild moved it
/// into a band of its own where it just squatted.
///
/// The ruling (owner, same day, option B of the capture-landing mockup) is that stopping
/// gets **its own state**: a receipt naming what was just captured, showing its opening
/// prose with the voice marks, and offering the two things you might want next — open it,
/// or record another. It stays until dismissed; it never fades on a timer, because the
/// owner is typically looking down at a paper journal when a recording ends. This also
/// makes good on the post-stop receipt approved in the 2026-08-08 IA pass and never built.
///
/// Pure and `Sendable`: built from an already-loaded entry plus its transcript, with no I/O
/// of its own, so every rule below is unit-testable without a simulator.
struct CaptureReceipt: Equatable, Sendable, Identifiable {

    /// The entry that was just recorded. Also the id the "Open" action navigates to.
    var captureID: String
    var id: String { captureID }

    /// The entry's effective date, already formatted — the same string the library row
    /// shows, taken from `EntryListItem.formattedEffectiveDate()` rather than re-derived,
    /// so the receipt and the row can never disagree about what day this entry is.
    var dateText: String

    var durationSeconds: Double

    /// Whether this capture was a two-voice reading, straight off the sidecar. Drives
    /// nothing but the summary line — the prose gets its voices from `body`.
    var isMultiVoice: Bool

    /// What to render as the receipt's prose. Deliberately the SAME enum the detail screen
    /// switches over, not a parallel one: both are answering "what does this entry's
    /// transcript look like", and two copies of that answer drift.
    var body: EntryDetailView.TranscriptDisplay

    /// Assembled from the pieces the caller already has in hand.
    ///
    /// `transcript` is optional because the receipt must survive a transcript that could
    /// not be read at all — a recording with no usable transcript is still a recording
    /// worth acknowledging, and refusing to show a receipt would make a degraded read look
    /// like a lost capture. That case renders as `.absent`, which the view states plainly.
    /// `@MainActor` only because `EntryDetailView.transcriptDisplay` is a static on a
    /// `View` and so inherits the actor. The function itself touches nothing isolated —
    /// it is a pure switch — and the caller is already on the main actor.
    @MainActor
    static func make(entry: EntryListItem, transcript: EntryTranscript?) -> CaptureReceipt {
        CaptureReceipt(
            captureID: entry.captureID,
            dateText: entry.formattedEffectiveDate(),
            durationSeconds: entry.durationSeconds,
            isMultiVoice: entry.multiVoice,
            body: transcript.map { EntryDetailView.transcriptDisplay($0) } ?? .absent)
    }

    /// The line under the date: how long, in how many voices, over how many paragraphs.
    ///
    /// Only facts that are actually known appear. A single-voice reading does not say
    /// "1 voice" (it says nothing — one voice is the unremarkable case), and paragraphs are
    /// counted only when the prose really is attributed, since a `.plain` transcript has no
    /// paragraph structure to count and guessing one from line breaks would be a fiction.
    var summaryLine: String {
        var parts = [RecFormat.clock(durationSeconds)]

        if isMultiVoice {
            parts.append("2 voices")
        }

        if case .attributed(let paragraphs) = body, paragraphs.count > 1 {
            parts.append("\(paragraphs.count) paragraphs")
        }

        return parts.joined(separator: " · ")
    }

    /// Whether there is prose worth showing. False for every degraded read, which the view
    /// turns into one calm line rather than an empty box.
    var hasProse: Bool {
        switch body {
        case .plain(let text): return !text.isEmpty
        case .attributed(let paragraphs): return !paragraphs.isEmpty
        case .absent, .unreadable, .empty: return false
        }
    }

    /// The one line shown in place of prose. Keeps issue #11's rule — absent, unreadable
    /// and present-but-empty are three different answers and none of them is an error —
    /// on a screen where the owner has just finished speaking and wants to know what
    /// happened to it.
    var proseUnavailableText: String? {
        switch body {
        case .plain, .attributed: return nil
        case .empty: return "No words were transcribed."
        case .absent: return "The recording is saved. No transcript yet."
        case .unreadable: return "The recording is saved. Its transcript could not be read."
        }
    }
}
