import XCTest
import AVFoundation
import Speech
@testable import Raconte

/// A `TranscriptionModuleCandidate` with no models and no SDK, so the §6.1 fallback
/// *rule* is reachable on CI.
///
/// The seam exists precisely so these tests never call the real `AssetInventory`:
/// `assetInstallationRequest` downloads hundreds of megabytes, which is not a thing a
/// test run gets to decide (the same reason `SpeechAvailabilityProbe` refuses to).
final class FakeModuleCandidate: TranscriptionModuleCandidate, @unchecked Sendable {

    enum Call: Equatable {
        case isAvailable
        case resolveLocale
        case build(String)
        case analysisFormat
        case install
    }

    let generator: String

    var available = true
    var locale: Locale?
    /// Probes are consumed in order; the last one repeats. Two entries model
    /// "nothing, then something after installing".
    var probes: [ModuleFormatProbe] = [.unavailable]
    /// `false` == nothing worth requesting. Throwing models a real install failure.
    var installSucceeds = true
    var installError: Error?

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _probeIndex = 0

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// Non-`async` on purpose: `NSLock.lock()` is unavailable from an async context.
    private func nextProbe() -> ModuleFormatProbe {
        lock.lock(); defer { lock.unlock() }
        let probe = probes[min(_probeIndex, probes.count - 1)]
        _probeIndex += 1
        return probe
    }

    init(_ generator: String, locale: Locale? = Locale(identifier: "en_US")) {
        self.generator = generator
        self.locale = locale
    }

    private func record(_ call: Call) { lock.lock(); _calls.append(call); lock.unlock() }

    func isAvailable() async -> Bool {
        record(.isAvailable)
        return available
    }

    func resolvedLocale(matching requested: Locale) async -> Locale? {
        record(.resolveLocale)
        return locale
    }

    func build(locale: Locale) async { record(.build(locale.identifier)) }

    func analysisFormat(considering input: AudioFormatDescriptor) async -> ModuleFormatProbe {
        record(.analysisFormat)
        return nextProbe()
    }

    func installAssetsIfPossible() async throws -> Bool {
        record(.install)
        if let installError { throw installError }
        return installSucceeds
    }

    /// A real module only when a test needs `prepare` to get past the analyzer, since
    /// `SpeechAnalyzer(modules:)` will not take a stand-in. Constructing a
    /// `SpeechTranscriber` touches no assets and downloads nothing — the only call that
    /// would is `AssetInventory.assetInstallationRequest`, which this fake replaces.
    var module: (any SpeechModule)?

    func speechModule() async -> (any SpeechModule)? { module }

    func forwardResults(
        inputRate: Double,
        into continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation
    ) async -> Task<Void, Never>? { nil }
}

/// Design §6.1: `SpeechTranscriber`, else `DictationTranscriber`, else an honest
/// unavailable. Every assertion here is about *order* and *per-module questions* — the
/// two things that cannot be checked by reading a passing device run.
final class TranscriptionModuleSelectionTests: XCTestCase {

