import XCTest
@testable import Raconte

/// M4 T3: `SyncRecordName` build + parse. Every shape is prefixed and total —
/// `init?(rawValue:)` must accept exactly what `rawValue` produces and reject
/// everything else, including a bare ULID (no prefix) and the ambiguous-looking
/// multi-dot shapes (`a.<ulid>.0`, `m.<ulid>.<ulid>`) fed anything other than the exact
/// grammar.
final class SyncRecordNameTests: XCTestCase {

    // Two real 26-char Crockford ULIDs (the SyncBookkeepingTests fixture pair), so
    // `ULID.isWellFormed` validation inside `init?` doesn't reject the round-trip.
    private let ulidA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let ulidB = "01BRZ3NDEKTSV4RRFFQ69G5FAW"

    // MARK: rawValue shapes

    func testJournalRawValue() {
        XCTAssertEqual(SyncRecordName.journal(id: ulidA).rawValue, "j.\(ulidA)")
    }

    func testEntryRawValue() {
        XCTAssertEqual(SyncRecordName.entry(captureID: ulidA).rawValue, "e.\(ulidA)")
    }

    func testAudioRawValueIsTheAmbiguousLookingThreeComponentShape() {
        XCTAssertEqual(SyncRecordName.audio(captureID: ulidA).rawValue, "a.\(ulidA).0")
    }

    func testRevisionRawValue() {
        XCTAssertEqual(SyncRecordName.revision(id: ulidA).rawValue, "r.\(ulidA)")
    }

    func testLiveLogRawValue() {
        XCTAssertEqual(SyncRecordName.liveLog(captureID: ulidA).rawValue, "l.\(ulidA)")
    }

    func testMarkerStreamRawValueIsTheAmbiguousLookingTwoUlidShape() {
        XCTAssertEqual(SyncRecordName.markerStream(captureID: ulidA, deviceID: ulidB).rawValue,
                       "m.\(ulidA).\(ulidB)")
    }

    // MARK: Round trip, every case

