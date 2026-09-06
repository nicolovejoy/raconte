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
    /// `ingestLiveLog`'s now-sequential guards — each sub-cause here is one of those
    /// guards' own literal park reasons, not re-derived).
    static func childAsset(_ record: CKRecord) -> String? {
        guard let asset = record[SyncChildAssetField.file] as? CKAsset else { return "missing file asset" }
        guard asset.fileURL != nil else { return "asset has no local fileURL" }
        guard record[SyncChildAssetField.sha256] as? String != nil else { return "missing sha256 field" }
        return nil
    }

    /// Image: `file` asset + `sha256` — same field keys as `childAsset` (`RemoteImageFields`
    /// reads through `SyncChildAssetField`, not an image-specific pair), mirrors
    /// `ingestImage`'s sequential guards.
    static func image(_ record: CKRecord) -> String? {
        guard let asset = record[SyncChildAssetField.file] as? CKAsset else { return "missing file asset" }
        guard asset.fileURL != nil else { return "asset has no local fileURL" }
        guard record[SyncChildAssetField.sha256] as? String != nil else { return "missing sha256 field" }
        return nil
    }

    /// Revision: `body` asset + `sha256` + an `entryRef` that parses as an Entry name
    /// (mirrors `ingestRevision`'s sequential guards).
    static func revision(_ record: CKRecord) -> String? {
        guard let asset = record[SyncRevisionField.body] as? CKAsset else { return "missing file asset" }
        guard asset.fileURL != nil else { return "asset has no local fileURL" }
        guard record[SyncChildAssetField.sha256] as? String != nil else { return "missing sha256 field" }
        guard let entryRef = record[SyncChildAssetField.entryRef] as? CKRecord.Reference else {
            return "missing entryRef"
        }
        guard case .entry? = SyncCloudIdentifiers.name(of: entryRef.recordID) else {
            return "entryRef is not an entry name"
        }
        return nil
    }
}
