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
}
