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
    /// Row order and titles (locked): Capture, then one row per journal in registry
    /// order, then All Entries, then Trash, then Debug when `includesDebug`.
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

        for journal in journals {
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

enum PlaceRouting {
    static let launchPlace: Place = .capture

    /// Selecting a DIFFERENT place clears the detail path; re-selecting the same place
    /// keeps it — tapping the place you're already in must not throw away where you are.
    static func detailPath(afterSelecting new: Place,
                           from old: Place,
                           path: [LibraryDestination]) -> [LibraryDestination] {
        new == old ? path : []
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
    var detailPath: [LibraryDestination] = []
    /// Consumed by T8's ⌘N and T8's root alert.
    var showingNewJournalPrompt = false

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
}
