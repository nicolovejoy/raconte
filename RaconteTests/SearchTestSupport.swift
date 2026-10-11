import XCTest
@testable import Raconte

/// Counts reconcile calls and blocks until released, to prove coalescing.
actor FakeReconciler: SearchReconciling {
    var calls: [[SearchIndexer.Entry]] = []
    /// The base priority of the task each call arrived on (not its escalated priority).
    private(set) var basePriorities: [TaskPriority?] = []
    /// What a call returns when it is released. The default is a pass that changed nothing.
    private var report = SearchIndexer.Report()
    private var gate: CheckedContinuation<Void, Never>?
    func reconcile(_ entries: [SearchIndexer.Entry]) async -> SearchIndexer.Report {
        calls.append(entries)
        basePriorities.append(Task.basePriority)
        await withCheckedContinuation { gate = $0 }
        return report
    }
    /// Sets the report for the parked call and every later one, until set again.
    func willReport(_ report: SearchIndexer.Report) { self.report = report }
    /// True when a parked call was released. False means nothing was parked.
    @discardableResult func release() -> Bool {
        guard let g = gate else { return false }
        gate = nil; g.resume(); return true
    }
    /// Returns once `n` calls have parked (or after ~2 s, so a broken build fails an
    /// assertion instead of hanging the suite).
    func waitForParkedCall(_ n: Int) async {
        for _ in 0..<400 where !(calls.count >= n && gate != nil) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Bounded wait for the model to go idle (~2 s), same reason.
@MainActor func waitUntilIdle(_ model: LibraryScreenModel) async {
    for _ in 0..<400 where model.searchIndexing { try? await Task.sleep(for: .milliseconds(5)) }
}

/// Parks each search until it is released with the hits to return, or failed.
actor FakeSearching: SearchQuerying {
    struct Failure: Error {}

    /// Every query received, in order.
    private(set) var queries: [SearchQuery] = []
    var calls: Int { queries.count }
    /// Parked calls, oldest first.
    private var gates: [CheckedContinuation<[SearchHit], any Error>] = []

    func search(_ query: SearchQuery) async throws -> [SearchHit] {
        queries.append(query)
        return try await withCheckedThrowingContinuation { gates.append($0) }
    }
    /// Answers the oldest parked call. False means nothing was parked.
    @discardableResult func release(_ hits: [SearchHit]) -> Bool {
        guard !gates.isEmpty else { return false }
        gates.removeFirst().resume(returning: hits); return true
    }
    /// Makes the oldest parked call throw. False means nothing was parked.
    @discardableResult func fail() -> Bool {
        guard !gates.isEmpty else { return false }
        gates.removeFirst().resume(throwing: Failure()); return true
    }
    /// Returns once `n` calls have arrived and one is parked (or after ~2 s, so a broken
    /// build fails an assertion instead of hanging the suite).
    func waitForParkedCall(_ n: Int) async {
        for _ in 0..<400 where !(calls >= n && !gates.isEmpty) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Bounded wait (~2 s) for the search screen to publish exactly `count` results.
@MainActor func waitForResults(_ model: SearchScreenModel, count: Int) async {
    for _ in 0..<400 where model.results.count != count { try? await Task.sleep(for: .milliseconds(5)) }
}
