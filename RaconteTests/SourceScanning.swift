import Foundation

/// Strips `//` line comments from source text before a source-scanning test matches
/// against it. Shared by every such test in this suite (repo memory:
/// source-scanning-tests-must-strip-comments) — without it, a scan is satisfied by prose
/// *about* the pattern rather than the pattern itself. `CaptureLabelTests` and
/// `PrecisionDatePickerTests` each carried their own copy of exactly this logic before
/// this file existed; both now call through here instead of a third (or fourth) copy.
///
/// Line comments only; assumes no `//` inside a string literal in the scanned files —
/// true for every source this suite scans as of this writing.
func strippingComments(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let slashes = line.range(of: "//") else { return line }
            return line[line.startIndex..<slashes.lowerBound]
        }
        .joined(separator: "\n")
}

/// The paper (reading-surface) screens every design-system source scan runs over: type roles
/// (`TypeScaleTests`, #162) and ink roles (`InkSurfaceTests`, #149). Capture-surface files are
/// deliberately absent (spec ruling 4); `Raconte/Capture/Debug` is exempt (DEBUG-only tooling).
/// `PlaybackProgressLine` lives under Capture/UI but renders on paper in entry detail.
/// `VoiceAttributedText` builds `Text` for the transcript and carries colour but no font.
let paperScreenFiles = [
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
    "Raconte/Library/UI/VoiceAttributedText.swift",
    "Raconte/Capture/UI/PlaybackProgressLine.swift",
]

/// Repo root, derived from this file's location (RaconteTests/ → repo).
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}
