import Foundation
import AVFoundation

/// Cross-platform (iOS + macOS) engine driver: installs an input tap at the hardware
/// format, downmixes to the canonical mono `Float32` segment format at the hardware sample
/// rate, computes an RMS level for the meter, and feeds PCM to a `PCMSink`.
///
/// The tap closure runs on a realtime audio thread and does NO disk I/O — it only converts,
/// measures, and hands bytes to the sink (which enqueues them elsewhere). Session activation,
/// permission, and interruption handling live in `AudioSessionController` (T5); this type is
/// pure engine + tap and is shared unchanged across platforms.
final class AudioEngineRecorder {
    enum RecorderError: Error {
        case noInputFormat
        case engineStartFailed(any Error)
    }

    private let engine = AVAudioEngine()
    private var processor: TapProcessor?

    private(set) var isRunning = false

    /// Canonical format frames are delivered in, once running.
    var captureFormat: AVAudioFormat? { processor?.outputFormat }

    /// Installs the tap at the hardware input format and starts the engine.
    /// Call from a single context (the coordinator); safe to call once per capture.
    func start(sink: PCMSink, onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputFormat
        }
        let proc = TapProcessor(inputFormat: inputFormat, sink: sink, onLevel: onLevel)
        // bufferSize is a hint; delivered frameLength may differ — we size per buffer.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            proc.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }
        processor = proc
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor = nil
        isRunning = false
    }

    /// Linear RMS over mono samples, range 0...1. Pure; used by the meter and unit-tested.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer(rms)
    }
}

/// Per-capture tap worker. Holds the preallocated converter and canonical format, converts
/// each tap buffer to mono `Float32` at the hardware rate, measures RMS, and forwards a
/// `PCMChunk`.
///
/// `@unchecked Sendable`: `AVAudioEngine` guarantees the tap block is invoked serially on a
/// single thread, so the mutable conversion scratch is never touched concurrently. The type
/// touches no filesystem — persistence is entirely the sink's job (no-disk-on-tap-thread by
/// construction).
final class TapProcessor: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let sink: PCMSink
    private let onLevel: (@Sendable (Float) -> Void)?
    private let converter: AVAudioConverter?

    init(inputFormat: AVAudioFormat, sink: PCMSink, onLevel: (@Sendable (Float) -> Void)? = nil) {
        // VERIFY #2: store at the HARDWARE sample rate (no resample on the tap thread);
        // only downmix to mono, non-interleaved Float32. Resampling, if ever wanted, is
        // deferred to finalize (the sidecar records the rate).
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: inputFormat.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        self.outputFormat = output
        self.sink = sink
        self.onLevel = onLevel
        self.converter = inputFormat == output ? nil : AVAudioConverter(from: inputFormat, to: output)
    }

    func process(_ inputBuffer: AVAudioPCMBuffer) {
        let mono: AVAudioPCMBuffer
        if let converter {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: max(inputBuffer.frameLength, 1)),
                  (try? converter.convert(to: out, from: inputBuffer)) != nil else { return }
            mono = out
        } else {
            mono = inputBuffer
        }
        guard let channel = mono.floatChannelData, mono.frameLength > 0 else { return }
        let n = Int(mono.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: n)
        onLevel?(AudioEngineRecorder.rms(samples))
        sink.receive(PCMChunk(data: Data(buffer: samples),
                              frameCount: AVAudioFrameCount(n),
                              sampleRate: outputFormat.sampleRate))
    }
}
