import Foundation

/// Whether a capture has a live transcript log, in the three answers §11 settled on.
///
/// `unreadable` is emphatically **not** `absent`: an entry whose log we failed to read
/// still has a transcript, and any UI that offers "no transcript — re-derive?" over it
/// would be lying about what is on disk. Same mistake as issue #11, one layer up.
enum EntryTranscriptState: Sendable, Equatable {
    /// No `transcript/live.jsonl`. The honest "not transcribed".
    case absent
    /// The log exists and could not be read.
    case unreadable
    /// The log was read. Whether it held any committed text is a separate question —
    /// see `EntryListItem.hasTranscriptText`.
    case present
}

/// Everything about an item that is less than fully trustworthy.
///
/// A degradation is never a reason to hide an entry. Recovery's rule — a corrupt
/// manifest is "unknown state", not "no capture" — applies here too: the library is how
/// the owner finds a recording, and an entry we can't fully describe is the one he most
/// needs to see.
struct EntryDegradation: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// No `manifest.json`. Dates fall back to the ULID timestamp.
    static let manifestAbsent = EntryDegradation(rawValue: 1 << 0)
    /// `manifest.json` exists and did not decode.
    static let manifestCorrupt = EntryDegradation(rawValue: 1 << 1)
    /// `entry.json` exists and did not decode — journal, backdate and trash state are
    /// all unknown, and the item shows the defaults *without* having adopted them.
    static let metadataUnreadable = EntryDegradation(rawValue: 1 << 2)
    /// `transcript/live.jsonl` exists and could not be read.
    static let transcriptUnreadable = EntryDegradation(rawValue: 1 << 3)
    /// The sidecar names a journal the registry does not hold (or the registry itself
    /// was unreadable — `LibraryScanResult.journalsUnreadable` distinguishes them).
    static let journalUnresolved = EntryDegradation(rawValue: 1 << 4)
    /// Fewer log lines than `TranscriptRef.committedRecords` — the app was killed and
    /// the tail is short. The snippet is still real, just possibly not the whole story.
    static let transcriptTruncated = EntryDegradation(rawValue: 1 << 5)
    /// A promoted revision chain exists (`transcript/canonical-<n>.json`) and at least
    /// one file in it failed to decode (T6c). The displayed text still comes from the
    /// best readable revision — never hidden — but may not be the true head.
    static let revisionUnreadable = EntryDegradation(rawValue: 1 << 6)

    /// Every flag declared above. **Add a new flag here and to `reasonTable`.**
    ///
    /// Swift cannot enumerate an `OptionSet`'s static members (no `Mirror` over a type),
    /// so this list is the closest thing to T2.5's manifest field-count tripwire:
    /// `EntryDegradationTableTests` pins its bit count, so adding a flag without
    /// updating both lists fails the suite rather than silently dropping the new flag
    /// out of every accessibility label.
    static let allDeclared: EntryDegradation = [
        .manifestAbsent, .manifestCorrupt, .metadataUnreadable,
        .transcriptUnreadable, .journalUnresolved, .transcriptTruncated, .revisionUnreadable,
    ]

    /// Calm, specific phrases for the library row's degraded marker — never "error" or
    /// "corrupt", per the M3 T4 brief: a degradation is a reason to look, not to alarm.
    ///
    /// Lives here rather than in `LibraryView` (where it started) so the flags and the
    /// words for them are read together and the tripwire above can cover both.
    static let reasonTable: [(flag: EntryDegradation, reason: String)] = [
        (.manifestAbsent, "recording details incomplete"),
        (.manifestCorrupt, "recording details incomplete"),
        (.metadataUnreadable, "entry settings unreadable"),
        (.journalUnresolved, "journal not found"),
        (.transcriptUnreadable, "transcript unreadable"),
        (.transcriptTruncated, "transcript may be incomplete"),
        (.revisionUnreadable, "transcript revision unreadable"),
    ]

    /// The reasons this value carries, in table order and de-duplicated (absent and
    /// corrupt manifests share a phrase — the owner does not need the difference).
    var accessibilityReasons: [String] {
        var reasons: [String] = []
        for entry in Self.reasonTable where contains(entry.flag) && !reasons.contains(entry.reason) {
            reasons.append(entry.reason)
        }
        return reasons
    }
}

