import XCTest
@testable import Raconte

/// Mac menu bar commands (nav T8, design §7). Menu shortcuts themselves are neither
/// unit-testable (SwiftUI `Commands` bodies aren't introspectable) nor drivable by
/// XCUITest from the simulator-only `RaconteUI` scheme, which cannot reach a Mac menu
/// bar. So this file tests the pure half — the router functions every menu item calls,
/// and that the commands source never binds a global Esc — and the binding half (menu
/// items actually wired to those functions, ⌘1-4/⌘[/⌘N actually firing) is owner-smoked
/// at Gate B, not pretended here.
@MainActor
final class AppRouterCommandTests: XCTestCase {

    func testCommandTargetsAreTheRouterFunctions() {
        let router = AppRouter()
        router.select(.allEntries)
        router.detailPath = [.entry("A")]
        router.goBack()
        XCTAssertEqual(router.place, .allEntries)
        XCTAssertTrue(router.detailPath.isEmpty)

        router.select(.about)
        XCTAssertEqual(router.place, .about, "#89: the Go menu's About item routes here")
    }

    func testNewJournalRequestIsAFlagTheRootCanSee() {
        let router = AppRouter()
        XCTAssertFalse(router.showingNewJournalPrompt)
        router.requestNewJournal()
        XCTAssertTrue(router.showingNewJournalPrompt,
                      "⌘N must work from any place, so the flag lives on the router, not "
                      + "inside JournalHeaderView's private @State")
    }

    /// Source scan, comments stripped (repo memory: source-scanning-tests-must-strip-comments).
    func testNoGlobalEscapeBinding() throws {
        let source = strippingComments(try String(contentsOf: commandsFileURL))
        XCTAssertFalse(source.contains("cancelAction"),
                       "a menu command wins the responder chain, which would break "
                       + "TranscriptEditorView's Esc-closes contract")
        XCTAssertFalse(source.contains(".escape"))
    }

    private var commandsFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/App/RaconteCommands.swift")
    }
}
