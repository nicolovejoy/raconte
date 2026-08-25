import XCTest
import UniformTypeIdentifiers
@testable import Raconte

/// Image capture plan Task 9 brief: "prefer a pure unit test on the data-extraction
/// step (`NSItemProvider`/pasteboard -> `Data` + UTType… ) over attempting a full
/// simulated drag gesture." Pins `ImageDropSource.extract`, the one function both
/// `EntryDetailView`'s `.onDrop`/`.onPasteCommand` and `LibraryEntryRow`'s `.onDrop`
/// hand their `[NSItemProvider]` to before ever reaching `LibraryScreenModel.addImage` —
/// the same write path `ImageCapturePickerSheet`'s `onPick` already exercises end to end
/// (Tasks 2/3/6). This file never touches `addImage` itself; it exists to confirm the
/// bridge from a platform-supplied item provider to the `(Data, UTType)` shape that
/// write path expects.
final class ImageDropSourceTests: XCTestCase {

    func testExtractsDataAndTypeFromAnImageProvider() async {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let provider = NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.jpeg.identifier)

        let result = await ImageDropSource.extract(from: [provider])

        XCTAssertEqual(result?.data, bytes)
        XCTAssertEqual(result?.type, .jpeg)
    }

    func testReturnsNilWhenNoProviderOffersAnImage() async {
        let provider = NSItemProvider(item: Data("hello".utf8) as NSData,
                                      typeIdentifier: UTType.plainText.identifier)

        let result = await ImageDropSource.extract(from: [provider])

        XCTAssertNil(result)
    }

    func testReturnsNilForAnEmptyProviderList() async {
        let result = await ImageDropSource.extract(from: [])

        XCTAssertNil(result)
    }

    /// A real drag/paste often carries several providers (e.g. a Finder drag also
    /// offers a file-URL representation) — the function must skip past a non-image
    /// provider rather than bail on the whole list.
    func testSkipsANonImageProviderAndUsesTheNextOne() async {
        let textProvider = NSItemProvider(item: Data("hello".utf8) as NSData,
                                          typeIdentifier: UTType.plainText.identifier)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let imageProvider = NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.png.identifier)

        let result = await ImageDropSource.extract(from: [textProvider, imageProvider])

        XCTAssertEqual(result?.data, bytes)
        XCTAssertEqual(result?.type, .png)
    }
}
