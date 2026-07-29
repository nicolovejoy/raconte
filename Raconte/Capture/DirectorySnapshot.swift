import Foundation

/// A read-only, stat-level view of one `captures/<id>/` directory (design §3
/// inputs). Built by a filesystem walk that reads only manifest/sidecar JSON and
/// file sizes — never PCM audio. `RecoveryPlanner` consumes this and nothing else,
/// so the whole recovery decision is a pure function of these values.
struct CaptureSnapshot: Equatable {
    var captureID: String
    /// Absolute directory for this capture (`.../captures/<id>/`).
    var directory: URL
    /// Parsed manifest, or nil if `manifest.json` is absent OR failed to decode.
    /// `manifestCorrupt` distinguishes the two; both are treated as "unknown state".
    var manifest: Manifest?
    /// True iff `manifest.json` exists on disk but could not be decoded.
    var manifestCorrupt: Bool
    /// True iff a stray `manifest.json.part` is present (crashed manifest write).
    var strayManifestPart: Bool
    /// Per-index segment file stats, sorted ascending by index.
    var segments: [SegmentFileStat]
    /// `final/recording.m4a` present with byte size > 0.
    var finalM4APresent: Bool
    /// `final/recording.m4a.part` present (interrupted finalize).
    var finalM4APartPresent: Bool
    /// Resolved capture format (manifest → any sidecar → default). Carries a
    /// filled-in `bytesPerFrame` so the planner needs no format defaults.
    var format: AudioFormatDescriptor

    init(captureID: String,
         directory: URL,
         manifest: Manifest?,
         manifestCorrupt: Bool = false,
         strayManifestPart: Bool = false,
         segments: [SegmentFileStat],
         finalM4APresent: Bool = false,
         finalM4APartPresent: Bool = false,
         format: AudioFormatDescriptor) {
        self.captureID = captureID
        self.directory = directory
        self.manifest = manifest
        self.manifestCorrupt = manifestCorrupt
        self.strayManifestPart = strayManifestPart
        self.segments = segments.sorted { $0.index < $1.index }
        self.finalM4APresent = finalM4APresent
        self.finalM4APartPresent = finalM4APartPresent
        self.format = format
    }
}

/// Stat-level facts about one segment index. Exactly one of `pcmByteSize` /
/// `partByteSize` is normally set; if both are set (a crash left both siblings),
/// the finalized `.pcm` wins.
struct SegmentFileStat: Equatable {
    var index: Int
    /// Byte size of `NNNNNN.pcm`, or nil if absent.
    var pcmByteSize: Int?
    /// Byte size of `NNNNNN.pcm.part`, or nil if absent.
    var partByteSize: Int?
    /// Decoded `NNNNNN.json`, or nil if the sidecar is absent/corrupt.
    var sidecar: SegmentSidecar?

    init(index: Int, pcmByteSize: Int? = nil, partByteSize: Int? = nil, sidecar: SegmentSidecar? = nil) {
        self.index = index
        self.pcmByteSize = pcmByteSize
        self.partByteSize = partByteSize
        self.sidecar = sidecar
    }
}

/// The whole `captures/` tree as stats. Input to `RecoveryPlanner.plan`.
struct DirectorySnapshot: Equatable {
    var capturesRoot: URL
    var captures: [CaptureSnapshot]
}