/// One row of the library, derived from one capture directory.
///
/// A value type with no filesystem inside it, so every rule about dates, filing and
/// trash is reachable from a unit test with no disk. `LibraryScanner` is the only thing
/// that knows where the bytes come from.
struct EntryListItem: Sendable, Equatable, Identifiable {
    var captureID: String
    var id: String { captureID }

    /// The sidecar, whole. Held rather than flattened into copies: `effectiveDate` and
    /// friends below are `EntryMetadata`'s own rules, and three parallel fields with
    /// re-derived accessors are three chances for the row and the file to disagree —
    /// only a pinning test held them together before.
    var metadata: EntryMetadata

    /// The journal id as written in `entry.json` — kept raw so a dangling reference is
    /// visible rather than silently reading as "unfiled".
    var journalID: String? {
        get { metadata.journalID }
        set { metadata.journalID = newValue }
    }
    /// Resolved against the registry. `nil` when unfiled, dangling, or unresolvable.
    var journal: Journal?

    /// When the recording was made: the manifest's `createdAt`, else the ULID's
    /// millisecond prefix. Never user-editable.
    var capturedAt: Date
    /// The backdate, when the owner set one. `nil` is not "same as capturedAt" — it is
    /// "never backdated", and the two must stay distinguishable (see `EntryMetadata`).
    var originalDate: PartialDate? {
        get { metadata.originalDate }
        set { metadata.originalDate = newValue }
    }
    /// Precision `originalDate` was set at, defaulted. Meaningless when `originalDate`
    /// is nil — display code should gate on `isBackdated` before reading it.
    var originalDatePrecision: DatePrecision { metadata.effectivePrecision }

    /// The capture was a two-voice reading (T6 §14). Read-only: nothing on the library
    /// side edits it, and the capture screen's carry-over reads it through here.
    var multiVoice: Bool { metadata.multiVoice }

    var durationSeconds: Double

    /// `final/recording.m4a` is present and non-empty (`CaptureSnapshot.finalM4APresent`,
    /// computed by the scan). Carried onto the row solely so `hasAudio` below can be
    /// right — nothing displays it.
    var finalM4APresent: Bool

    /// There is audio to play. **Not `durationSeconds > 0`** (final-review I3):
    /// `LibraryScanner.durationSeconds` returns `0` when there are no raw segments AND
    /// `final.durationFrames` is nil, which is anomalous but reachable (a verified
    /// manifest with no frame count at all — see `SyncTreeScanner`'s comment on it, and
    /// `SyncRecordExchange.audioRecordToPush`'s refusal to push one). Gating playback on
    /// the duration would hide the play button for exactly that entry — the one artifact
    /// this app promises is indestructible — even though the `.m4a` is sitting there and
    /// would play.
    ///
    /// This is the row-level restatement of `PlayableSourceSelector.select` returning
    /// something other than `.none`: a present final `.m4a` wins, else any raw frames.
    /// `durationSeconds > 0` covers the raw-segments half exactly (both are
    /// `PlayableSourceSelector.frameTotal(of: rawSegments) > 0`, modulo the finalized
    /// case where the m4a flag already answers first).
    var hasAudio: Bool { finalM4APresent || durationSeconds > 0 }

    /// First stretch of committed transcript text, whitespace-collapsed and truncated.
    /// `nil` when there is no readable text — which includes a readable but empty log.
    var snippet: String?
    var transcript: EntryTranscriptState

    var trashedAt: Date? {
        get { metadata.trashedAt }
        set { metadata.trashedAt = newValue }
    }
    var degradations: EntryDegradation

    /// Images attached to this capture (image capture plan Task 3), populated by the
    /// scan via `ImageStore.readSidecars`, ULID order — same order as `ImageStore
    /// .images(captureID:)`. Defaulted to `[]` so every pre-existing construction site
    /// (test fixtures that don't exercise images) keeps compiling unchanged; the one
    /// production site, `LibraryScanner.item(for:)`, always passes a real scan result.
    var images: [ImageSidecar]
    /// The earliest-added image, for the library row's leading thumbnail. `nil` when
    /// there are no images.
    var leadingThumbnail: ImageSidecar? { images.first }

