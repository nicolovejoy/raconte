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

    /// Tap buffer request, in frames. 4800 @ 48 kHz ≈ 100 ms — the low end of
    /// `AVAudioNode.h`'s documented supported range [100 ms, 400 ms] (the old 4096 was
    /// ~85 ms, below it). It's a hint; the delivered `frameLength` is treated as
    /// authoritative regardless.
    static let tapBufferSize: AVAudioFrameCount = 4800
    /// Headroom multiplier for the preallocated converter-output buffer: the tap may
    /// hand us more frames than requested, so size the reused scratch buffer above the
    /// request. A callback exceeding even this falls back to a one-off allocation.
    private static let scratchHeadroom: AVAudioFrameCount = 2

    private let engine = AVAudioEngine()
    private var processor: TapProcessor?

    private(set) var isRunning = false

    /// Canonical format frames are delivered in, once running.
    var captureFormat: AVAudioFormat? { processor?.outputFormat }

    /// Installs the tap at the hardware input format and starts the engine.
    /// Call from a single context (the coordinator); safe to call once per capture.
    ///
    /// `matching`: when non-nil, output is pinned to this canonical format instead of
    /// the hardware rate — the resume-after-device-switch path, where the new device's
    /// rate may differ but the capture's segments must stay at one rate (§1). The tap
    /// then resamples (the only path that does; initial starts always adopt hardware).
    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor? = nil,
               onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputFormat
        }
        let proc = TapProcessor(inputFormat: inputFormat,
                                outputFormat: canonical?.avAudioFormat,
                                sink: sink, onLevel: onLevel,
                                maxFrameCapacity: Self.tapBufferSize * Self.scratchHeadroom)
        // bufferSize is a hint; delivered frameLength may differ — the scratch buffer is
        // sized with headroom and the process() path falls back to a one-off alloc if a
        // callback still exceeds it (never drops audio).
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
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

extension AudioFormatDescriptor {
    /// AVAudioFormat equivalent, for pinning a resumed engine to the capture's
    /// canonical format. `otherFormat` maps to Float32 (the canonical sample type).
    var avAudioFormat: AVAudioFormat? {
        let common: AVAudioCommonFormat
        switch commonFormat {
        case .pcmFormatFloat32, .otherFormat: common = .pcmFormatFloat32
        case .pcmFormatFloat64: common = .pcmFormatFloat64
        case .pcmFormatInt16: common = .pcmFormatInt16
        case .pcmFormatInt32: common = .pcmFormatInt32
        }
        return AVAudioFormat(commonFormat: common,
                             sampleRate: Double(sampleRate),
                             channels: AVAudioChannelCount(max(1, channels)),
                             interleaved: interleaved)
    }
}

