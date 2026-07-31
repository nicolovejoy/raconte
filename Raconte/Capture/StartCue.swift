import Foundation
import AVFoundation

/// Short rising blip played immediately *before* the tap goes live.
///
/// Placement is the whole point: the cue finishes, then `recorder.start` installs the
/// tap. So "the blip means start talking" is literally true, and the tone itself never
/// lands in the recording — which it would if we played it once the mic was hot
/// (`.playAndRecord` + `.defaultToSpeaker` has no echo cancellation in `.spokenAudio`).
///
/// Same approach as `SegmentPlayer`: a private `AVAudioEngine` + `AVAudioPlayerNode`
/// rendering one in-memory buffer — no bundled asset, no file I/O, both platforms.
///
/// Every failure path is silent. A cue that can't play must never stop a capture from
/// starting, and the fixed settle delay means it can never block one either.
@MainActor
final class StartCue {
    /// Tone length. The settle wait is slightly longer so the tail is audible before
    /// the tap opens.
    private static let toneSeconds = 0.14
    private static let settle = Duration.milliseconds(190)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    func play() async {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 44100, channels: 1, interleaved: false),
              let buffer = Self.blip(format: format) else { return }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }

        node.scheduleBuffer(buffer, completionHandler: nil)
        node.play()
        try? await Task.sleep(for: Self.settle)

        node.stop()
        engine.stop()
        engine.detach(node)
    }

    /// 660 → 990 Hz rise with a raised-cosine envelope. The envelope matters: a bare
    /// sine gated on and off clicks, which reads as a glitch rather than a cue.
    private static func blip(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * toneSeconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        let n = Double(frames)
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / n
            let hz = 660 + 330 * t
            phase += 2 * .pi * hz / format.sampleRate
            let envelope = 0.5 * (1 - cos(2 * .pi * min(1, max(0, t))))
            channel[i] = Float(sin(phase) * envelope * 0.22)
        }
        return buffer
    }
}
