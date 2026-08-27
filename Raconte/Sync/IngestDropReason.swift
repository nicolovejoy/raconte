import CloudKit

/// The sub-cause behind an inbound-record ingest drop (#85). The compound guards in
/// `SyncRecordExchange`'s ingest paths used to log one undifferentiated "missing its
/// file or sha256 — ignored" line; a genuinely field-less server record and a CKAsset
/// whose download failed (asset present, `fileURL` nil) are different bugs with
/// different fixes, and without the record name in the line there is no way to tell
/// whether two launches dropped the same records or different ones. Pure over the
/// `CKRecord` so the table is unit-testable.
///
/// Returns nil when the record carries everything the guard requires — the guard
/// itself then binds the values and proceeds; these functions never bind on its behalf.
enum IngestDropReason {
    /// AudioAsset / LiveLog: `file` asset + `sha256` (mirrors `ingestAudio`/
    /// `ingestLiveLog`'s guard).
    static func childAsset(_ record: CKRecord) -> String? {
        guard let asset = record[SyncChildAssetField.file] as? CKAsset else { return "no file asset" }
        guard asset.fileURL != nil else { return "file asset has no fileURL — asset download failed" }
        guard record[SyncChildAssetField.sha256] as? String != nil else { return "no sha256" }
        return nil
    }

    /// Revision: `body` asset + `sha256` + an `entryRef` that parses as an Entry name
    /// (mirrors `ingestRevision`'s guard).
    static func revision(_ record: CKRecord) -> String? {
        guard let asset = record[SyncRevisionField.body] as? CKAsset else { return "no body asset" }
        guard asset.fileURL != nil else { return "body asset has no fileURL — asset download failed" }
        guard record[SyncChildAssetField.sha256] as? String != nil else { return "no sha256" }
        guard let entryRef = record[SyncChildAssetField.entryRef] as? CKRecord.Reference else { return "no entryRef" }
        guard case .entry? = SyncCloudIdentifiers.name(of: entryRef.recordID) else {
            return "entryRef does not name an Entry"
        }
        return nil
    }
}