    func testRoundTripJournal() {
        let name = SyncRecordName.journal(id: ulidA)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripEntry() {
        let name = SyncRecordName.entry(captureID: ulidA)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripAudio() {
        let name = SyncRecordName.audio(captureID: ulidA)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripRevision() {
        let name = SyncRecordName.revision(id: ulidA)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripLiveLog() {
        let name = SyncRecordName.liveLog(captureID: ulidA)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripMarkerStream() {
        let name = SyncRecordName.markerStream(captureID: ulidA, deviceID: ulidB)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    func testRoundTripDistinguishesCaptureIDFromDeviceIDInMarkerStream() {
        // The two-ULID shape is exactly why order matters: swapping them must NOT
        // round-trip to the same value.
        let name = SyncRecordName.markerStream(captureID: ulidA, deviceID: ulidB)
        let swapped = SyncRecordName.markerStream(captureID: ulidB, deviceID: ulidA)
        XCTAssertNotEqual(name, swapped)
        XCTAssertEqual(SyncRecordName(rawValue: swapped.rawValue), swapped)
    }

    // MARK: init? rejects garbage

    func testInitRejectsABareULIDWithNoPrefix() {
        // The whole reason every shape is prefixed (design amendment, "Locked
        // decisions"): a bare ULID cannot be told apart from any record's id.
        XCTAssertNil(SyncRecordName(rawValue: ulidA))
    }

    func testInitRejectsEmptyString() {
        XCTAssertNil(SyncRecordName(rawValue: ""))
    }

    func testInitRejectsUnknownPrefix() {
        XCTAssertNil(SyncRecordName(rawValue: "x.\(ulidA)"))
    }

    func testInitRejectsPrefixAlone() {
        XCTAssertNil(SyncRecordName(rawValue: "j"))
    }

    func testInitRejectsTrailingDotWithEmptyComponent() {
        XCTAssertNil(SyncRecordName(rawValue: "j.\(ulidA)."))
    }

    func testInitRejectsDoubleDotEmptyComponent() {
        XCTAssertNil(SyncRecordName(rawValue: "m.\(ulidA)..\(ulidB)"))
    }

    func testInitRejectsGarbageIdThatIsNotAWellFormedULID() {
        XCTAssertNil(SyncRecordName(rawValue: "j.not-a-ulid"))
        XCTAssertNil(SyncRecordName(rawValue: "e.tooshort"))
    }

    func testInitRejectsAudioWithWrongIndexSuffix() {
        // Only index 0 is modeled today (no multi-recording built yet) — a syntactically
        // matching shape naming a future index is garbage to THIS build, not a case it
        // silently mismodels.
        XCTAssertNil(SyncRecordName(rawValue: "a.\(ulidA).1"))
    }

    func testInitRejectsAudioMissingItsIndexSuffix() {
        XCTAssertNil(SyncRecordName(rawValue: "a.\(ulidA)"))
    }

    func testInitRejectsJournalWithExtraComponent() {
        XCTAssertNil(SyncRecordName(rawValue: "j.\(ulidA).extra"))
    }

    func testInitRejectsMarkerStreamMissingDeviceID() {
        XCTAssertNil(SyncRecordName(rawValue: "m.\(ulidA)"))
    }

    func testInitRejectsMarkerStreamWithGarbageDeviceID() {
        XCTAssertNil(SyncRecordName(rawValue: "m.\(ulidA).not-a-device-id"))
    }

    // MARK: Image (image-capture plan Task 4)

    func testImageRawValueEmbedsBothTheCaptureIDAndTheImageID() {
        XCTAssertEqual(SyncRecordName.image(captureID: ulidA, imageID: ulidB).rawValue,
                       "i.\(ulidA).\(ulidB)")
    }

    func testRoundTripImage() {
        let name = SyncRecordName.image(captureID: ulidA, imageID: ulidB)
        XCTAssertEqual(SyncRecordName(rawValue: name.rawValue), name)
    }

    /// Same two-ULID shape as `.markerStream`, told apart on the prefix alone — so the
    /// components must not be swappable and the two shapes must not collide.
    func testImageAndMarkerStreamShareAShapeButNeverAValue() {
        let image = SyncRecordName.image(captureID: ulidA, imageID: ulidB)
        let swapped = SyncRecordName.image(captureID: ulidB, imageID: ulidA)
        XCTAssertNotEqual(image, swapped)
        XCTAssertEqual(SyncRecordName(rawValue: swapped.rawValue), swapped)
        XCTAssertNotEqual(image.rawValue,
                          SyncRecordName.markerStream(captureID: ulidA, deviceID: ulidB).rawValue)
    }

    func testInitRejectsImageMissingItsImageID() {
        XCTAssertNil(SyncRecordName(rawValue: "i.\(ulidA)"))
    }

    func testInitRejectsImageWithAGarbageImageID() {
        XCTAssertNil(SyncRecordName(rawValue: "i.\(ulidA).not-a-ulid"))
    }

    // MARK: parentEntry (#91)

    func testAudioParentEntryIsTheEntryWithTheSameCaptureID() {
        XCTAssertEqual(SyncRecordName.audio(captureID: ulidA).parentEntry, .entry(captureID: ulidA))
    }

    func testLiveLogParentEntryIsTheEntryWithTheSameCaptureID() {
        XCTAssertEqual(SyncRecordName.liveLog(captureID: ulidA).parentEntry, .entry(captureID: ulidA))
    }

    func testMarkerStreamParentEntryIsTheEntryWithTheSameCaptureID() {
        XCTAssertEqual(SyncRecordName.markerStream(captureID: ulidA, deviceID: ulidB).parentEntry,
                       .entry(captureID: ulidA))
    }

    func testImageParentEntryIsTheEntryWithTheSameCaptureID() {
        XCTAssertEqual(SyncRecordName.image(captureID: ulidA, imageID: ulidB).parentEntry,
                       .entry(captureID: ulidA))
    }

    /// `.revision` carries only its own id — there is no captureID to derive a parent
    /// from. Callers recover the parent from the failed record's `entryRef` field.
    func testRevisionParentEntryIsNil() {
        XCTAssertNil(SyncRecordName.revision(id: ulidA).parentEntry)
    }

    func testEntryParentEntryIsNil() {
        XCTAssertNil(SyncRecordName.entry(captureID: ulidA).parentEntry)
    }

    func testJournalParentEntryIsNil() {
        XCTAssertNil(SyncRecordName.journal(id: ulidA).parentEntry)
    }
}
