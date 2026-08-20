#if DEBUG
import XCTest
@testable import Raconte

/// Pins `BuildStamp.currentBuildDisplayStringAsync()` (nav T7): the Debug place's
/// `.task` moved this call off the main actor on principle (bundle enumeration + a
/// dyld image walk are file I/O), not because it caused the 2026-08-17 freeze (that
/// was a modal sheet blocking ⌘Q — see design §6). The async entry point must agree
/// with the synchronous one and must actually be callable off the main actor.
final class BuildStampAsyncTests: XCTestCase {
    func testAsyncStringMatchesTheSynchronousOne() async {
        let sync = BuildStamp.currentBuildDisplayString()
        let async = await BuildStamp.currentBuildDisplayStringAsync()
        XCTAssertEqual(sync, async)
    }

    func testAsyncCallDoesNotRequireTheMainActor() async {
        // Runs off the main actor; the point of the change. A `Task.detached` wrapper
        // at the CALL SITE alone (as this test originally read) only proves the caller
        // can await off-main — that is equally true of a `@MainActor`-annotated
        // function called with `await`, so it cannot detect that regression, and its
        // only actual failing mode (content mismatch) duplicates
        // `testAsyncStringMatchesTheSynchronousOne`. `lastAsyncEntryWasOnMainThread`
        // is the real pin: see its doc comment in BuildStamp.swift for why a future
        // accidental `@MainActor` flips it to `true` from this same off-main caller.
        BuildStamp.lastAsyncEntryWasOnMainThread = nil
        let value = await Task.detached { await BuildStamp.currentBuildDisplayStringAsync() }.value
        XCTAssertEqual(value, BuildStamp.currentBuildDisplayString())
        XCTAssertEqual(BuildStamp.lastAsyncEntryWasOnMainThread, false,
                       "currentBuildDisplayStringAsync entered on the main thread from an "
                       + "off-main caller — it has become main-actor-isolated")
    }
}
#endif