    init(captureID: String,
         capturedAt: Date,
         durationSeconds: Double = 0,
         // Defaulted false so every existing construction site keeps compiling: a
         // fixture that passes a non-zero `durationSeconds` already reads as
         // `hasAudio`, and one that passes neither is the no-audio row it always was.
         // Only the anomalous m4a-present-but-frameless case needs it stated.
         finalM4APresent: Bool = false,
         metadata: EntryMetadata = .defaults,
         journal: Journal? = nil,
         snippet: String? = nil,
         transcript: EntryTranscriptState = .absent,
         degradations: EntryDegradation = [],
         images: [ImageSidecar] = []) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.durationSeconds = durationSeconds
        self.finalM4APresent = finalM4APresent
        self.metadata = metadata
        self.journal = journal
        self.snippet = snippet
        self.transcript = transcript
        self.degradations = degradations
        self.images = images
    }

    /// The date the library sorts and groups by. Defined once, in
    /// `EntryMetadata.effectiveDate(capturedAt:)`, and now *called* rather than restated.
    var effectiveDate: Date { metadata.effectiveDate(capturedAt: capturedAt) }

    /// Precision-aware display of the effective date: `originalDate.formatted` when
    /// backdated (so a year-only entry reads "1998", never "Jan 1, 1998"), else
    /// `capturedAt` at day precision — the same rule `DatePrecision.formatted` used to
    /// apply to `effectiveDate` before `PartialDate` absorbed it.
    func formattedEffectiveDate(dayStyle: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        if let originalDate { return originalDate.formatted(dayStyle: dayStyle) }
        return capturedAt.formatted(date: dayStyle, time: .omitted)
    }

    var isBackdated: Bool { originalDate != nil }

    /// This entry's row should carry the time of day as well as the date (#125): several
    /// readings in one day are otherwise indistinguishable in the list.
    ///
    /// Two conditions, both necessary:
    ///
    /// - **Not backdated.** A backdated row shows a *user-authored* date, and a
    ///   `PartialDate` has no time of day. Taking one from `capturedAt` would attach the
    ///   moment of the reading to the date of the thing being read — a lie about which
    ///   the row is claiming to date. Backdated rows are unchanged even inside the week.
    /// - **`capturedAt` falls in the calendar week containing `now`**, in
    ///   `America/Los_Angeles` (`Calendar.gregorianPacific`), never UTC — bucketing
    ///   UTC-stamped instants by a UTC day rolls the owner's week over at 5pm Pacific.
    ///
    /// The membership test is half-open (`>= start`, `< end`) against the week's own
    /// interval, matching `JournalSpan.contains`: `dateInterval(of:for:).end` is already
    /// the first instant of the NEXT week, so `<` covers every instant of this one
    /// (including its final sub-second) without a synthetic "last instant".
    func showsCaptureTime(now: Date, calendar: Calendar = .gregorianPacific) -> Bool {
        guard !isBackdated else { return false }
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
        return capturedAt >= week.start && capturedAt < week.end
    }

    /// The library row's date line (#125). Identical to `formattedEffectiveDate()`
    /// everywhere except a non-backdated entry captured in the current week, which also
    /// gets the time to the minute — "Aug 31, 9:41 PM", the same date+time pair the
    /// backdated marker's accessibility label already uses.
    ///
    /// A sibling of `formattedEffectiveDate()` rather than a parameter on it: the other
    /// three callers (`CaptureReceipt`, `EntryInfoSheet`, `EntryDetailView`) render the
    /// bare date and are out of scope for #125.
    func formattedLibraryRowDate(now: Date,
                                 calendar: Calendar = .gregorianPacific,
                                 dayStyle: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        guard showsCaptureTime(now: now, calendar: calendar) else {
            return formattedEffectiveDate(dayStyle: dayStyle)
        }
        return capturedAt.formatted(date: dayStyle, time: .shortened)
    }

    /// The weekday for this entry's backdate — `nil` unless `originalDate` is set AND
    /// at `.day` precision (issue #48). A capture-date-only entry has no user-authored
    /// day to name a weekday for, so it is `nil` here regardless of `capturedAt`'s own
    /// (exact) weekday — see `PartialDate.weekdayText`.
    func weekdayText(style: WeekdayStyle = .abbreviated) -> String? {
        originalDate?.weekdayText(style: style)
    }
    /// The backdate came from the recording's own opening words and has not been edited
    /// (M3 issue #15) — the detail screen says so under the date.
    var backdateWasDetected: Bool { metadata.backdateWasDetected }
    var isTrashed: Bool { metadata.isTrashed }

    /// A journal was named and could not be resolved. Distinct from unfiled.
    var hasDanglingJournal: Bool { journalID != nil && journal == nil }

    /// #71: this entry's effective date falls outside its journal's declared span.
    /// Flagged, never blocked (owner ruling 4, 2026-08-18) — must never gate a write,
    /// disable a control, or change what any entry-list filter returns. `journal == nil`
    /// and a journal with no `span` both give `false` (`JournalSpan.flags`'s own rule).
    var isDatedOutsideJournalSpan: Bool { JournalSpan.flags(journal?.span, effectiveDate) }

    /// There is transcript text to show. Deliberately not the same as
    /// `transcript == .present`: an empty log is readable and says nothing.
    var hasTranscriptText: Bool { snippet?.isEmpty == false }
}