extension DirectorySnapshot {
    /// Default canonical format (design §1: Float32/mono/48k, non-interleaved)
    /// used when neither manifest nor any sidecar records one.
    static let defaultFormat = AudioFormatDescriptor(
        sampleRate: 48000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    /// Bytes per whole frame for a format. Prefers the explicit `bytesPerFrame`,
    /// else derives it from `commonFormat` × `channels`.
    static func bytesPerFrame(_ format: AudioFormatDescriptor) -> Int {
        if let bpf = format.bytesPerFrame, bpf > 0 { return bpf }
        let bytesPerSample: Int
        switch format.commonFormat {
        case .pcmFormatFloat64: bytesPerSample = 8
        case .pcmFormatFloat32, .pcmFormatInt32: bytesPerSample = 4
        case .pcmFormatInt16: bytesPerSample = 2
        case .otherFormat: bytesPerSample = 4
        }
        return bytesPerSample * max(1, format.channels)
    }

    /// A `format` with `bytesPerFrame` filled in, so downstream never re-derives it.
    static func normalizingBytesPerFrame(_ format: AudioFormatDescriptor) -> AudioFormatDescriptor {
        var f = format
        f.bytesPerFrame = bytesPerFrame(format)
        return f
    }
}

// MARK: - Real-filesystem gatherer

extension DirectorySnapshot {
    /// Walk `capturesRoot`, reading only JSON + file sizes (no PCM), and build a
    /// snapshot. Missing root → empty snapshot. Non-directory children are ignored.
    static func gather(capturesRoot: URL) -> DirectorySnapshot {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: capturesRoot.path) else {
            return DirectorySnapshot(capturesRoot: capturesRoot, captures: [])
        }
        let captures = ids.sorted().compactMap { id -> CaptureSnapshot? in
            let dir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return gatherCapture(captureID: id, directory: dir)
        }
        return DirectorySnapshot(capturesRoot: capturesRoot, captures: captures)
    }

    private static func gatherCapture(captureID: String, directory: URL) -> CaptureSnapshot {
        let fm = FileManager.default

        // Manifest.
        let manifestURL = SegmentLayout.manifestURL(captureDirectory: directory)
        var manifest: Manifest?
        var manifestCorrupt = false
        if fm.fileExists(atPath: manifestURL.path) {
            if let data = try? Data(contentsOf: manifestURL),
               let m = try? CaptureCoding.decoder().decode(Manifest.self, from: data) {
                manifest = m
            } else {
                manifestCorrupt = true
            }
        }
        let strayManifestPart =
            fm.fileExists(atPath: SegmentLayout.manifestPartURL(captureDirectory: directory).path)

        // Segments.
        let segmentsDir = SegmentLayout.segmentsDirectory(captureDirectory: directory)
        var byIndex: [Int: SegmentFileStat] = [:]
        var sidecarFormat: AudioFormatDescriptor?
        if let names = try? fm.contentsOfDirectory(atPath: segmentsDir.path) {
            for name in names {
                guard let index = SegmentLayout.segmentIndex(fromFileName: name) else { continue }
                var stat = byIndex[index] ?? SegmentFileStat(index: index)
                let url = segmentsDir.appendingPathComponent(name)
                let size = fileSize(url)
                if name.hasSuffix(".\(SegmentLayout.pcmExtension).\(SegmentLayout.partExtension)") {
                    stat.partByteSize = size
                } else if name.hasSuffix(".\(SegmentLayout.pcmExtension)") {
                    stat.pcmByteSize = size
                } else if name.hasSuffix(".\(SegmentLayout.sidecarExtension)") {
                    if let data = try? Data(contentsOf: url),
                       let sc = try? CaptureCoding.decoder().decode(SegmentSidecar.self, from: data) {
                        stat.sidecar = sc
                        if sidecarFormat == nil { sidecarFormat = sc.format }
                    }
                }
                byIndex[index] = stat
            }
        }
        let segments = byIndex.values.sorted { $0.index < $1.index }

        // Final.
        let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: directory)
        let finalM4APresent = fm.fileExists(atPath: m4aURL.path) && fileSize(m4aURL) > 0
        let finalM4APartPresent =
            fm.fileExists(atPath: SegmentLayout.finalRecordingPartURL(captureDirectory: directory).path)

        // Format resolution: manifest → sidecar → default; always bytesPerFrame-filled.
        let resolved = manifest?.format ?? sidecarFormat ?? defaultFormat
        let format = normalizingBytesPerFrame(resolved)

        return CaptureSnapshot(
            captureID: captureID, directory: directory,
            manifest: manifest, manifestCorrupt: manifestCorrupt,
            strayManifestPart: strayManifestPart,
            segments: segments,
            finalM4APresent: finalM4APresent, finalM4APartPresent: finalM4APartPresent,
            format: format)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