    private let inputFormat = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)

    private let speechFormat = AudioFormatDescriptor(
        sampleRate: 16_000, channels: 1, commonFormat: .pcmFormatInt16, interleaved: true)

    /// Deliberately different from `speechFormat` in every field that matters, so a test
    /// can tell which module's format came back.
    private let dictationFormat = AudioFormatDescriptor(
        sampleRate: 8_000, channels: 2, commonFormat: .pcmFormatFloat32, interleaved: false)

    private func select(_ candidates: [FakeModuleCandidate],
                        locale: Locale = Locale(identifier: "en_US")) async throws
    -> SelectedTranscriptionModule {
        try await TranscriptionModuleSelector.select(from: candidates,
                                                     requestedLocale: locale,
                                                     inputFormat: inputFormat)
    }

    // MARK: Preference order

    func testSpeechTranscriberWinsAndTheFallbackIsNeverTouched() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.ready(speechFormat)]
        let dictation = FakeModuleCandidate("DictationTranscriber")

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "SpeechTranscriber")
        XCTAssertEqual(selection.analysisFormat, speechFormat)
        XCTAssertEqual(dictation.calls, [],
                       "the fallback is a fallback — asking it anything costs a locale "
                       + "lookup and risks reserving a second locale for nothing")
    }

    func testUnavailableSpeechTranscriberFallsBackToDictation() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.available = false
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "DictationTranscriber")
        XCTAssertEqual(speech.calls, [.isAvailable],
                       "an unavailable module must not be built or probed")
    }

    /// The case the shipped code got wrong: `isAvailable` was the only gate, so a machine
    /// where the module exists but the model bytes do not gave up instead of falling back.
    func testSpeechTranscriberWithNoFormatFallsBackEvenThoughItIsAvailable() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable]          // still nothing after installing
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "DictationTranscriber")
        XCTAssertEqual(selection.analysisFormat, dictationFormat)
    }

    /// The constraint that outranks everything else here: a real format for *the module
    /// you intend to run*. Reusing the preferred module's format would feed the analyzer
    /// buffers it never asked for.
    func testTheWinnerReportsItsOwnFormatNotThePreferredModules() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.ready(speechFormat)]
        speech.available = false                // so its format is never in play
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.analysisFormat, dictationFormat)
        XCTAssertNotEqual(selection.analysisFormat, speechFormat)
        XCTAssertTrue(dictation.calls.contains(.analysisFormat),
                      "the fallback must be asked for its own format")
    }

    func testAssetsInstallIsRetriedOnceAndTheFormatIsTheProof() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable, .ready(speechFormat)]

        let selection = try await select([speech])

        XCTAssertEqual(selection.generator, "SpeechTranscriber")
        XCTAssertEqual(speech.calls,
                       [.isAvailable, .resolveLocale, .build("en_US"),
                        .analysisFormat, .install, .analysisFormat])
    }

    /// §6/§11: `AssetInventory.status` tracks this app's reservation, not the bytes. An
    /// install request on a machine that already has everything is the bug that gate
    /// exists to prevent.
    func testNoInstallIsAttemptedWhenAFormatAlreadyExists() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.ready(speechFormat)]

        _ = try await select([speech])

        XCTAssertFalse(speech.calls.contains(.install))
    }

    /// A format the seam's value type cannot carry (§11.7) is not an asset problem, and
    /// downloading more of them cannot fix it.
    func testUnrepresentableFormatSkipsInstallAndMovesToTheFallback() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unrepresentable]
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "DictationTranscriber")
        XCTAssertFalse(speech.calls.contains(.install))
    }

    func testInstallFailureOnThePreferredModuleStillReachesTheFallback() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable]
        speech.installError = TranscriptionUnavailable.other("download died")
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "DictationTranscriber")
    }

    /// "Nothing worth requesting" is a skip, not a failure — it must not be reported as
    /// an install error and must not stop the fallback.
    func testNothingToInstallIsASkipNotAFailure() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable]
        speech.installSucceeds = false
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation])

        XCTAssertEqual(selection.generator, "DictationTranscriber")
        XCTAssertEqual(speech.calls.filter { $0 == .analysisFormat }.count, 1,
                       "re-probing after an install that never happened is a wasted call")
    }

    // MARK: Locale, per candidate

    func testLocaleIsResolvedByEachCandidateSeparately() async throws {
        let speech = FakeModuleCandidate("SpeechTranscriber", locale: nil)
        let dictation = FakeModuleCandidate("DictationTranscriber",
                                            locale: Locale(identifier: "fr_CA"))
        dictation.probes = [.ready(dictationFormat)]

        let selection = try await select([speech, dictation], locale: Locale(identifier: "fr_FR"))

        XCTAssertEqual(selection.locale.identifier, "fr_CA",
                       "the resolved locale, not the requested one (§6.2)")
        XCTAssertEqual(dictation.calls.first(where: {
            if case .build = $0 { return true } else { return false }
        }), .build("fr_CA"))
        XCTAssertFalse(speech.calls.contains(.analysisFormat),
                       "a module with no locale must not be built or probed")
    }

    // MARK: Honest failure

    func testNoAvailableModuleAtAllIsNoModel() async {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.available = false
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.available = false

        await XCTAssertThrowsErrorAsync(try await select([speech, dictation])) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .noModel)
        }
    }

    func testAvailableModulesWithNoSupportedLocaleIsUnsupportedLocale() async {
        let speech = FakeModuleCandidate("SpeechTranscriber", locale: nil)
        let dictation = FakeModuleCandidate("DictationTranscriber", locale: nil)

        await XCTAssertThrowsErrorAsync(
            try await select([speech, dictation], locale: Locale(identifier: "xx_XX"))
        ) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .unsupportedLocale("xx_XX"))
        }
    }

    /// The CI case, and the case on a device whose assets were never installed. It must
    /// still throw: transcription is derived (§0) and the app records perfectly without
    /// it, but pretending a module was chosen would be a lie the session acts on.
    func testNeitherModuleYieldingAFormatStillFails() async {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable]
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.unavailable]

        await XCTAssertThrowsErrorAsync(try await select([speech, dictation])) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .noAnalysisFormat,
                           "both modules exist and both were asked — the bytes are what "
                           + "is missing, which is what this case documents")
        }
    }

    func testInstallFailureEverywhereIsReportedRatherThanSwallowed() async {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.probes = [.unavailable]
        speech.installError = TranscriptionUnavailable.other("disk full")
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.unavailable]
        dictation.installSucceeds = false

        await XCTAssertThrowsErrorAsync(try await select([speech, dictation])) { error in
            guard case .other(let message)? = error as? TranscriptionUnavailable else {
                return XCTFail("expected .other, got \(error)")
            }
            XCTAssertTrue(message.contains("disk full"), message)
        }
    }

    func testEmptyCandidateListIsNoModelNotACrash() async {
        await XCTAssertThrowsErrorAsync(try await select([])) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .noModel)
        }
    }

    // MARK: The engine's use of the selection

    /// `prepare` must carry the *selected* module's identity into `TranscriptionSetup`,
    /// which is what `LiveTranscriptWriter` stamps on every record (§3). A hardcoded
    /// `"SpeechTranscriber"` there would make a fallback run lie about its own
    /// provenance, and the log is the only place that lie would ever show up.
    ///
    /// The one test here that touches the real SDK, and only its cheap end: constructing
    /// a `SpeechTranscriber` and an analyzer downloads nothing (0.20 s measured, mini,
    /// 2026-07-31), and `prepareToAnalyze` is already best-effort `try?` in `prepare`, so
    /// an asset-free CI runner degrades rather than failing.
    func testEngineReportsTheFallbackModuleThroughTranscriptionSetup() async throws {
        let dictation = FakeModuleCandidate("DictationTranscriber",
                                            locale: Locale(identifier: "fr_CA"))
        dictation.probes = [.ready(dictationFormat)]
        dictation.module = SpeechTranscriber(locale: Locale(identifier: "en_US"),
                                             transcriptionOptions: [],
                                             reportingOptions: [],
                                             attributeOptions: [])
        let engine = SpeechAnalyzerEngine(locale: Locale(identifier: "fr_FR"),
                                          candidates: [dictation])

        let setup = try await engine.prepare(inputFormat: inputFormat)
        await engine.abandon()

        XCTAssertEqual(setup.generator, "DictationTranscriber")
        XCTAssertEqual(setup.locale, "fr_CA")
        XCTAssertEqual(setup.analysisFormat, dictationFormat)
    }

    func testEngineRefusesWhenSelectionYieldsNoUsableModule() async {
        // Every fake reports `speechModule() == nil`, so the engine cannot construct an
        // analyzer — the honest outcome, and reachable with no SDK contact at all.
        let dictation = FakeModuleCandidate("DictationTranscriber")
        dictation.probes = [.ready(dictationFormat)]
        let engine = SpeechAnalyzerEngine(locale: Locale(identifier: "en_US"),
                                          candidates: [dictation])

        await XCTAssertThrowsErrorAsync(try await engine.prepare(inputFormat: inputFormat)) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .noAnalysisFormat)
        }
        XCTAssertTrue(dictation.calls.contains(.analysisFormat),
                      "the engine drives selection rather than probing on its own")
    }

    func testEnginePropagatesTheUnavailableReasonFromSelection() async {
        let speech = FakeModuleCandidate("SpeechTranscriber")
        speech.available = false
        let engine = SpeechAnalyzerEngine(locale: Locale(identifier: "en_US"),
                                          candidates: [speech])

        await XCTAssertThrowsErrorAsync(try await engine.prepare(inputFormat: inputFormat)) { error in
            XCTAssertEqual(error as? TranscriptionUnavailable, .noModel)
        }
    }
}

/// `XCTAssertThrowsError` predates `async`; its autoclosure is not async.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath,
                                  line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
