import XCTest
import AVFoundation
import Speech
@testable import Raconte

/// A **probe, not a test.** It asserts almost nothing; it prints what this machine's
/// Speech stack actually reports, so the §10 VERIFY list can be settled from facts
/// rather than inference.
///
/// Deliberately never fails on an unavailable stack: CI runners have no model assets, and
/// a red build there would say "the code is broken" when it means "no models here."
/// It also never downloads: `assetInstallationRequest` pulls hundreds of megabytes, which
/// is not a thing a test run gets to decide.
final class SpeechAvailabilityProbe: XCTestCase {

    func testReportSpeechStack() async throws {
        var report = ["", "──── Speech stack probe ────"]

        report.append("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        report.append("AssetInventory.maximumReservedLocales: \(AssetInventory.maximumReservedLocales)")
        report.append("reservedLocales: \(await AssetInventory.reservedLocales.map(\.identifier))")

        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        report.append("installedLocales (\(installed.count)): \(installed.prefix(12))")

        let current = Locale.current
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: current)
        report.append("current locale: \(current.identifier) → resolved: \(resolved?.identifier ?? "nil")")
        if let resolved, resolved.identifier != current.identifier {
            report.append("  ⚠︎ NEAR-EQUIVALENT, not exact — §6.2 says show a picker")
        }

        guard SpeechTranscriber.isAvailable, let locale = resolved else {
            report.append("→ unavailable on this machine; nothing further to probe")
            print(report.joined(separator: "\n"))
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        let status = await AssetInventory.status(forModules: [transcriber])
        report.append("AssetInventory.status: \(status)  (installed == ready)")

        // The capture path's canonical format, which is what `prepare` would pass.
        let capture = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 48_000, channels: 1, interleaved: false)
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                 considering: capture)
        if let best {
            report.append("bestAvailableAudioFormat: \(best)")
            report.append("  sampleRate=\(best.sampleRate) channels=\(best.channelCount) "
                          + "common=\(best.commonFormat.rawValue) interleaved=\(best.isInterleaved)")

            // The §11.7 assertion, measured rather than assumed.
            let descriptor = AudioFormatDescriptor(from: best)
            let roundTripped = descriptor.avAudioFormat
            let survives = roundTripped?.isEqual(best) ?? false
            report.append("  descriptor round-trip isEqual: \(survives)")
            if !survives {
                report.append("  ⚠︎ the seam's value type does NOT survive this format — "
                              + "engine correctly refuses, but §11.7 needs revisiting")
            }
        } else {
            report.append("bestAvailableAudioFormat: nil → assets not installed (§6)")
        }

        let formats = await transcriber.availableCompatibleAudioFormats
        report.append("availableCompatibleAudioFormats: \(formats.map { "\($0.sampleRate)Hz" })")
        report.append("────────────────────────────")
        print(report.joined(separator: "\n"))
    }
}
