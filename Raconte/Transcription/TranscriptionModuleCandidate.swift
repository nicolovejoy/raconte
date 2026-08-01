import Foundation
import AVFoundation
import Speech

/// The §6.1 module fallback, factored out of `SpeechAnalyzerEngine` so the *order of
/// preference* is testable with no models, no hardware, and — critically — no chance of
/// a test run deciding to download several hundred megabytes of assets.
///
/// Why a protocol rather than one generic function over `SpeechModule`: the two modules
/// share `SpeechModule`, but it has associated types (`Result`, `Results`), so the only
/// existential that carries results is one we write ourselves. And the module object
/// cannot cross a `Sendable` seam as an `AVAudioFormat`-producing value anyway. So each
/// candidate keeps its own concrete module and answers in `Sendable` terms:
/// `AudioFormatDescriptor`, `Locale`, `String`.
///
/// The gate rule is fixed and non-negotiable (§6, measured on the mini 2026-07-31):
/// **a real `bestAvailableAudioFormat` is the only proof the model bytes are there.**
/// `AssetInventory.status` tracks *this app's reservation*, not installation, so it is
/// advisory only — see `installAssetsIfPossible`.
protocol TranscriptionModuleCandidate: Sendable {
    /// The string written into every `TranscriptRecord.generator` (§3) when this
    /// candidate wins: `"SpeechTranscriber"` or `"DictationTranscriber"`.
    var generator: String { get }

    /// Can this module run on this OS/device at all, before any locale or asset
    /// question. `false` means skip it without building anything.
    func isAvailable() async -> Bool

    /// The module's own locale resolution. Deliberately per-candidate: the two modules
    /// do not ship the same locale sets, and `SpeechTranscriber` refusing a locale says
    /// nothing about `DictationTranscriber`.
    func resolvedLocale(matching requested: Locale) async -> Locale?

    /// Construct the module for `locale`. Called once, only after `resolvedLocale`
    /// succeeded, and always before `analysisFormat` / `installAssetsIfPossible`.
    func build(locale: Locale) async

    /// The analyzer's preferred format **for the module this candidate just built**.
    ///
    /// Never share a format between candidates: `bestAvailableAudioFormat` is a question
    /// about a specific set of modules, and handing `DictationTranscriber` a format
    /// resolved against `SpeechTranscriber` would feed the analyzer buffers it never
    /// asked for.
    func analysisFormat(considering input: AudioFormatDescriptor) async -> ModuleFormatProbe

    /// Attempt an asset install. Reached **only** when `analysisFormat` returned
    /// `.unavailable`. Returns `false` when there is nothing worth requesting (no asset
    /// can ever support this module/locale), which is a skip, not a failure. Throws only
    /// on a genuine install failure.
    @discardableResult
    func installAssetsIfPossible() async throws -> Bool

    /// The built module, for `SpeechAnalyzer(modules:)`. `nil` until `build` ran.
    func speechModule() async -> (any SpeechModule)?

    /// Drain this module's own result sequence, mapped onto the capture-frame axis.
    /// The candidate does it because only it knows the concrete `Result` type.
    func forwardResults(
        inputRate: Double,
        into continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation
    ) async -> Task<Void, Never>?
}

/// Three answers, not two — the distinction is load-bearing.
///
/// `.unavailable` is the assets-missing signal and the *only* thing that justifies an
/// install attempt. `.unrepresentable` is a format the seam's value type cannot carry
/// (§11.7); downloading more assets cannot fix it, and treating it as `.unavailable`
/// would fire an install request at a machine that already has everything.
enum ModuleFormatProbe: Sendable, Equatable {
    case unavailable
    case unrepresentable
    case ready(AudioFormatDescriptor)
}

/// What selection settled on. Carries the candidate itself because `prepare` still needs
/// the module and the results drain from it.
struct SelectedTranscriptionModule: Sendable {
    var candidate: any TranscriptionModuleCandidate
    var generator: String
    var locale: Locale
    var analysisFormat: AudioFormatDescriptor
}

/// The §6.1 rule, in one place: try candidates in order, take the first that yields a
/// real analysis format, and fail honestly when none does.
enum TranscriptionModuleSelector {

    /// The shipped order of preference. `SpeechTranscriber` is the better model;
    /// `DictationTranscriber` is the fallback, not a peer.
    static func defaultCandidates() -> [any TranscriptionModuleCandidate] {
        [SpeechTranscriberCandidate(), DictationTranscriberCandidate()]
    }

