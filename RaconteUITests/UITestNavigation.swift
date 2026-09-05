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
    // Looped, not a single conditional tap (#103 fix round 1): a caller sitting two
    // pushes deep in the detail stack — e.g. a paging test popping from a pushed
    // `EntryDetailView` back to the sidebar — needs more than one reveal/back tap on
    // iPhone's collapsed split view to reach a sidebar row at all. Bounded at 5 so a
    // genuinely unreachable identifier still fails loudly via the assertion below
    // rather than looping forever. A caller already one hop away (the common case
    // every existing use of this helper was written against) still resolves on the
    // very first `waitForExistence` check, so this is a pure generalization —
    // zero behavior change for anyone already reachable in one tap.
    var attempts = 0
    while !row.waitForExistence(timeout: 3) && attempts < 5 {
        if app.buttons["Show Sidebar"].firstMatch.exists {
            app.buttons["Show Sidebar"].firstMatch.tap()
        } else if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        } else {
            break
        }
        attempts += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 15),
                  "could not reach \(identifier)", file: file, line: line)
    row.tap()
}

/// Back to the capture place from anywhere.
func openCapture(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    openPlace(app, "sidebar.capture", file: file, line: line)
}

/// The first sidebar row for a real journal (`sidebar.journal.<id>`) — for tests that
/// need to reach a journal whose id is minted fresh per run and so can't be named
/// exactly the way `openPlace` requires. Mirrors `openPlace`'s own reveal step
/// (Mac/iPad keep both columns visible and never need it; iPhone collapses the split
/// view, so a place already selected pops the sidebar off the visible stack — reveal
/// via the nav bar's back button before searching).
func firstJournalRow(_ app: XCUIApplication) -> XCUIElement {
    let row = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.journal.'"))
        .firstMatch
    if !row.waitForExistence(timeout: 3) {
        if app.buttons["Show Sidebar"].firstMatch.exists {
            app.buttons["Show Sidebar"].firstMatch.tap()
        } else if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
    return row
}

/// Wait for the post-stop receipt and open its entry.
///
/// #118 §3 deleted "Record another", so the receipt has two exits: the bar's record
/// button (which starts the next reading) and the entry card (which pushes the detail
/// screen and retires the receipt on the way). Tests want the second. The receipt
/// appearing is the completion signal — it is built only after the finalizer, the
/// transcript ref and the rescan have all run — so this also replaces the old
/// "recent row appeared" wait.
///
/// `app.descendants(matching: .any)`, not `app.buttons`: a `NavigationLink` is reported
/// as a button on iOS and as a generic element on macOS.
func openReceiptEntry(_ app: XCUIApplication, _ what: String = "recording",
                      file: StaticString = #filePath, line: UInt = #line) {
    let card = app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch
    guard card.waitForExistence(timeout: 30) else {
        XCTFail("\(what): the post-stop receipt never appeared", file: file, line: line)
        return
    }
    #if os(macOS)
    card.click()
    #else
    card.tap()
    #endif
    XCTAssertTrue(app.buttons["detail.moreButton"].firstMatch.waitForExistence(timeout: 15),
                  "\(what): opening the receipt did not reach the entry", file: file, line: line)
}

/// Finish a recording the way the old "Record another" did — back on Capture, Ready,
/// no receipt. Opens the entry (retiring the receipt) and returns via the sidebar.
func finishReceipt(_ app: XCUIApplication, _ what: String = "recording",
                   file: StaticString = #filePath, line: UInt = #line) {
    openReceiptEntry(app, what, file: file, line: line)
    openCapture(app, file: file, line: line)
    XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                  "\(what): did not get back to the capture screen", file: file, line: line)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.receipt.open")
                    .firstMatch.exists,
                   "\(what): the receipt survived opening its entry", file: file, line: line)
}