// MARK: - Sorting

extension EntryListItem {
    /// Newest first by effective date, so a backdated 1987 entry sorts under 1987 rather
    /// than under the afternoon it was read aloud.
    ///
    /// Ties break on `captureID` descending. ULIDs are time-ordered, so that is "most
    /// recently recorded first" — and it makes the order total, which matters the moment
    /// the owner backdates two entries to the same day and expects a stable list.
    static func sortedByEffectiveDate(_ items: [EntryListItem]) -> [EntryListItem] {
        items.sorted {
            $0.effectiveDate == $1.effectiveDate
                ? $0.captureID > $1.captureID
                : $0.effectiveDate > $1.effectiveDate
        }
    }
}

// MARK: - Filtering

/// Which journal a library view is showing.
///
/// An enum rather than an optional id because "all journals" and "the entries with no
/// journal" are both real views and `nil` cannot mean both.
enum JournalScope: Sendable, Equatable {
    case all
    case journal(String)
    case unfiled
}

/// Which side of the trash a library view is showing (M3 T5 owns the Trash screen; the
/// filter lands now so the scan never has to grow a second code path for it).
enum TrashScope: Sendable, Equatable {
    case excludeTrashed
    case trashedOnly
    case all
}

struct EntryListFilter: Sendable, Equatable {
    var journal: JournalScope
    var trash: TrashScope

    init(journal: JournalScope = .all, trash: TrashScope = .excludeTrashed) {
        self.journal = journal
        self.trash = trash
    }

    /// The library's default view: everything not in the trash.
    static let `default` = EntryListFilter()

    func matches(_ item: EntryListItem) -> Bool {
        switch trash {
        // An item whose `entry.json` is unreadable has an *unknown* trash state. It is
        // shown in the normal library and withheld from the Trash view, deliberately
        // asymmetric: a visible entry that may be deleted is a nuisance, an invisible
        // one is indistinguishable from data loss.
        case .excludeTrashed where item.isTrashed: return false
        case .trashedOnly where !item.isTrashed: return false
        default: break
        }
        switch journal {
        case .all: return true
        case .unfiled: return item.journalID == nil
        // Matches on the raw id, not the resolved journal: a dangling reference still
        // belongs to whatever it names, and filtering on resolution would make those
        // entries reachable from no journal view at all.
        case .journal(let id): return item.journalID == id
        }
    }

    /// Filter, then sort. The library never presents one without the other.
    func apply(to items: [EntryListItem]) -> [EntryListItem] {
        EntryListItem.sortedByEffectiveDate(items.filter(matches))
    }
}

// MARK: - Snippet

/// The one-line preview drawn from committed transcript text.
enum EntrySnippet {
    static let characterLimit = 160

    /// Whitespace-collapsed, trimmed, cut at a word boundary. `nil` for empty input, so
    /// "has no text" is an absence rather than an empty string that renders as a blank
    /// row.
    static func make(from text: String, limit: Int = characterLimit) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit, limit > 0 else { return collapsed }
        let head = collapsed.prefix(limit)
        if let lastSpace = head.lastIndex(of: " "), lastSpace > head.startIndex {
            return String(head[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }
}