    static func select(from candidates: [any TranscriptionModuleCandidate],
                       requestedLocale: Locale,
                       inputFormat: AudioFormatDescriptor) async throws -> SelectedTranscriptionModule {
        // Enough state to report *why* nothing worked, at the granularity the existing
        // `TranscriptionUnavailable` cases already distinguish.
        var sawAvailableModule = false
        var probedAFormat = false
        var installFailure: String?

        for candidate in candidates {
            guard await candidate.isAvailable() else { continue }
            sawAvailableModule = true

            guard let locale = await candidate.resolvedLocale(matching: requestedLocale) else { continue }
            await candidate.build(locale: locale)
            probedAFormat = true

            var probe = await candidate.analysisFormat(considering: inputFormat)

            if probe == .unavailable {
                do {
                    // `false` == nothing to request; not an error, just this candidate
                    // having nothing further to offer.
                    guard try await candidate.installAssetsIfPossible() else { continue }
                } catch {
                    installFailure = String(describing: error)
                    continue
                }
                // §6.4: re-ask rather than trusting the request's own success. The format
                // is the proof; the request is not.
                probe = await candidate.analysisFormat(considering: inputFormat)
            }

            if case .ready(let descriptor) = probe {
                return SelectedTranscriptionModule(candidate: candidate,
                                                   generator: candidate.generator,
                                                   locale: locale,
                                                   analysisFormat: descriptor)
            }
        }

        // Honest failure, most specific first. Transcription is derived (§0): every one
        // of these leaves capture untouched.
        if let installFailure { throw TranscriptionUnavailable.other("model install failed: \(installFailure)") }
        if probedAFormat { throw TranscriptionUnavailable.noAnalysisFormat }
        if sawAvailableModule { throw TranscriptionUnavailable.unsupportedLocale(requestedLocale.identifier) }
        throw TranscriptionUnavailable.noModel
    }
}

// MARK: - Shared result mapping

/// The slice of a `SpeechModuleResult` this app maps. `text` is on neither
/// `SpeechModule` nor `SpeechModuleResult` — both transcribers declare it on their own
/// nested `Result` — so one internal protocol lets `SpeechAnalyzerEngine.map` serve both
/// without duplicating the frame math. `isFinal` comes free from the SDK's own
/// `SpeechModuleResult` extension.
protocol TimedTextResult: SpeechModuleResult, Sendable {
    var text: AttributedString { get }
}

extension SpeechTranscriber.Result: TimedTextResult {}
extension DictationTranscriber.Result: TimedTextResult {}

// MARK: - Real candidates

/// Everything both real candidates do identically.
private enum SDKCandidateSupport {

    /// Probe the format for exactly these modules, and verify the seam's value type
    /// survives it (§11.7).
    ///
    /// The round-trip check is here rather than in the engine because only here does the
    /// original `AVAudioFormat` exist. Failing it is `.unrepresentable`, not
    /// `.unavailable`: the session converts to whatever descriptor comes back, so a
    /// descriptor that does not rebuild into the analyzer's actual format would have the
    /// analyzer rejecting buffers mid-run as an opaque failure.
    static func probe(modules: [any SpeechModule],
                      considering input: AudioFormatDescriptor) async -> ModuleFormatProbe {
        guard let analysisAV = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules, considering: input.avAudioFormat) else { return .unavailable }

        let descriptor = AudioFormatDescriptor(from: analysisAV)
        guard let roundTripped = descriptor.avAudioFormat, roundTripped.isEqual(analysisAV) else {
            return .unrepresentable
        }
        return .ready(descriptor)
    }

    /// Install models. Reached **only** when there is no analysis format to be had.
    ///
    /// Nothing about installation state is cached: assets are shared system-wide and the
    /// system *"may unsubscribe your app from assets that haven't been used in a while"*,
    /// so this is re-decided at every capture start (§6.4).
    static func install(for modules: [any SpeechModule]) async throws -> Bool {
        // Advisory only. `.unsupported` means no asset can ever support this module, so
        // requesting one is pointless — a skip, not a failure.
        guard await AssetInventory.status(forModules: modules) > .unsupported else { return false }
        // Returns nil when nothing further is needed. Auto-reserves the locale, and
        // throws if that would exceed `maximumReservedLocales` — which varies by device,
        // so it is never hardcoded.
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: modules) else { return true }
        try await request.downloadAndInstall()
        return true
    }

    static func forward<M: SpeechModule>(
        module: M,
        inputRate: Double,
        into continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation
    ) -> Task<Void, Never> where M.Result: TimedTextResult {
        Task {
            do {
                for try await result in module.results {
                    continuation.yield(SpeechAnalyzerEngine.map(result, inputRate: inputRate))
                }
                continuation.finish()
            } catch {
                // *"If there is an error in the overall analysis, all modules will throw
                // the error from their individual result sequence"* — so this is the one
                // and only error path for analysis failures.
                continuation.finish(throwing: error)
            }
        }
    }
}

