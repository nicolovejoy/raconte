import XCTest
import AVFoundation
@testable import Raconte

/// M2 T1: fan-out semantics of the tap sink (design §2).
final class TeeSinkTests: XCTestCase {

    /// Records entry order across all branches so "disk branch first" is testable
    /// as an actual ordering claim, not a comment.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(branch: String, chunk: Int)] = []
        func note(_ branch: String, _ chunk: Int) {
            lock.lock(); entries.append((branch, chunk)); lock.unlock()
        }
        var all: [(branch: String, chunk: Int)] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }

    private final class RecordingSink: PCMSink, @unchecked Sendable {
        let name: String
        let log: OrderLog
        /// Work done inside `receive`, e.g. a sleep or a throw-and-absorb.
        let body: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var seen: [PCMChunk] = []

        init(name: String, log: OrderLog, body: (@Sendable () -> Void)? = nil) {
            self.name = name; self.log = log; self.body = body
        }

        nonisolated func receive(_ chunk: PCMChunk) {
            lock.lock(); let index = seen.count; seen.append(chunk); lock.unlock()
            log.note(name, index)
            body?()
        }

        var received: [PCMChunk] {
            lock.lock(); defer { lock.unlock() }; return seen
        }
    }

    private func chunk(_ byte: UInt8, frames: AVAudioFrameCount = 512) -> PCMChunk {
        PCMChunk(data: Data(repeating: byte, count: Int(frames) * 4),
                 frameCount: frames, sampleRate: 48000)
    }

    func testEveryBranchSeesEveryChunk() {
        let log = OrderLog()
        let a = RecordingSink(name: "disk", log: log)
        let b = RecordingSink(name: "second", log: log)
        let tee = TeeSink(branches: [a, b])

        for i in 0..<10 { tee.receive(chunk(UInt8(i))) }

        XCTAssertEqual(a.received.count, 10)
        XCTAssertEqual(b.received.count, 10)
        XCTAssertEqual(a.received, b.received)
    }

    /// The honest form of "a slow branch can't stall the disk branch": the tee is
    /// synchronous, so the guarantee is ordering — the disk branch is entered for
    /// chunk N before the slow branch is.
    func testDiskBranchIsEnteredFirstForEveryChunk() {
        let log = OrderLog()
        let disk = RecordingSink(name: "disk", log: log)
        let slow = RecordingSink(name: "slow", log: log, body: { Thread.sleep(forTimeInterval: 0.005) })
        let tee = TeeSink(branches: [disk, slow])

        for i in 0..<5 { tee.receive(chunk(UInt8(i))) }

        // Strict alternation: disk 0, slow 0, disk 1, slow 1, ...
        let expected = (0..<5).flatMap { [("disk", $0), ("slow", $0)] }
        XCTAssertEqual(log.all.map(\.branch), expected.map(\.0))
        XCTAssertEqual(log.all.map(\.chunk), expected.map(\.1))
    }

    /// `PCMSink.receive` is non-throwing, so a "failing" branch is one that
    /// absorbs its own error. It must be invisible to the others.
    func testInternallyFailingBranchIsInvisibleToTheOthers() {
        let log = OrderLog()
        let disk = RecordingSink(name: "disk", log: log)
        let failing = RecordingSink(name: "failing", log: log, body: {
            do { throw CocoaError(.fileNoSuchFile) } catch { /* absorbed */ }
        })
        let tee = TeeSink(branches: [disk, failing])

        for i in 0..<4 { tee.receive(chunk(UInt8(i))) }

        XCTAssertEqual(disk.received.count, 4)
        XCTAssertEqual(failing.received.count, 4)
    }

    func testZeroAndOneBranchTees() {
        let log = OrderLog()
        TeeSink(branches: []).receive(chunk(1))   // must not trap

        let only = RecordingSink(name: "only", log: log)
        let tee = TeeSink(branches: [only])
        tee.receive(chunk(7))
        XCTAssertEqual(only.received.count, 1)
        XCTAssertEqual(only.received.first?.frameCount, 512)
    }

    func testChunksArePassedThroughUnchanged() {
        let log = OrderLog()
        let sink = RecordingSink(name: "only", log: log)
        let original = chunk(0xAB, frames: 128)
        TeeSink(branches: [sink]).receive(original)
        XCTAssertEqual(sink.received.first, original)
    }
}
