import XCTest
@testable import Raconte

/// T7 Mark Voices (issue #56): `VoiceDisplay` is the one place voice-id -> rendering
/// decisions are made, replacing `TranscriptAttribution.displayName`/`isItalic`. Pure,
/// no I/O — every case here is a value-in, value-out assertion.
final class VoiceDisplayTests: XCTestCase {

    // MARK: label

    func testLabelIsNilByDefault() {
        XCTAssertNil(VoiceDisplay.label(forVoice: "bn", voiceLabels: [:]))
    }

    func testLabelReturnsTheConfiguredLabel() {
        XCTAssertEqual(VoiceDisplay.label(forVoice: "bn", voiceLabels: ["bn": "Grandpa"]), "Grandpa")
        XCTAssertNil(VoiceDisplay.label(forVoice: "ln", voiceLabels: ["bn": "Grandpa"]),
                    "a label configured for a different voice does not leak")
        XCTAssertNil(VoiceDisplay.label(forVoice: nil, voiceLabels: ["bn": "Grandpa"]),
                    "no voice in force -> no label, regardless of configuration")
    }

    func testEmptyOrWhitespaceLabelYieldsNil() {
        XCTAssertNil(VoiceDisplay.label(forVoice: "bn", voiceLabels: ["bn": ""]))
        XCTAssertNil(VoiceDisplay.label(forVoice: "bn", voiceLabels: ["bn": "   "]))
    }

    // MARK: isItalic

    func testIsItalicIsTrueOnlyForTheMainVoice() {
        XCTAssertTrue(VoiceDisplay.isItalic(voice: "bn"))
        XCTAssertFalse(VoiceDisplay.isItalic(voice: "ln"))
        XCTAssertFalse(VoiceDisplay.isItalic(voice: "x-third"))
        XCTAssertFalse(VoiceDisplay.isItalic(voice: nil))
    }

    // MARK: other

    func testOtherFlipsBetweenTheTwoVoices() {
        XCTAssertEqual(VoiceDisplay.other("bn"), "ln")
        XCTAssertEqual(VoiceDisplay.other("ln"), "bn")
    }

    // MARK: accessibilityName

    func testAccessibilityNameFallsBackToUppercasedVoiceID() {
        XCTAssertEqual(VoiceDisplay.accessibilityName(forVoice: "bn", voiceLabels: [:]), "BN")
        XCTAssertEqual(VoiceDisplay.accessibilityName(forVoice: "ln", voiceLabels: ["bn": "Grandpa"]), "LN")
    }

    /// Companion to the fallback test above: `accessibilityName` documents TWO
    /// behaviours ("label if set, else voice.uppercased()") and the brief's named tests
    /// only pin the fallback half. Added so the label-present branch isn't a wholly
    /// untested branch (the exact vacuous-fixture shape this codebase's history keeps
    /// finding).
    func testAccessibilityNameUsesTheConfiguredLabelWhenSet() {
        XCTAssertEqual(VoiceDisplay.accessibilityName(forVoice: "bn", voiceLabels: ["bn": "Grandpa"]), "Grandpa")
    }
}
