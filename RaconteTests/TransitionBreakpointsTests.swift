import XCTest
@testable import Raconte

/// Covers the T11 debug harness (`TransitionBreakpointController`): arming a state
/// gates a caller at `gate(at:)`, disarming releases it. `abort()` fatalError()s by
/// design and is intentionally not exercised here.
@MainActor
final class TransitionBreakpointsTests: XCTestCase {
    override func tearDown() {
        TransitionBreakpointController.shared.disarmAll()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUnarmedStateNeverGates() async {
        let controller = TransitionBreakpointController.shared
        XCTAssertFalse(controller.isArmed(.recording))
        await controller.gate(at: .recording)
        XCTAssertFalse(controller.isWaiting(.recording), "ungated call never marks waiting")
    }

    func testArmingGatesACallerUntilDisarmed() async {
        let controller = TransitionBreakpointController.shared
        controller.arm(.recording)
        XCTAssertTrue(controller.isArmed(.recording))

        let released = LockedFlag()
        let task = Task { @MainActor in
            await controller.gate(at: .recording)
            released.set(true)
        }

        await waitUntil({ controller.isWaiting(.recording) },
                        "gate(at:) never marked .recording as waiting")
        // Still armed and not yet released: the caller stays parked.
        XCTAssertFalse(released.get(), "task must stay parked while armed")

        controller.disarm(.recording)

        await waitUntil({ released.get() }, "disarm never released the parked caller")
        XCTAssertFalse(controller.isWaiting(.recording), "disarm clears the waiting flag")
        XCTAssertFalse(controller.isArmed(.recording), "disarm clears the armed flag")

        await task.value
    }

    func testDisarmAllReleasesEveryParkedState() async {
        let controller = TransitionBreakpointController.shared
        controller.arm(.recording)
        controller.arm(.interrupted)

        let recordingReleased = LockedFlag()
        let interruptedReleased = LockedFlag()
        let t1 = Task { @MainActor in
            await controller.gate(at: .recording)
            recordingReleased.set(true)
        }
        let t2 = Task { @MainActor in
            await controller.gate(at: .interrupted)
            interruptedReleased.set(true)
        }

        await waitUntil({ controller.isWaiting(.recording) && controller.isWaiting(.interrupted) },
                        "both gates should be waiting before disarmAll")

        controller.disarmAll()

        await waitUntil({ recordingReleased.get() && interruptedReleased.get() },
                        "disarmAll must release every parked caller")
        XCTAssertTrue(controller.armedStates.isEmpty)
        XCTAssertTrue(controller.waitingStates.isEmpty)

        await t1.value
        await t2.value
    }

    func testMultipleCallersOnSameStateAllReleased() async {
        let controller = TransitionBreakpointController.shared
        controller.arm(.finalizing)

        let a = LockedFlag()
        let b = LockedFlag()
        let t1 = Task { @MainActor in await controller.gate(at: .finalizing); a.set(true) }
        let t2 = Task { @MainActor in await controller.gate(at: .finalizing); b.set(true) }

        await waitUntil({ controller.isWaiting(.finalizing) })
        // Give both tasks a beat to reach the gate before disarming.
        try? await Task.sleep(for: .milliseconds(20))

        controller.disarm(.finalizing)

        await waitUntil({ a.get() && b.get() },
                        "disarm must release every caller parked on the same state")

        await t1.value
        await t2.value
    }
}

/// Thread-safe boolean handshake between a test and a parked `Task`, matching the
/// NSLock-box convention already used by this suite's fakes (`LevelBox`, `FakeSession`).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = false) { self.value = value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
