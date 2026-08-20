import XCTest

/// Task 8 review carry-in (Task 7's own review flagged, but did not fix, that the span
/// section was mounted BELOW voice labels when the design doc's editor field order is
/// name -> cover -> span -> voice labels -> derived). There is no SwiftUI unit test for
/// `Form` child ordering in this repo, so — same shape as `JournalHeaderSourceTests` —
/// this is a source scan over `JournalEditorView.swift`, pinning the sequence of section
/// markers as they appear in the file.
final class JournalEditorSourceTests: XCTestCase {
    private var editorFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/Library/UI/JournalEditorView.swift")
    }

    private var editorSource: String {
        get throws { strippingComments(try String(contentsOf: editorFileURL)) }
    }

    func testFieldsAppearInDesignOrder() throws {
        let source = try editorSource
        let markers = [
            "Section(\"Name\")",
            "Section(\"Cover\")",
            "JournalSpanEditor(",
            "JournalVoiceLabelsSection(",
            "journalEditor.derived",
        ]
        var indices: [String.Index] = []
        for marker in markers {
            guard let range = source.range(of: marker) else {
                XCTFail("expected to find \(marker) in JournalEditorView.swift")
                return
            }
            indices.append(range.lowerBound)
        }
        for i in 1..<indices.count {
            XCTAssertLessThan(indices[i - 1], indices[i],
                              "the editor's field order must be name -> cover -> span -> "
                              + "voice labels -> derived (design doc); \(markers[i - 1]) "
                              + "must appear before \(markers[i])")
        }
    }

    /// Guards against silently regressing to the brief's illustrative sketch, whose
    /// `onPick`/`onRemove` shapes don't match `JournalCoverPickerSheet`'s real
    /// initializer (`onPick: (Data) async -> Bool`, `onRemove: () async -> Void`, both
    /// required, plus a required `journalName`).
    func testCoverSheetIsCalledWithItsRealInitializer() throws {
        let source = try editorSource
        XCTAssertTrue(source.contains("JournalCoverPickerSheet("))
        XCTAssertTrue(source.contains("journalName:"))
        XCTAssertTrue(source.contains("currentCover:"))
        XCTAssertTrue(source.contains("onPick:"))
        XCTAssertTrue(source.contains("onRemove:"))
    }

    /// #68 is a known, owner-accepted gap (macOS renders this sheet empty) — the code
    /// must keep saying so at the mount site rather than paper over it. Deliberately the
    /// RAW file, not the comment-stripped source: the reference lives IN the comment, so
    /// stripping comments (the usual anti-false-positive rule for this test family) would
    /// erase the very thing being checked for here.
    func testCoverSectionDocumentsTheKnownMacOSGap() throws {
        let raw = try String(contentsOf: editorFileURL)
        XCTAssertTrue(raw.contains("#68"))
    }
}
