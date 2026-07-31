import Foundation
import AVFoundation

/// Plays an ordered raw-PCM segment set gap-free.
///
/// Approach: AVAudioEngine + AVAudioPlayerNode. Each flat `Float32` mono `.pcm`
/// file is read into an `AVAudioPCMBuffer` at the canonical format and scheduled
/// in index order — `AVAudioPlayerNode` renders scheduled buffers back-to-back
/// with no gap, which is exactly the "concatenate the segments" semantics (design
/// §5). Simplest testable path: no muxing, no intermediate file.
///
/// Seeking (issue #6) re-schedules from the target frame: the segment containing
/// it is loaded from `frameOffset` onward, later segments whole.
@MainActor
final class SegmentPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let renderFormat: AVAudioFormat
    private let segments: [EncodableSegment]
    private let bytesPerFrame: Int

    let sampleRate: Double
    let totalFrames: Int

    private(set) var didFinish = false
    private var scheduled = false

    /// Frame the current schedule started at. The node's sample clock resets on
    /// `stop()`, so position is `seekBaseFrame + node sample time`.
    private var seekBaseFrame = 0

    /// Bumped on every re-schedule. `node.stop()` fires the pending
    /// `.dataPlayedBack` handlers of the buffers it discards, so the completion
    /// callback must ignore anything from a superseded schedule — otherwise the
    /// first seek instantly marks the capture finished.
    private var generation = 0

    init(segments: [EncodableSegment], format: AudioFormatDescriptor) {
        self.segments = segments.sorted { $0.index < $1.index }
        self.sampleRate = Double(max(1, format.sampleRate))
        self.totalFrames = segments.reduce(0) { $0 + max(0, $1.frameCount) }
        self.bytesPerFrame = DirectorySnapshot.bytesPerFrame(format)
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

    /// Node player time in seconds relative to the seek base, clamped to the
    /// total, or the finished total.
    var currentTime: TimeInterval {
        Double(currentFrame) / sampleRate
    }

    /// Global playback frame. Falls back to the seek base when nothing is
    /// rendering — so a seek while stopped/paused reads back the target, not 0.
    var currentFrame: Int {
        if didFinish { return totalFrames }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return seekBaseFrame }
        return min(seekBaseFrame + max(0, Int(playerTime.sampleTime)), totalFrames)
    }

    var isPlaying: Bool { node.isPlaying && !didFinish }

    /// Start (or restart) playback from the current position.
    func play() {
        if didFinish || !scheduled { schedule(fromFrame: didFinish ? 0 : seekBaseFrame) }
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
        generation &+= 1
        node.stop()
        engine.stop()
        scheduled = false
        didFinish = false
        seekBaseFrame = 0
    }

    // MARK: - seeking

    /// Re-schedule playback to start at `frame`, preserving play/pause state.
    func seek(toFrame frame: Int) {
        let target = PlaybackSeek.clampFrame(frame, totalFrames: totalFrames)
        let wasPlaying = node.isPlaying
        generation &+= 1
        node.stop()
        seekBaseFrame = target
        didFinish = false
        schedule(fromFrame: target)
        if wasPlaying {
            do {
                if !engine.isRunning { try engine.start() }
                node.play()
            } catch {
                // No route: stay scheduled but silent, same as `play()`.
            }
        }
    }

    // MARK: - scheduling

    /// Schedule every segment from `startFrame` to the end. The segment holding
    /// `startFrame` is loaded from its internal offset; the rest whole.
    private func schedule(fromFrame startFrame: Int) {
        node.stop()
        didFinish = false
        seekBaseFrame = PlaybackSeek.clampFrame(startFrame, totalFrames: totalFrames)
        engine.prepare()
        let gen = generation

        let plan = PlaybackSeek.plan(frameCounts: segments.map(\.frameCount),
                                     globalFrame: seekBaseFrame)
        // Past the last frame (or nothing to play): schedule nothing, stay ready.
        guard let plan else {
            scheduled = true
            return
        }

        var buffers: [AVAudioPCMBuffer] = []
        for position in plan.position..<segments.count {
            let segment = segments[position]
            let offset = position == plan.position ? plan.frameOffsetInSegment : 0
            guard let buffer = Self.loadBuffer(url: segment.pcmURL, format: renderFormat,
                                               bytesPerFrame: bytesPerFrame,
                                               frameOffset: offset,
                                               frameCount: max(0, segment.frameCount) - offset),
                  buffer.frameLength > 0 else { continue }
            buffers.append(buffer)
        }

        for (offset, buffer) in buffers.enumerated() {
            if offset == buffers.count - 1 {
                node.scheduleBuffer(buffer, at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, gen == self.generation else { return }
                        self.didFinish = true
                    }
                }
            } else {
                node.scheduleBuffer(buffer, at: nil, options: [])
            }
        }
        scheduled = true
    }

    /// Read a flat little-endian `Float32` mono file (or a frame range of one)
    /// into a PCM buffer. Byte math goes through `bytesPerFrame` rather than a
    /// hardcoded stride; the sample copy still assumes Float32 mono, matching
    /// what the capture path writes.
    static func loadBuffer(url: URL, format: AVAudioFormat, bytesPerFrame: Int,
                           frameOffset: Int = 0, frameCount: Int? = nil) -> AVAudioPCMBuffer? {
        guard bytesPerFrame > 0, frameOffset >= 0 else { return nil }
        // Mapped: a long capture is hundreds of MB and only a slice is needed.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let availableFrames = data.count / bytesPerFrame
        guard frameOffset < availableFrames else { return nil }
        var frames = availableFrames - frameOffset
        if let frameCount { frames = min(frames, max(0, frameCount)) }
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let byteStart = data.startIndex + frameOffset * bytesPerFrame
        let byteEnd = byteStart + frames * bytesPerFrame
        let samples = (byteEnd - byteStart) / MemoryLayout<Float>.stride
        data[byteStart..<byteEnd].withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress {
                channel.update(from: base, count: samples)
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
