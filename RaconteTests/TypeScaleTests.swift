import XCTest
import SwiftUI
@testable import Raconte

/// #162: the owner's type-size rulings (2026-09-08) as build-time facts. Sizes are stated in
/// points, per platform — never as text-style names, which differ in size across platforms.
final class TypeScaleTests: XCTestCase {

    /// iOS: smallest text up the most, largest not at all. 13/17/11 were the literals before.
    /// macOS: everything ×1.3.
    func testHomeSizesFollowTheRuling() {
        #if os(macOS)
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 17)
        XCTAssertEqual(TypeScale.homeSpineTitle, 22)
        XCTAssertEqual(TypeScale.homeRelativeTime, 14)
        #else
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 16, "+20% over 13")
        XCTAssertEqual(TypeScale.homeSpineTitle, 19, "+10% over 17")
        XCTAssertEqual(TypeScale.homeRelativeTime, 14, "+30% over 11")
        #endif
    }

    /// Spec batch 1: a role's macOS size is the iOS rendered size of its style — the same rule
    /// `CaptureSurface` already states for the capture screen. Stated literally in the enum, so
    /// this test is a pin, not a tautology: it compares two independently written tables.
    func testEveryRoleRendersAtTheiOSSizeOnMacOS() {
        for role in TypeRole.allCases {
            XCTAssertEqual(role.macOSPointSize, role.iOSStyle.pointSize(on: .iOS),
                           "\(role): macOS must render at the iOS size of \(role.iOSStyle)")
        }
    }

    /// The ~30% ask (#162): every role except `meta` is at least 1.2× Apple's macOS default
    /// for its style (caption is 10→12, the smallest step; body/headline are 13→17, 1.31×).
    /// `meta` is caption2, which Apple already sizes 10 vs 11 — +10% is all there is.
    func testEveryRoleIsAtLeastAFifthLargerThanAppleMacOSDefault() {
        for role in TypeRole.allCases where role != .meta {
            let apple = role.iOSStyle.pointSize(on: .macOS)
            XCTAssertGreaterThanOrEqual(role.macOSPointSize * 5, apple * 6,
                                        "\(role): \(role.macOSPointSize) vs Apple macOS \(apple)")
        }
        XCTAssertEqual(TypeRole.meta.macOSPointSize, 11)
    }

    /// Only `reading` is serif; everything else is the system face.
    func testOnlyReadingIsSerif() {
        XCTAssertEqual(TypeRole.allCases.filter(\.isSerif), [.reading])
    }

    /// `.system(size:)` is regular weight; `.headline` must say semibold explicitly or macOS
    /// silently disagrees with iOS's `Font.headline`.
    func testHeadlineKeepsItsWeightOnMacOS() {
        XCTAssertEqual(TypeRole.headline.macOSWeight, .semibold)
        for role in TypeRole.allCases where role != .headline {
            XCTAssertEqual(role.macOSWeight, .regular, "\(role)")
        }
    }

    /// Named literal constants: macOS never smaller than iOS, and the play glyph is the one
    /// deliberate exception that does not move at all (a glyph, not text).
    func testNamedSizesNeverShrinkOnMacOS() {
        for entry in TypeScale.namedSizes {
            XCTAssertGreaterThanOrEqual(entry.size, entry.iOSSize, entry.name)
        }
        XCTAssertEqual(TypeScale.detailPlayGlyph, 36)
        #if os(macOS)
        XCTAssertEqual(TypeScale.libraryRowMeta, 15)
        XCTAssertEqual(TypeScale.libraryCoverTitle, 28)
        XCTAssertEqual(TypeScale.homeNewEntryButton, 19)
        #else
        XCTAssertEqual(TypeScale.libraryRowMeta, 13)
        XCTAssertEqual(TypeScale.libraryCoverTitle, 26)
        XCTAssertEqual(TypeScale.homeNewEntryButton, 17)
        #endif
    }

    /// The paper screens are on `TypeRole`/`TypeScale`, never a bare Apple style or a size
    /// literal — a bare style is 10–13 pt on macOS, which is #162 coming back. Capture-surface
    /// files are deliberately absent from this list (spec ruling 4). `Raconte/Capture/Debug` is
    /// exempt (DEBUG-only tooling, spec inventory scope).
    private static let paperFiles = [
        "Raconte/Home/UI/HomeView.swift",
        "Raconte/App/SidebarView.swift",
        "Raconte/App/AboutView.swift",
        "Raconte/App/SyncStatusSectionView.swift",
        "Raconte/Library/UI/LibraryView.swift",
        "Raconte/Library/UI/TrashView.swift",
        "Raconte/Library/UI/EntryDetailView.swift",
        "Raconte/Library/UI/EntryInfoSheet.swift",
        "Raconte/Library/UI/TranscriptEditorView.swift",
        "Raconte/Library/UI/RevisionHistoryView.swift",
        "Raconte/Library/UI/JournalPickerSheet.swift",
        "Raconte/Library/UI/JournalSpanEditor.swift",
        "Raconte/Library/UI/JournalEditorView.swift",
        "Raconte/Library/UI/VoiceMarkingView.swift",
        "Raconte/Capture/UI/PlaybackProgressLine.swift",
        "Raconte/App/ExportConfirmationSheet.swift",
    ]

    func testPaperScreensCarryNoBareTextStyleOrSizeLiteral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let bare = [".font(.caption", ".font(.footnote", ".font(.subheadline",
                    ".font(.callout",
                    ".font(.body", ".font(.headline", ".font(.system(.",
                    ".font(.title", ".font(.largeTitle", ".font(.custom("]
        let literal = try NSRegularExpression(pattern: #"system\(size:\s*[0-9]"#)
        for path in Self.paperFiles {
            let url = root.appendingPathComponent(path)
            let source = strippingComments(try String(contentsOf: url))
            for pattern in bare {
                XCTAssertFalse(source.contains(pattern), "\(path) still has \(pattern)")
            }
            let hits = literal.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, "\(path) still has a system(size: <number>) literal")
        }
    }
}
