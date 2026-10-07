import Foundation

/// The undo window behind swipe-to-trash (#83). The trash write has ALREADY landed when a
/// capture id is armed here — this is a restore window, not a deferred delete — so a crash
/// mid-window leaves the entry in Trash, recoverable, never silently lost. Pure: the model
/// owns the clock and the timer, so the window pins with an injected `now`.
struct TrashLinger: Equatable {
    let window: TimeInterval
    private var armedAt: [String: Date] = [:]

    init(window: TimeInterval = 2) {
        self.window = window
    }

    var isEmpty: Bool { armedAt.isEmpty }

    func isLingering(_ captureID: String) -> Bool { armedAt[captureID] != nil }

    /// False when already lingering: a second swipe neither re-arms nor restarts the clock.
    mutating func arm(_ captureID: String, now: Date) -> Bool {
        guard armedAt[captureID] == nil else { return false }
        armedAt[captureID] = now
        return true
    }

    /// False when nothing was lingering — the window closed, or it never opened.
    mutating func undo(_ captureID: String) -> Bool {
        armedAt.removeValue(forKey: captureID) != nil
    }

    /// Every id whose window has passed (inclusive at exactly `window`), removed.
    mutating func expire(now: Date) -> [String] {
        let done = armedAt.filter { now.timeIntervalSince($0.value) >= window }.map(\.key).sorted()
        for id in done { armedAt[id] = nil }
        return done
    }
}