/// Per-capture tap worker. Holds the reused converter + a preallocated converter-output
/// buffer and the canonical format, converts each tap buffer to mono `Float32` at the
/// hardware rate, measures RMS, and forwards a `PCMChunk`.
///
/// `@unchecked Sendable`: the shared mutable state this hides is the reused
/// `AVAudioConverter` (its internal streaming buffers) and the preallocated output buffer
/// (`scratch`), both mutated on every `process(_:)` call. Safety rests on `process(_:)`
/// being invoked serially: `AVAudioEngine` calls a bus's tap block one buffer at a time on
/// a single audio thread. This is a de-facto contract (observed, not documented by Apple),
/// so no second caller of `process(_:)` may ever be added — a concurrent second caller
/// would race the converter and scratch buffer. The type touches no filesystem —
/// persistence is entirely the sink's job (no-disk-on-tap-thread by construction).
final class TapProcessor: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let sink: PCMSink
    private let onLevel: (@Sendable (Float) -> Void)?
    private let converter: AVAudioConverter?
    /// Output frames produced per input frame (1 unless resuming onto a device whose
    /// rate differs from the capture's canonical rate).
    private let rateRatio: Double
    private let ratesDiffer: Bool
    /// Reused converter-output buffer, allocated once at init (finding #1: no heap
    /// allocation per realtime tap callback → no priority-inversion / dropped-buffer risk).
    /// `nil` on the passthrough path (input already canonical, no conversion). A callback
    /// whose `frameLength` exceeds this capacity falls back to a one-off allocation in
    /// `process(_:)` rather than dropping audio (the rare path).
    private let scratch: AVAudioPCMBuffer?

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat? = nil,
         sink: PCMSink, onLevel: (@Sendable (Float) -> Void)? = nil,
         maxFrameCapacity: AVAudioFrameCount = AudioEngineRecorder.tapBufferSize * 2) {
        // VERIFY #2: store at the HARDWARE sample rate (no resample on the tap thread);
        // only downmix to mono, non-interleaved Float32. One deliberate exception: a
        // resume onto a different-rate device pins `outputFormat` to the capture's
        // canonical format, and the converter resamples so the segment chain keeps a
        // single rate (§1 — manifest/sidecars/playback/finalize all assume one).
        let output = outputFormat
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: inputFormat.sampleRate,
                             channels: 1,
                             interleaved: false)!
        self.outputFormat = output
        self.sink = sink
        self.onLevel = onLevel
        self.rateRatio = output.sampleRate / inputFormat.sampleRate
        self.ratesDiffer = output.sampleRate != inputFormat.sampleRate
        if inputFormat == output {
            self.converter = nil
            self.scratch = nil
        } else {
            self.converter = AVAudioConverter(from: inputFormat, to: output)
            // Preallocated once; reused across every tap callback. Scaled up when
            // resampling produces more output frames than input frames.
            let capacity = AVAudioFrameCount((Double(maxFrameCapacity) * max(1, rateRatio)).rounded(.up))
            self.scratch = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: max(capacity, 1))
        }
    }

    /// Output frames needed for `frames` input frames (identity unless resampling).
    private func requiredOutputFrames(for frames: AVAudioFrameCount) -> AVAudioFrameCount {
        ratesDiffer ? AVAudioFrameCount((Double(frames) * rateRatio).rounded(.up)) : frames
    }

    func process(_ inputBuffer: AVAudioPCMBuffer) {
        let mono: AVAudioPCMBuffer
        if let converter {
            let needed = requiredOutputFrames(for: inputBuffer.frameLength)
            let out: AVAudioPCMBuffer
            if let scratch, scratch.frameCapacity >= needed {
                out = scratch                      // common path: no allocation
            } else {
                // Rare: callback exceeds the preallocated capacity — allocate a one-off
                // buffer rather than drop audio.
                guard let fresh = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: max(needed, 1)) else { return }
                out = fresh
            }
            if ratesDiffer {
                // Rate conversion requires the streaming API. `.noDataNow` (not
                // `.endOfStream`) keeps the converter alive across callbacks; the few
                // frames it holds back internally are delivered on the next call.
                out.frameLength = 0
                var fed = false
                var convertError: NSError?
                let status = converter.convert(to: out, error: &convertError) { _, outStatus in
                    if fed { outStatus.pointee = .noDataNow; return nil }
                    fed = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                guard status == .haveData || status == .inputRanDry else { return }
            } else {
                guard (try? converter.convert(to: out, from: inputBuffer)) != nil else { return }
            }
            mono = out
        } else {
            mono = inputBuffer
        }
        guard let channel = mono.floatChannelData, mono.frameLength > 0 else { return }
        let n = Int(mono.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: n)
        onLevel?(AudioEngineRecorder.rms(samples))
        // Single allocating copy straight from the converter output (finding #1): no
        // intermediate Array/buffer. Byte-identical to the prior `Data(buffer:)`.
        let data = Data(bytes: channel[0], count: n * MemoryLayout<Float>.stride)
        sink.receive(PCMChunk(data: data,
                              frameCount: AVAudioFrameCount(n),
                              sampleRate: outputFormat.sampleRate))
    }
}
