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
        // Runs off the main actor; the point of the change. Compiles-and-passes IS the
        // assertion here, so it is paired with the mutation check (Step 5 in the task
        // brief: swap the body for a constant) rather than standing alone.
        let value = await Task.detached { await BuildStamp.currentBuildDisplayStringAsync() }.value
        XCTAssertEqual(value, BuildStamp.currentBuildDisplayString())
    }
}
#endif
