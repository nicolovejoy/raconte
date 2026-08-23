import Foundation
import Observation

/// Every screen the app can be showing, as one value. The navigation redesign (T1-T9)
/// routes the whole window off this instead of the ad-hoc tab/sheet/push state the
/// pre-redesign screens each grew independently.
///
/// `.debug` is always a member of the type — only its *listing* in the sidebar is
/// gated `#if DEBUG` (`SidebarModel.rows`'s `includesDebug` flag). Keeping the case
/// itself unconditional means `PlaceRouting`'s switches stay exhaustive on every
/// build configuration; a `#if DEBUG` case would force `default:` in release builds,
/// which is exactly the silent-fallback hazard the no-`default` convention exists to
/// prevent.
enum Place: Hashable, Sendable {
    case capture
    case journal(String)      // journal id
    case allEntries
    case trash
    case debug
}

/// One sidebar row. Pure data — `SidebarView` (a later task) only lays it out.
struct PlaceRow: Identifiable, Equatable, Sendable {
    var place: Place
    var title: String
    var subtitle: String?          // a journal's derived date range, nil otherwise
    var systemImage: String?       // nil for journal rows (they draw a cover thumbnail)
    var journalID: String?         // non-nil ⇒ draw JournalCoverThumbnail
    var accessibilityIdentifier: String
    var id: Place { place }
}

enum SidebarModel {
    /// Row order and titles (locked): Capture, then one row per journal in DISPLAY
    /// order (`Array<Journal>.displayOrdered` — createdAt ascending, id tie-break), then
    /// All Entries, then Trash, then Debug when `includesDebug`. Superseded 2026-08-21
    /// (owner report, issue #79): this used to say "registry order", but registry order
    /// is per-device insertion history and differs between devices — the sidebar showed
    /// a different journal order on every device and surface as a result.
    ///
    /// `dateRanges` is journalID → formatted range (or absent). Caller supplies it from
    /// `LibraryScreenModel.dateRange(forJournal:)` so this stays pure.
    static func rows(journals: [Journal],
                     dateRanges: [String: String],
                     includesDebug: Bool) -> [PlaceRow] {
        var rows: [PlaceRow] = [
            PlaceRow(place: .capture,
                     title: "Capture",
                     subtitle: nil,
                     systemImage: "mic.circle",
                     journalID: nil,
                     accessibilityIdentifier: "sidebar.capture")
        ]

        for journal in journals.displayOrdered {
            rows.append(PlaceRow(place: .journal(journal.id),
                                 title: journal.name,
                                 subtitle: dateRanges[journal.id],
                                 systemImage: nil,
                                 journalID: journal.id,
                                 accessibilityIdentifier: "sidebar.journal.\(journal.id)"))
        }

        rows.append(PlaceRow(place: .allEntries,
                             title: "All Entries",
                             subtitle: nil,
                             systemImage: "books.vertical",
                             journalID: nil,
                             accessibilityIdentifier: "sidebar.allEntries"))
        rows.append(PlaceRow(place: .trash,
                             title: "Trash",
                             subtitle: nil,
                             systemImage: "trash",
                             journalID: nil,
                             accessibilityIdentifier: "sidebar.trash"))

        if includesDebug {
            rows.append(PlaceRow(place: .debug,
                                 title: "Debug",
                                 subtitle: nil,
                                 systemImage: "ladybug",
                                 journalID: nil,
                                 accessibilityIdentifier: "sidebar.debug"))
        }

        return rows
    }
}

/// The sidebar's Capture row visibility guarantee (design §5): whether a capture is
/// live from ANY other place, and how long it's been running. Pure — `SidebarView`/
/// `SidebarRowView` (nav T6) only render it; `NavigationUITests
/// .testARecordingSurvivesNavigatingAwayAndComingBack` pins the SwiftUI half this type
/// cannot express.
struct CaptureSidebarRow: Equatable, Sendable {
    var isLive: Bool
    var elapsedText: String?     // nil when not live

    /// `isLive` is true for exactly `.preparing, .recording, .interrupted, .resuming,
    /// .stopping` — the same set `CaptureLayoutModel.make` treats as `.capturing`
    /// (`CaptureLayoutModel.swift:116`). Exhaustive switch over `CaptureState`, no
    /// `default` — same rule as `CaptureLayoutModel.make` and `MarkerControlsModel.make`:
    /// a new phase must be classified here explicitly, not fall through silently.
    static func make(phase: CaptureState, elapsed: TimeInterval) -> CaptureSidebarRow {
        switch phase {
        case .preparing, .recording, .interrupted, .resuming, .stopping:
            return CaptureSidebarRow(isLive: true,
                                     elapsedText: CaptureCoordinator.formatDuration(elapsed))
        case .idle, .captured, .finalizing, .complete:
            return CaptureSidebarRow(isLive: false, elapsedText: nil)
        }
    }
}

