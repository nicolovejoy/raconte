import Foundation

/// The Home landing's shelf split (#108 design): which journals show face-out covers
/// and which show as spines, ranked by capture activity. Pure — the view supplies
/// `LibraryScreenModel.journals` / `.allEntries` and renders the result.
struct HomeShelf: Equatable, Sendable {
    var faceOut: [Journal]
    var spines: [Journal]
    /// Journal id → newest `capturedAt` among its entries. Absent = no entries.
    var lastActivity: [String: Date]

    /// Ranking is by `capturedAt`, never `effectiveDate` — a backdate must not
    /// reorder the shelf (spec). Empty journals rank last; every tie falls back to
    /// the sidebar's display order so the two surfaces never disagree arbitrarily.
    static func make(journals: [Journal],
                     entries: [EntryListItem],
                     faceOutLimit: Int) -> HomeShelf {
        var lastActivity: [String: Date] = [:]
        let known = Set(journals.map(\.id))
        for entry in entries {
            guard let id = entry.journalID, known.contains(id) else { continue }
            if let existing = lastActivity[id] {
                if entry.capturedAt > existing { lastActivity[id] = entry.capturedAt }
            } else {
                lastActivity[id] = entry.capturedAt
            }
        }
        let display = journals.displayOrdered
        let displayIndex = Dictionary(uniqueKeysWithValues:
            display.enumerated().map { ($0.element.id, $0.offset) })
        let ranked = display.sorted { a, b in
            switch (lastActivity[a.id], lastActivity[b.id]) {
            case let (da?, db?):
                if da != db { return da > db }
                return displayIndex[a.id]! < displayIndex[b.id]!
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return displayIndex[a.id]! < displayIndex[b.id]!
            }
        }
        return HomeShelf(faceOut: Array(ranked.prefix(faceOutLimit)),
                         spines: Array(ranked.dropFirst(faceOutLimit)),
                         lastActivity: lastActivity)
    }
}
