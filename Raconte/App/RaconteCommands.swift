import SwiftUI

#if os(macOS)
/// The Mac menu bar (nav T8, design §7). Three departures from a naive port are locked
/// in the plan's decisions:
///
/// - **No global Esc.** Esc belongs to whatever is focused —
///   `TranscriptEditorView` binds it to `.cancelAction` for its own dismiss contract,
///   and a menu command would win that fight unconditionally (a menu shortcut beats the
///   responder chain). ⌘[ is the only Back binding.
/// - **Fixed-place digits only.** ⌘1-4 select `.capture`/`.allEntries`/`.trash`/`.debug`
///   — no per-journal digit shortcuts.
/// - **⌘N presents a root-level alert**, not `JournalHeaderView`'s own — that one is
///   reachable only from the capture screen's menu, which a Mac menu command must not
///   require.
///
/// `#if DEBUG` around the ⌘4 Debug item matches the `#if DEBUG` around the sidebar's
/// Debug row (`SidebarModel.rows`'s `includesDebug`) — a shortcut that selects a place
/// with no sidebar row in Release would be a way to reach a screen that does not exist
/// there.
///
/// Menu shortcuts are not unit-testable and XCUITest cannot reliably drive a Mac menu
/// bar from the simulator-only `RaconteUI` scheme. `AppRouterCommandTests` pins the pure
/// half (the router functions these buttons call, and that this file's source never
/// binds a global Esc); the binding half — these buttons actually wired to those
/// functions, and the shortcuts actually firing — is owner-smoked at Gate B.
struct RaconteCommands: Commands {
    let services: AppServices

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Journal…") { services.router.requestNewJournal() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Capture")     { services.router.select(.capture) }.keyboardShortcut("1")
            Button("All Entries") { services.router.select(.allEntries) }.keyboardShortcut("2")
            Button("Trash")       { services.router.select(.trash) }.keyboardShortcut("3")
            #if DEBUG
            Button("Debug")       { services.router.select(.debug) }.keyboardShortcut("4")
            #endif
            Divider()
            Button("Back") { services.router.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!services.router.canGoBack)
        }
    }
}
#endif