enum PlaceRouting {
    static let launchPlace: Place = .capture

    /// Selecting any place — including the one you're already in — resets the detail
    /// path to root. Different place: obviously clears it. Same place: pops to root
    /// too, the universal sidebar idiom (Mail, Notes, Files) — re-clicking a row you're
    /// already on returns to that place's landing screen rather than being a dead click.
    /// Superseded 2026-08-17 (Gate B I1): the old rule ("re-selecting keeps the path")
    /// was written for iPhone, where the sidebar is reachable only at depth 0 so the
    /// path is always empty when a re-select can even happen. On Mac/iPad the Capture
    /// place can carry a pushed entry (its `capture.recentRow` link, or the post-stop
    /// receipt's Open link — both push onto this same path), and re-selecting Capture
    /// via its sidebar row or ⌘1 did nothing — a dead click on the exact gesture meant
    /// to return there.
    static func detailPath(afterSelecting new: Place,
                           from old: Place,
                           path: [LibraryDestination]) -> [LibraryDestination] {
        []
    }

    /// A `.journal(id)` for a journal that is not in the registry falls back to
    /// `.capture`. Every other place resolves to itself. No `default:` — a new `Place`
    /// case must be handled here explicitly, per the repo convention
    /// (`CaptureLayoutModel.make`, `MarkerControlsModel.make`).
    static func resolve(_ place: Place, journals: [Journal]) -> Place {
        switch place {
        case .journal(let id):
            return journals.contains { $0.id == id } ? place : .capture
        case .capture, .allEntries, .trash, .debug:
            return place
        }
    }

    /// The scope the entry list must run under. `nil` for places that are not entry
    /// lists. No `default:`, same reasoning as `resolve`.
    static func journalScope(for place: Place) -> JournalScope? {
        switch place {
        case .allEntries:
            return .all
        case .journal(let id):
            return .journal(id)
        case .capture, .trash, .debug:
            return nil
        }
    }
}

@MainActor @Observable
final class AppRouter {
    var place: Place = PlaceRouting.launchPlace
    /// Bound to the detail `NavigationStack` (`ContentView.swift`, nav T5) — nav T4 shipped
    /// this unbound, since a typed path had no slot for the `RootDestination` pushes still
    /// in use then; T5 retired `RootDestination`, so the stack is homogeneous and the bind
    /// is safe.
    var detailPath: [LibraryDestination] = []
    /// Consumed by T8's ⌘N and T8's root alert.
    var showingNewJournalPrompt = false
    /// A journal editor to push once its journal's place has actually become root
    /// (nav T9, sidebar `+`). NOT pushed inline with `select`: a `NavigationStack`
    /// whose ROOT content identity changes (via `ContentView.detailRoot`'s switch,
    /// following `place`) in the SAME synchronous update as a non-empty `path` discards
    /// the path — the stack resets to show just the new root. Confirmed empirically
    /// (os_log traces showed `detailPath` correctly holding `[.journalEditor]`
    /// immediately after `select` + `.append`, yet the rendered screen was the journal's
    /// plain library, never the editor) before this queue replaced the inline append.
    /// `ContentView`'s `.onChange(of: place)` consumes this once the new root has
    /// actually rendered, in a later, separate update pass.
    var pendingEditorPush: String?

    func select(_ place: Place) {
        detailPath = PlaceRouting.detailPath(afterSelecting: place, from: self.place, path: detailPath)
        self.place = place
    }

    /// Pops `detailPath` if non-empty; no-op otherwise.
    func goBack() {
        guard !detailPath.isEmpty else { return }
        detailPath.removeLast()
    }

    var canGoBack: Bool { !detailPath.isEmpty }

    /// ⌘N (nav T8): must work from any place, not just the capture screen, so the flag
    /// lives here rather than inside `JournalHeaderView`'s private `@State`. The root
    /// alert on `ContentView` observes `showingNewJournalPrompt` directly.
    func requestNewJournal() {
        showingNewJournalPrompt = true
    }
}
