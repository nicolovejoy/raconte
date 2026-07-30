#if DEBUG
import Foundation

/// DEBUG-only harness for design §6 test 9 ("kill at each transition"): arm any
/// `CaptureState` to halt the next caller that reaches it, then force-kill the
/// process exactly there via `abort()`.
///
/// This file is intentionally self-contained and NOT wired into the app —
/// `CaptureCoordinator` does not call `gate(at:)` yet. One line makes it live:
///
///     #if DEBUG
///     await TransitionBreakpointController.shared.gate(at: next.phase)
///     #endif
///
/// inserted in `CaptureCoordinator.send(_:)` right after `phase = next.phase` is
/// set (before `await realize(...)`), so every transition passes through the gate
/// keyed by the state it just entered.
@MainActor
@Observable
final class TransitionBreakpointController {
    static let shared = TransitionBreakpointController()

    /// States that will halt the next caller reaching `gate(at:)` for them.
    private(set) var armedStates: Set<CaptureState> = []
    /// States a caller is currently parked at (drives the debug menu's "waiting" row).
    private(set) var waitingStates: Set<CaptureState> = []

    private var waiters: [CaptureState: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    /// Arm a state: the next (or already-in-flight) `gate(at: state)` call blocks
    /// until `disarm(state)` or `abort()`.
    func arm(_ state: CaptureState) {
        armedStates.insert(state)
    }

    /// Disarm a state, releasing any caller currently parked in its gate.
    func disarm(_ state: CaptureState) {
        armedStates.remove(state)
        release(state)
    }

    func disarmAll() {
        for state in armedStates { release(state) }
        armedStates.removeAll()
    }

    func isArmed(_ state: CaptureState) -> Bool {
        armedStates.contains(state)
    }

    func isWaiting(_ state: CaptureState) -> Bool {
        waitingStates.contains(state)
    }

    /// Call at the point a transition reaches `state`. A no-op unless `state` is
    /// armed; when armed, suspends the caller (marking it "waiting" for the debug
    /// menu) until disarmed.
    func gate(at state: CaptureState) async {
        guard armedStates.contains(state) else { return }
        waitingStates.insert(state)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[state, default: []].append(continuation)
        }
    }

    /// Simulate a force-kill exactly at whatever state(s) a caller is currently
    /// gated at (or unconditionally, if nothing is waiting). Never returns.
    func abort() -> Never {
        let where_ = waitingStates.isEmpty
            ? "no gate currently waiting"
            : waitingStates.map(\.rawValue).sorted().joined(separator: ", ")
        fatalError("TransitionBreakpointController: simulated force-kill at [\(where_)]")
    }

    private func release(_ state: CaptureState) {
        waitingStates.remove(state)
        let parked = waiters.removeValue(forKey: state) ?? []
        for continuation in parked { continuation.resume() }
    }
}
#endif
