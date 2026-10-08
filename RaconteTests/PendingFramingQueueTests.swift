import XCTest
import UniformTypeIdentifiers
@testable import Raconte

/// #121: the queue behind the two picker sheets' framing step, and the one rule that decides
/// what reaches `onPick`. Pure, so a multi-select of three with a cancel in the middle pins
/// without a `PhotosPicker`.
final class PendingFramingQueueTests: XCTestCase {

    private func item(_ tag: UInt8, type: UTType = .png, origin: PendingFramingItem.Origin = .library) -> PendingFramingItem {
        PendingFramingItem(id: UUID(), data: ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (tag, 0, 0)),
                           type: type, origin: origin)
    }

    func testHeadIsFIFOAndPopAdvances() {
        var queue = PendingFramingQueue()
        let a = item(1), b = item(2), c = item(3)
        queue.enqueue(contentsOf: [a, b, c])
        XCTAssertEqual(queue.head, a)
        XCTAssertEqual(queue.popHead(), a)
        XCTAssertEqual(queue.head, b)
        XCTAssertEqual(queue.popHead(), b)
        XCTAssertEqual(queue.popHead(), c)
        XCTAssertNil(queue.popHead())
        XCTAssertTrue(queue.isEmpty)
    }

    /// Review Focus 5: cancelling the framing on the second item does not lose the third.
    func testQueueAdvancesPastACancelledItem() {
        var queue = PendingFramingQueue()
        let a = item(1), b = item(2), c = item(3)
        queue.enqueue(contentsOf: [a, b, c])
        _ = queue.popHead()                       // a used
        let cancelled = queue.popHead()           // b cancelled — the sheet still calls onPick(b, unframed)
        XCTAssertEqual(cancelled, b)
        XCTAssertEqual(queue.head, c, "the item after a cancelled one is still framed")
    }

    /// Review Focus 2: an uncropped PNG pick stays a PNG, byte for byte.
    func testIdentityFramingHandsTheOriginalBytesAndTypeToOnPick() {
        let png = item(9, type: .png)
        let (data, type) = PendingFramingQueue.resolve(png, framing: .identity)
        XCTAssertEqual(data, png.data)
        XCTAssertEqual(type, .png)
    }

    func testNonIdentityFramingHandsAJPEG() throws {
        let png = item(9, type: .png)
        let (data, type) = PendingFramingQueue.resolve(
            png, framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit))
        XCTAssertEqual(type, .jpeg)
        XCTAssertEqual(ImageThumbnailerTests.imageType(of: data), UTType.jpeg.identifier)
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: data))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    /// A framing that cannot be applied (bytes that are not an image) must not drop the item:
    /// the original goes through as it was.
    func testFailedApplyFallsBackToTheOriginal() {
        let junk = PendingFramingItem(id: UUID(), data: Data("not an image".utf8), type: .jpeg, origin: .camera)
        let (data, type) = PendingFramingQueue.resolve(
            junk, framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit))
        XCTAssertEqual(data, junk.data)
        XCTAssertEqual(type, .jpeg)
    }

    /// A queued camera shot keeps the library batch open: [L, L, C] is not over after both L's.
    func testBatchIsNotOverWhileACameraShotIsQueued() throws {
        var queue = PendingFramingQueue()
        queue.enqueue(contentsOf: [item(1), item(2)])
        queue.enqueue(item(3, origin: .camera))
        let l1 = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(l1, landed: true)
        let l2 = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(l2, landed: true)
        XCTAssertFalse(queue.libraryBatchIsOver, "the camera shot is still queued")
        let c = try XCTUnwrap(queue.beginResolving())
        XCTAssertFalse(queue.libraryBatchIsOver, "and then still in flight")
        queue.finishResolving(c, landed: true)
        XCTAssertTrue(queue.libraryBatchIsOver)
    }

    /// Out-of-order completion: the batch is over only when the LAST in-flight add returns.
    func testBatchIsNotOverUntilEveryInFlightItemFinishes() throws {
        var queue = PendingFramingQueue()
        queue.enqueue(contentsOf: [item(1), item(2)])
        let l1 = try XCTUnwrap(queue.beginResolving())
        let l2 = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(l2, landed: true)
        XCTAssertFalse(queue.libraryBatchIsOver, "L1 is still in flight")
        queue.finishResolving(l1, landed: true)
        XCTAssertTrue(queue.libraryBatchIsOver)
    }

    func testFailedLibraryItemReportsOnceThenResets() throws {
        var queue = PendingFramingQueue()
        queue.enqueue(contentsOf: [item(1), item(2)])
        let l1 = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(l1, landed: false)
        let l2 = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(l2, landed: true)
        XCTAssertTrue(queue.libraryBatchIsOver)
        XCTAssertTrue(queue.closeLibraryBatch())
        XCTAssertFalse(queue.closeLibraryBatch())
        XCTAssertFalse(queue.libraryBatchIsOver, "closed")
    }

    /// A camera-only queue never opens a library batch.
    func testCameraItemsAloneNeverOpenALibraryBatch() throws {
        var queue = PendingFramingQueue()
        queue.enqueue(item(1, origin: .camera))
        let c = try XCTUnwrap(queue.beginResolving())
        queue.finishResolving(c, landed: false)
        XCTAssertFalse(queue.libraryBatchIsOver)
    }
}
