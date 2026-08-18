import XCTest

/// Reveal the sidebar and select a place.
///
/// On macOS/iPad both columns are visible and the row is a straight tap. On iPhone the
/// split view is COLLAPSED to a stack whose root is the places list, so the sidebar is
/// reached by the navigation bar's back button — which is also exactly what the owner
/// does.
///
/// Gate B M1 (2026-08-17): the regular-width (iPad, portrait-collapsed-sidebar) case
/// used to query `sidebar.toggle`, an identifier NO production view applies — SwiftUI
/// draws `NavigationSplitView`'s own reveal button and it cannot carry one. That query
/// always failed silently and fell straight through to `navigationBars.buttons
/// .firstMatch`, which at depth>0 on iPad is the DETAIL screen's back button, not the
/// sidebar reveal — so this helper silently popped instead of revealing. Gate B
/// verified live that the system button IS reachable, by its label:
/// `app.buttons["Show Sidebar"]`. The `navigationBars.buttons.firstMatch` fallback is
/// kept, not deleted — it is still correct and still needed for iPhone, where the
/// split view is collapsed to a stack (no "Show Sidebar" button exists at all) and the
/// nav bar's back button is genuinely how the sidebar is reached.
func openPlace(_ app: XCUIApplication,
               _ identifier: String,
               file: StaticString = #filePath,
               line: UInt = #line) {
    let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    if !row.waitForExistence(timeout: 3) {
        if app.buttons["Show Sidebar"].firstMatch.exists {
            app.buttons["Show Sidebar"].firstMatch.tap()
        } else if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
    XCTAssertTrue(row.waitForExistence(timeout: 15),
                  "could not reach \(identifier)", file: file, line: line)
    row.tap()
}

/// Back to the capture place from anywhere.
func openCapture(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    openPlace(app, "sidebar.capture", file: file, line: line)
}
