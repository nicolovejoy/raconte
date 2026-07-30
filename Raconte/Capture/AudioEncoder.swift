import Foundation
import AVFoundation

/// One finalized segment ready to feed the encoder, in index order (design §5).
/// `pcmURL` is the flat `Float32` mono `.pcm` file; `frameCount`/`startFrameOffset`
/// come from the sidecar so contiguity is checkable without decoding.
struct EncodableSegment: Sendable, Equatable {
    var index: Int
    var startFrameOffset: Int
    var frameCount: Int
    var pcmURL: URL
}

/// Outcome of an encode pass: where the `.m4a.part` was written and how many
/// PCM frames were fed (the contiguous total the encoder actually encoded).
struct EncodeResult: Sendable, Equatable {
    var outputURL: URL
    var encodedFrameCount: Int
}

/// Raw facts decoded from a produced `.m4a` (design §5 verification). The
/// tolerance/pass decision lives in `FinalizerWorker`, not here, so a fake
/// encoder can drive every verify branch.
struct VerifyResult: Sendable, Equatable {
    /// The container opened and decoded without error.
    var decodable: Bool
    /// Decoded frame length at the file's own sample rate.
    var decodedFrameCount: Int
    /// True iff any decoded sample exceeded the silence floor.
    var nonSilent: Bool
}

/// PCM-segments-in, playable-`.m4a`-out, behind a protocol so `FinalizerWorker`
/// is tested with a fake and the real AVAssetWriter path is validated by a
/// round-trip integration test (design §6). `Sendable`: the worker is an actor
/// and hops to the encoder across an await.
protocol AudioEncoder: Sendable {
    /// Encode the ordered contiguous `segments` into a mono AAC-LC file at
    /// `outputPartURL` (the `.m4a.part`; the worker renames it after verify).
    func encode(segments: [EncodableSegment],
                format: AudioFormatDescriptor,
                to outputPartURL: URL) async throws -> EncodeResult

    /// Decode `m4aURL` and report decodability, frame length, and non-silence.
    func verify(m4aURL: URL) async throws -> VerifyResult
}

enum AudioEncoderError: Error, Equatable {
    case noContiguousSegments
    case writerSetupFailed(String)
    case sampleBufferCreationFailed(OSStatus)
    case appendFailed(String)
    case finishFailed(String)
    case notDecodable
}

