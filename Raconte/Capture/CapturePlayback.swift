import Foundation
import AVFoundation
import Observation

/// What a capture can be played from (design §5): a verified/present finalized
/// `.m4a` is preferred; otherwise the ordered raw-PCM segment set; otherwise
/// nothing. Pure value — `PlayableSourceSelector` decides it from a snapshot.
enum PlayableSource: Equatable, Sendable {
    case finalizedM4A(URL)
    case rawSegments([EncodableSegment], format: AudioFormatDescriptor)
    case none
}

/// Pure decision + duration logic for playback (design §6: testable without
/// hardware). No decode — raw duration comes from sidecars/file sizes; the m4a
/// duration is decoded by `CapturePlayback` at load.
enum PlayableSourceSelector {
    /// Prefer a present finalized `.m4a` (a full `.m4a`, never a `.part`, exists
    /// only after finalize verified it — design §5). Else raw segments if they
    /// hold any frames. Else `.none`.
    static func select(_ snapshot: CaptureSnapshot) -> PlayableSource {
        if snapshot.finalM4APresent {
            return .finalizedM4A(SegmentLayout.finalRecordingURL(captureDirectory: snapshot.directory))
        }
        let segments = rawSegments(snapshot)
        return frameTotal(of: segments) > 0
            ? .rawSegments(segments, format: snapshot.format)
            : PlayableSource.none
    }

    /// Finalized (`.pcm`, not `.part`) segments in index order, with frame counts
    /// from sidecars where present and file-size fallback otherwise (mirrors the
    /// finalizer's reader so playback and encode agree on the frame chain).
    static func rawSegments(_ snapshot: CaptureSnapshot) -> [EncodableSegment] {
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: snapshot.directory)
        let bytesPerFrame = DirectorySnapshot.bytesPerFrame(snapshot.format)
        var result: [EncodableSegment] = []
        var running = 0
        for stat in snapshot.segments.sorted(by: { $0.index < $1.index }) {
            guard let byteSize = stat.pcmByteSize else { continue }
            let frameCount = stat.sidecar?.frameCount
                ?? SegmentLayout.wholeFrameCount(fileSize: byteSize, bytesPerFrame: bytesPerFrame)
            let startOffset = stat.sidecar?.startFrameOffset ?? running
            running = startOffset + frameCount
            result.append(EncodableSegment(
                index: stat.index, startFrameOffset: startOffset,
                frameCount: frameCount,
                pcmURL: SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: stat.index)))
        }
        return result
    }

    static func frameTotal(of segments: [EncodableSegment]) -> Int {
        segments.reduce(0) { $0 + max(0, $1.frameCount) }
    }

    /// Total raw duration in seconds from sidecars/file sizes (no PCM decode).
    static func rawDurationSeconds(_ snapshot: CaptureSnapshot) -> Double {
        Double(frameTotal(of: rawSegments(snapshot))) / Double(max(1, snapshot.format.sampleRate))
    }
}

/// Top-level playback for one capture (design §5, T9). Decides the playable
/// source, exposes transport (`play`/`pause`/`stop`), and observable position /
/// duration for SwiftUI. Finished entries play their `.m4a` via `AVAudioPlayer`;
/// un-finalized recovered captures play their raw segments via `SegmentPlayer`.
@MainActor
@Observable
final class CapturePlayback {
    let source: PlayableSource
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var m4aPlayer: AVAudioPlayer?
    private var segmentPlayer: SegmentPlayer?
    private var ticker: Task<Void, Never>?

    init(source: PlayableSource) {
        self.source = source
        load()
    }

    /// Build from a gathered snapshot (pure source selection).
    convenience init(snapshot: CaptureSnapshot) {
        self.init(source: PlayableSourceSelector.select(snapshot))
    }

    /// Build by walking `capturesRoot` for `captureID` (reads disk once at init).
    convenience init(capturesRoot: URL, captureID: String) {
        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
            .captures.first { $0.captureID == captureID }
        if let snapshot {
            self.init(snapshot: snapshot)
        } else {
            self.init(source: .none)
        }
    }

    var hasAudio: Bool {
        if case .none = source { return false }
        return true
    }

    // MARK: - transport

    func play() {
        guard hasAudio, !isPlaying else { return }
        switch source {
        case .finalizedM4A:
            m4aPlayer?.play()
        case .rawSegments:
            segmentPlayer?.play()
        case .none:
            return
        }
        isPlaying = true
        startTicking()
    }

    func pause() {
        guard isPlaying else { return }
        m4aPlayer?.pause()
        segmentPlayer?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func stop() {
        m4aPlayer?.stop()
        m4aPlayer?.currentTime = 0
        segmentPlayer?.stop()
        isPlaying = false
        currentTime = 0
        ticker?.cancel()
    }

    // MARK: - loading

    private func load() {
        switch source {
        case .finalizedM4A(let url):
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                m4aPlayer = player
                duration = player.duration
            }
        case .rawSegments(let segments, let format):
            let player = SegmentPlayer(segments: segments, format: format)
            segmentPlayer = player
            duration = player.totalDuration
        case .none:
            duration = 0
        }
    }

    // MARK: - position ticking

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.tick()
            }
        }
    }

    private func tick() {
        switch source {
        case .finalizedM4A:
            guard let player = m4aPlayer else { return }
            currentTime = player.currentTime
            if !player.isPlaying {
                isPlaying = false
                currentTime = duration
            }
        case .rawSegments:
            guard let player = segmentPlayer else { return }
            currentTime = player.currentTime
            if player.didFinish {
                isPlaying = false
                currentTime = duration
            }
        case .none:
            isPlaying = false
        }
    }
}