/// The preferred module.
final class SpeechTranscriberCandidate: TranscriptionModuleCandidate, @unchecked Sendable {
    let generator = "SpeechTranscriber"

    private let lock = NSLock()
    private var module: SpeechTranscriber?
    private var current: SpeechTranscriber? { lock.withLock { module } }

    func isAvailable() async -> Bool { SpeechTranscriber.isAvailable }

    func resolvedLocale(matching requested: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    }

    func build(locale: Locale) async {
        // Deliberately not a `Preset`. No shipped preset enables `.transcriptionConfidence`
        // (verified against the preset table in the SDK's own `.swiftdoc`), and
        // `timeIndexedProgressiveTranscription` couples `.volatileResults` with
        // `.fastResults`, which trades accuracy for latency. §10.5 A/Bs that separately.
        let built = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        lock.withLock { module = built }
    }

    func analysisFormat(considering input: AudioFormatDescriptor) async -> ModuleFormatProbe {
        guard let module = current else { return .unavailable }
        return await SDKCandidateSupport.probe(modules: [module], considering: input)
    }

    func installAssetsIfPossible() async throws -> Bool {
        guard let module = current else { return false }
        return try await SDKCandidateSupport.install(for: [module])
    }

    func speechModule() async -> (any SpeechModule)? { current }

    func forwardResults(
        inputRate: Double,
        into continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation
    ) async -> Task<Void, Never>? {
        guard let module = current else { return nil }
        return SDKCandidateSupport.forward(module: module, inputRate: inputRate, into: continuation)
    }
}

/// The §6.1 fallback.
///
/// Two real differences from `SpeechTranscriber`, both verified against the Xcode 26.6
/// SDK rather than assumed:
///
/// - **There is no `DictationTranscriber.isAvailable`.** `isAvailable` exists on
///   `SpeechTranscriber` alone, so availability here is answered the only honest way
///   available: whether a locale resolves, and then whether a format comes back.
/// - **Punctuation is opt-in.** `SpeechTranscriber.TranscriptionOption` has exactly one
///   case (`.etiquetteReplacements`) and punctuates by default;
///   `DictationTranscriber.TranscriptionOption` adds `.punctuation` and `.emoji`.
///   A journal wants sentences, so `.punctuation` is requested and `.emoji` is not.
///
/// It is also narrower on platforms — `@available(tvOS, unavailable)` where
/// `SpeechTranscriber` is not — which is irrelevant to a target that ships iOS and macOS
/// only, and is why no `#if` guards this file.
final class DictationTranscriberCandidate: TranscriptionModuleCandidate, @unchecked Sendable {
    let generator = "DictationTranscriber"

    private let lock = NSLock()
    private var module: DictationTranscriber?
    private var current: DictationTranscriber? { lock.withLock { module } }

    /// The SDK offers no static availability flag for this module. Reporting `true` here
    /// costs one `supportedLocale` call and keeps the *only* real proof — a format —
    /// where §6 puts it.
    func isAvailable() async -> Bool { true }

    func resolvedLocale(matching requested: Locale) async -> Locale? {
        await DictationTranscriber.supportedLocale(equivalentTo: requested)
    }

    func build(locale: Locale) async {
        let built = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        lock.withLock { module = built }
    }

    func analysisFormat(considering input: AudioFormatDescriptor) async -> ModuleFormatProbe {
        guard let module = current else { return .unavailable }
        return await SDKCandidateSupport.probe(modules: [module], considering: input)
    }

    func installAssetsIfPossible() async throws -> Bool {
        guard let module = current else { return false }
        return try await SDKCandidateSupport.install(for: [module])
    }

    func speechModule() async -> (any SpeechModule)? { current }

    func forwardResults(
        inputRate: Double,
        into continuation: AsyncThrowingStream<TranscriptResult, Error>.Continuation
    ) async -> Task<Void, Never>? {
        guard let module = current else { return nil }
        return SDKCandidateSupport.forward(module: module, inputRate: inputRate, into: continuation)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