/// Real `AudioEncoder` (design §5 decision: AVAssetWriter with an AAC-LC input).
///
/// An `actor` so all the non-Sendable AVFoundation objects stay isolated under
/// Swift 6 strict concurrency; the worker calls it serially. PCM is read one
/// segment at a time (bounded RAM) and wrapped into `CMSampleBuffer`s from a flat
/// `Float32` mono block buffer (VERIFY §4). AAC settings: `kAudioFormatMPEG4AAC`,
/// mono, the capture sample rate (so decoded frames line up with raw frames), and
/// `AVEncoderBitRateKey` 80_000.
actor AVAssetWriterAudioEncoder: AudioEncoder {
    /// Frames per fed sample buffer — bounds allocation and keeps append pacing sane.
    private static let framesPerBuffer = 16_384
    /// AAC target bitrate (design §5: ~80 kbps mono).
    static let bitRate = 80_000
    /// Below this |sample| the file is treated as silent (design §5 non-silent check).
    static let silenceFloor: Float = 1e-4

    func encode(segments: [EncodableSegment],
                format: AudioFormatDescriptor,
                to outputPartURL: URL) async throws -> EncodeResult {
        guard !segments.isEmpty else { throw AudioEncoderError.noContiguousSegments }

        let sampleRate = Double(format.sampleRate)
        // Fresh output — never append to a stale `.part`.
        try? FileManager.default.removeItem(at: outputPartURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputPartURL, fileType: .m4a)
        } catch {
            throw AudioEncoderError.writerSetupFailed(String(describing: error))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: Self.bitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw AudioEncoderError.writerSetupFailed("cannot add audio input")
        }
        writer.add(input)

        let sourceFormat = try Self.makeFloat32MonoFormatDescription(sampleRate: sampleRate)

        guard writer.startWriting() else {
            throw AudioEncoderError.writerSetupFailed(
                writer.error.map { String(describing: $0) } ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        var framesEmitted: Int64 = 0
        let bytesPerFrame = DirectorySnapshot.bytesPerFrame(format)

        for segment in segments {
            guard let handle = try? FileHandle(forReadingFrom: segment.pcmURL) else { continue }
            defer { try? handle.close() }
            let chunkBytes = Self.framesPerBuffer * bytesPerFrame
            while true {
                let data = handle.readData(ofLength: chunkBytes)
                if data.isEmpty { break }
                let frames = data.count / bytesPerFrame
                if frames == 0 { break }
                let aligned = frames * bytesPerFrame
                let payload = aligned == data.count ? data : data.prefix(aligned)

                let sampleBuffer = try Self.makeSampleBuffer(
                    pcm: payload, frameCount: frames, formatDescription: sourceFormat,
                    sampleRate: sampleRate, presentationFrame: framesEmitted)

                try await Self.appendWhenReady(input: input, sampleBuffer: sampleBuffer, writer: writer)
                framesEmitted += Int64(frames)
            }
        }

        input.markAsFinished()
        try await Self.finish(writer: writer)

        return EncodeResult(outputURL: outputPartURL, encodedFrameCount: Int(framesEmitted))
    }

    func verify(m4aURL: URL) async throws -> VerifyResult {
        guard let file = try? AVAudioFile(forReading: m4aURL) else {
            return VerifyResult(decodable: false, decodedFrameCount: 0, nonSilent: false)
        }
        let format = file.processingFormat
        let decodedFrames = Int(file.length)
        var nonSilent = false
        let capacity: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            if !nonSilent, let channels = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                outer: for c in 0..<Int(format.channelCount) {
                    let p = channels[c]
                    for f in 0..<frames where abs(p[f]) > Self.silenceFloor {
                        nonSilent = true
                        break outer
                    }
                }
            }
        }
        return VerifyResult(decodable: true, decodedFrameCount: decodedFrames, nonSilent: nonSilent)
    }

    // MARK: - CoreMedia construction (VERIFY §4)

    /// ASBD for packed 32-bit float, mono LPCM. For one channel interleaved and
    /// non-interleaved are byte-identical, so a plain packed layout suffices.
    private static func makeFloat32MonoFormatDescription(sampleRate: Double) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else {
            throw AudioEncoderError.sampleBufferCreationFailed(status)
        }
        return formatDescription
    }

    private static func makeSampleBuffer(pcm: Data, frameCount: Int,
                                         formatDescription: CMAudioFormatDescription,
                                         sampleRate: Double,
                                         presentationFrame: Int64) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let byteCount = pcm.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw AudioEncoderError.sampleBufferCreationFailed(status)
        }
        status = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw AudioEncoderError.sampleBufferCreationFailed(status)
        }

        let pts = CMTime(value: presentationFrame, timescale: CMTimeScale(sampleRate))
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw AudioEncoderError.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }

    // MARK: - non-realtime pacing (avoids a cross-thread @Sendable callback)

    private static func appendWhenReady(input: AVAssetWriterInput,
                                        sampleBuffer: CMSampleBuffer,
                                        writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw AudioEncoderError.appendFailed(
                    writer.error.map { String(describing: $0) } ?? "writer failed")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.append(sampleBuffer) else {
            throw AudioEncoderError.appendFailed(
                writer.error.map { String(describing: $0) } ?? "append rejected")
        }
    }

    private static func finish(writer: AVAssetWriter) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw AudioEncoderError.finishFailed(
                writer.error.map { String(describing: $0) } ?? "status \(writer.status.rawValue)")
        }
    }
}
