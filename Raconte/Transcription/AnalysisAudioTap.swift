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
        // Settings taken from the analyzer's own format, so the file is literally what
        // it received — not a re-interpretation.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file
        return file
    }

    func close() { file = nil }
}
#endif
