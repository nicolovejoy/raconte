import Foundation
import AVFoundation

/// Plays an ordered raw-PCM segment set gap-free.
///
/// Approach: AVAudioEngine + AVAudioPlayerNode. Each flat `Float32` mono `.pcm`
/// file is read into an `AVAudioPCMBuffer` at the canonical format and scheduled
/// in index order — `AVAudioPlayerNode` renders scheduled buffers back-to-back
/// with no gap, which is exactly the "concatenate the segments" semantics (design
/// §5). Simplest testable path: no muxing, no intermediate file.
@MainActor
final class SegmentPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let renderFormat: AVAudioFormat
    private let segments: [EncodableSegment]

    let sampleRate: Double
    let totalFrames: Int

    private(set) var didFinish = false
    private var scheduled = false

    init(segments: [EncodableSegment], format: AudioFormatDescriptor) {
        self.segments = segments.sorted { $0.index < $1.index }
        self.sampleRate = Double(max(1, format.sampleRate))
        self.totalFrames = segments.reduce(0) { $0 + max(0, $1.frameCount) }
        self.renderFormat = AVAudioFormat(
            commonFormat: Self.commonFormat(format.commonFormat),
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(max(1, format.channels)),
            interleaved: format.interleaved)
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
    }

    var totalDuration: TimeInterval { Double(totalFrames) / sampleRate }

    /// Node player time in seconds, clamped to the total, or the finished total.
    var currentTime: TimeInterval {
        if didFinish { return totalDuration }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return min(Double(playerTime.sampleTime) / sampleRate, totalDuration)
    }

    var isPlaying: Bool { node.isPlaying && !didFinish }

    /// Start (or restart) playback from the beginning.
    func play() {
        if didFinish || !scheduled { restart() }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
        } catch {
            // Engine start can fail if no audio route is available; leave stopped.
        }
    }

    func pause() {
        node.pause()
    }

    func stop() {
        node.stop()
        engine.stop()
        scheduled = false
        didFinish = false
    }

    // MARK: - scheduling

    private func restart() {
        node.stop()
        didFinish = false
        engine.prepare()
        for (offset, segment) in segments.enumerated() {
            guard let buffer = Self.loadBuffer(url: segment.pcmURL, format: renderFormat),
                  buffer.frameLength > 0 else { continue }
            let isLast = offset == segments.count - 1
            if isLast {
                node.scheduleBuffer(buffer, at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.didFinish = true }
                }
            } else {
                node.scheduleBuffer(buffer, at: nil, options: [])
            }
        }
        scheduled = true
    }

    /// Read a flat little-endian `Float32` mono file into a PCM buffer.
    static func loadBuffer(url: URL, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let frames = data.count / MemoryLayout<Float>.stride
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress {
                channel.update(from: base, count: frames)
            }
        }
        return buffer
    }

    private static func commonFormat(_ format: PCMCommonFormat) -> AVAudioCommonFormat {
        switch format {
        case .pcmFormatFloat32, .otherFormat: return .pcmFormatFloat32
        case .pcmFormatFloat64: return .pcmFormatFloat64
        case .pcmFormatInt16: return .pcmFormatInt16
        case .pcmFormatInt32: return .pcmFormatInt32
        }
    }
}
