import Foundation

/// M4 T11: every CloudKit record name that MAY exist for one captureID, beyond the
/// Entry record itself (design §5). The Entry's own CK delete cascades every child
/// record server-side via `.deleteSelf` (`entryRef`'s reference action on Audio/
/// Revision/LiveLog/MarkerStream builders), so this app never issues an explicit CK
/// delete for any of them — but each name's LOCAL ledger/system-fields bookkeeping
/// still has to be retired, and design §5's "the delete wins" rule means a not-yet-sent
/// SAVE for one of them must never reach the server once its parent is gone.
///
/// **Must be read BEFORE the capture directory is staged away.** Once
/// `StagedRemover.stage` renames it out of `captures/`, there is nothing left here to
/// enumerate — every caller collects this first, then stages/purges second.
///
/// Best-effort and permissive, never authoritative: a piece this device never actually
/// pushed (no ledger entry, no system fields, nothing ever queued) costs nothing extra
/// to "retire" — there was nothing there. The only failure mode this guards against is
/// a stale record surviving after its parent is gone, never a false success.
enum SyncRecordFamily {
    static func names(captureID: String, captureDirectory: URL) -> [SyncRecordName] {
        let fm = FileManager.default
        var names: [SyncRecordName] = []

        if fm.fileExists(atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory).path) {
            names.append(.audio(captureID: captureID))
        }
        if fm.fileExists(atPath: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory).path) {
            names.append(.liveLog(captureID: captureID))
        }
        if let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory) {
            names.append(contentsOf: chain.revisions.map { .revision(id: $0.id) })
        }
        // This device's own marker stream, if it ever wrote one.
        if fm.fileExists(atPath: SegmentLayout.markerLogURL(captureDirectory: captureDirectory).path) {
            names.append(.markerStream(captureID: captureID, deviceID: DeviceIdentity.stable()))
        }
        // Every FOREIGN marker stream materialized here by an earlier ingest
        // (`transcript/markers-<deviceID>.jsonl`).
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        if let entries = try? fm.contentsOfDirectory(atPath: transcriptDir.path) {
            for entry in entries.sorted() {
                guard let deviceID = SegmentLayout.foreignStreamDeviceID(fromFileName: entry) else { continue }
                names.append(.markerStream(captureID: captureID, deviceID: deviceID))
            }
        }
        return names
    }
}
