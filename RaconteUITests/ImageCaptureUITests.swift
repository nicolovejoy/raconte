import XCTest

/// Image capture plan Task 7, end to end on a simulator: blank-entry creation, the
/// real image-capture picker sheet presenting, and the library row's leading
/// thumbnail appearing/disappearing as an image is added and removed.
///
/// No existing `LibraryUITests`/`EntryDetailUITests` class exists in this suite
/// (checked before adding this file — `JournalEditorUITests`, `NavigationUITests`,
/// `CaptureUITests`/`CaptureControlsUITests`, `TranscriptEditorUITests`,
/// `VoiceMarkingUITests` are the only classes, none of them library/entry-detail
/// homed), so this is a new file rather than an addition to one of those.
///
/// The thumbnail-appears/removal-round-trip cases use `UITestImageSeed`
/// (`RACONTE_UITEST_SEED_IMAGE_ENTRY`) rather than actually driving the real
/// `PhotosPicker` to add an image — XCUITest cannot pick a real photo from a
/// simulator's (empty) Photos library, the same limitation
/// `JournalEditorUITests.testAddingACoverOpensTheRealPickerSheet` documents for the
/// journal cover picker. `testCapturingAnImageOpensTheRealPickerSheet` below follows
/// that exact precedent instead: it proves the real `ImageCapturePickerSheet`
/// presents and is dismissible, without trying to complete a pick.
final class ImageCaptureUITests: XCTestCase {

    private var testID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp(seedImageEntry: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        if seedImageEntry {
            app.launchEnvironment["RACONTE_UITEST_SEED_IMAGE_ENTRY"] = "1"
        }
        app.launch()
        return app
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    // MARK: - Blank-entry creation

    /// "+ New entry" (design doc decision 4): mints a blank entry and routes straight
    /// to its (mostly empty) detail screen — no picker-first flow.
    func testNewEntryCreatesABlankEntryAndLandsOnItsDetailScreen() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        openPlace(app, "sidebar.allEntries")

        let newEntry = app.buttons["library.newEntry"].firstMatch
        XCTAssertTrue(newEntry.waitForExistence(timeout: 15),
                      "the library screen must offer a + New entry toolbar action")
        press(newEntry)

        let imagesEmpty = app.descendants(matching: .any)
            .matching(identifier: "entryDetail.images.empty").firstMatch
        XCTAssertTrue(imagesEmpty.waitForExistence(timeout: 15),
                      "+ New entry did not land on a fresh, image-less entry detail screen")
    }

    // MARK: - Image add (picker precedent)

    /// Mirrors `JournalEditorUITests.testAddingACoverOpensTheRealPickerSheet` exactly:
    /// proves the real `ImageCapturePickerSheet` presents from the detail screen's
    /// "Capture Image…" button and is dismissible, without driving an actual pick.
    func testCapturingAnImageOpensTheRealPickerSheet() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        openPlace(app, "sidebar.allEntries")
        let newEntry = app.buttons["library.newEntry"].firstMatch
        XCTAssertTrue(newEntry.waitForExistence(timeout: 15))
        press(newEntry)

        let captureButton = app.buttons["entryDetail.images.captureButton"].firstMatch
        XCTAssertTrue(captureButton.waitForExistence(timeout: 15),
                      "the entry detail screen must offer a Capture Image… affordance")
        press(captureButton)

        let choosePhoto = app.buttons["imageCapture.choosePhoto"].firstMatch
        XCTAssertTrue(choosePhoto.waitForExistence(timeout: 15),
                      "tapping Capture Image… did not present the real image picker sheet")

        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        press(cancel)

        XCTAssertTrue(app.buttons["entryDetail.images.captureButton"].firstMatch.waitForExistence(timeout: 15),
                      "Cancel should dismiss the sheet back to the still-open detail screen")
    }

    // MARK: - Library row thumbnail + remove round-trip

    /// `UITestImageSeed` fixture: a finalized blank entry with one real image already
    /// attached. Confirms the library row's merged accessibility label carries "Entry
    /// photo" (the thumbnail's own `accessibilityLabel` — `library.row.thumbnail` is
    /// NOT independently queryable, matching this row's own doc comment about
    /// `NavigationLink` flattening; `CaptureUITests.durationSeconds(in:)` is this
    /// project's precedent for reading a row's content off its merged label instead),
    /// then removes the image from the full-screen viewer and confirms the label no
    /// longer carries it — the round-trip the brief asks for, without a real
    /// `PhotosPicker` add.
    func testImageThumbnailAppearsOnLibraryRowAndDisappearsAfterRemoval() {
        let app = launchApp(seedImageEntry: true)
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        openPlace(app, "sidebar.allEntries")

        let entryLink = app.descendants(matching: .any)
            .matching(identifier: "library.entryLink").firstMatch
        XCTAssertTrue(entryLink.waitForExistence(timeout: 20))
        waitUntil(20, "the seeded entry's image never produced a library row thumbnail "
                  + "(row label: \(entryLink.label))") {
            entryLink.label.contains("Entry photo")
        }
        press(entryLink)

        let stripThumbnail = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'entryDetail.images.thumbnail.'"))
            .firstMatch
        XCTAssertTrue(stripThumbnail.waitForExistence(timeout: 15),
                      "the entry detail screen never showed the seeded image in its strip")
        press(stripThumbnail)

        let remove = app.buttons["entryDetail.images.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15),
                      "the full-screen viewer must offer a Remove action")
        press(remove)

        // The confirmation dialog's own action button has no accessibility identifier
        // and the SAME "Remove" label as the toolbar button that opened it — both are
        // on screen at once, so `app.buttons["Remove"]` can match either. Excluding the
        // toolbar button's identifier leaves only the dialog's action.
        let confirmRemove = app.buttons.matching(NSPredicate(
            format: "label == 'Remove' AND identifier != 'entryDetail.images.remove'")).firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 15),
                      "removing an image must confirm before deleting")
        press(confirmRemove)

        let imagesEmpty = app.descendants(matching: .any)
            .matching(identifier: "entryDetail.images.empty").firstMatch
        XCTAssertTrue(imagesEmpty.waitForExistence(timeout: 15),
                      "the entry detail screen did not return to the empty images state after removal")

        // Pop the detail screen back to the library first: `openPlace`'s reveal step
        // only pops ONE level (detail root → sidebar), and the entry detail screen sits
        // a level BELOW the library, not at the detail root itself.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back from the entry detail screen")
        press(back)

        openPlace(app, "sidebar.allEntries")
        let entryLinkAfterRemoval = app.descendants(matching: .any)
            .matching(identifier: "library.entryLink").firstMatch
        waitUntil(20, "the library row's thumbnail did not disappear after the image was removed") {
            entryLinkAfterRemoval.exists && !entryLinkAfterRemoval.label.contains("Entry photo")
        }
    }
}
