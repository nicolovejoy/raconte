#if DEBUG
import Foundation
import AVFoundation

/// Diagnostic only: writes the buffers handed to the analyzer to
/// `transcript/analysis-input.wav`, so "the transcript is gibberish" can be split into
/// "the audio we send is wrong" and "the audio is fine, the model disagrees".
///
/// Gated on `RACONTE_DUMP_ANALYSIS_AUDIO=1`. Never present in a release build, and never
/// on the capture path — it observes the *derived* branch only.
final class AnalysisAudioTap {
    private let directory: URL
    private var file: AVAudioFile?
    private var failed = false

    init(directory: URL) { self.directory = directory }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            let file = try openIfNeeded(format: buffer.format)
            // `AVAudioFile.write(from:)` raises an **ObjC exception** — not a Swift error
            // — when the buffer's format differs from `processingFormat`, and Swift
            // cannot catch it, so it takes the whole app down. That is exactly what this
            // tap did on its first run: a diagnostic on the derived branch killing the
            // recording, which is the coupling §0 forbids. Check first, and disable
            // rather than trap.
            guard buffer.format.isEqual(file.processingFormat) else {
                failed = true
                return
            }
            try file.write(from: buffer)
        } catch {
            failed = true
        }
    }

    private func openIfNeeded(format: AVAudioFormat) throws -> AVAudioFile {
        if let file { return file }
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: directory),
            withIntermediateDirectories: true)
        let url = SegmentLayout.transcriptDirectory(captureDirectory: directory)
            .appendingPathComponent("analysis-input.wav")
        // `commonFormat`/`interleaved` must be passed explicitly. The two-argument
        // initializer gives the file a *standard* Float32 non-interleaved processing
        // format whatever the settings say, so an Int16 analyzer buffer — which is what
        // the mini's `bestAvailableAudioFormat` returns — cannot be written to it.
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        self.file = file
        return file
    }

    func close() { file = nil }
}
#endif
