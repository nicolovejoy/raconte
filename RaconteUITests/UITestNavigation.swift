import XCTest

/// Reveal the sidebar and select a place.
///
/// On macOS/iPad both columns are visible and the row is a straight tap. On iPhone the
/// split view is COLLAPSED to a stack whose root is the places list, so the sidebar is
/// reached by the navigation bar's back button — which is also exactly what the owner
/// does. `sidebar.toggle` covers the regular-width case where the column is hidden.
func openPlace(_ app: XCUIApplication,
               _ identifier: String,
               file: StaticString = #filePath,
               line: UInt = #line) {
    let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    if !row.waitForExistence(timeout: 3) {
        if app.buttons["sidebar.toggle"].firstMatch.exists {
            app.buttons["sidebar.toggle"].firstMatch.tap()
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
