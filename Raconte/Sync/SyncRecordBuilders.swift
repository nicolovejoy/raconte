import Foundation
import CloudKit

/// The CloudKit record types this app writes (design §2). Constants rather than inline
/// literals because the record type is part of the wire format: a typo here is a second,
/// silently-empty schema in the owner's container, not a compile error.
/// One per record kind, added as its builder lands (T6, T9, T10) rather than declared up
/// front — an unused constant is the kind of thing that quietly acquires a typo.
enum SyncRecordType {
    static let journal = "Journal"
}

/// The Journal record's field names (design §2, plus two as-built additions documented
/// on `SyncRecordBuilders.journalRecord`).
enum SyncJournalField {
    static let name = "name"
    static let createdAt = "createdAt"
    static let voiceLabels = "voiceLabels"
    static let cover = "cover"
    /// The journal's stored span (spec ruling 2, #70), additive like `voiceLabels`/`cover`
    /// above — a record built by a build that predates this field simply has no such key.
    static let span = "span"
    /// As-built: the per-field LWW stamps themselves. Design §2 says name/voiceLabels are
    /// "LWW per field" and §2 note 5 says `journals.json` grows a `modified` map — but the
    /// table never says how the stamps reach the other device. They have to: a receiver
    /// with no stamps cannot decide which side is newer, and would fall back to
    /// whole-record LWW, which is exactly the mutation this task's check rejects.
    static let modified = "modified"
    /// As-built: the origin device's `DeviceIdentity.stable()`. The locked tie-break rule
    /// is "equal stamps → lexicographically greater deviceID wins", which is unimplementable
    /// without knowing the remote's deviceID. See `JournalMerge` for the alternative that
    /// was rejected.
    static let deviceID = "deviceID"
}

/// Pure builders: local state in, `CKRecord` out. No IO beyond the caller-supplied file
/// URL for an asset, no engine, no store — which is what makes every field-coverage
/// assertion in `SyncJournalRecordTests` runnable with no CloudKit account and no server
/// traffic (`CKRecord` is constructible offline; only `CKSyncEngine` is not).
///
/// Later tasks add `entryRecord`/`audioRecord`/`liveLogRecord`/`revisionRecord`/
/// `markerStreamRecord` here (T6, T9, T10).
enum SyncRecordBuilders {

    /// The Journal record (design §2).
    ///
    /// `base` carries the archived CloudKit **system fields** for this record when this
    /// device has seen a server copy before — that is what makes the push carry the
    /// server's change tag, so CloudKit can detect a conflict instead of blindly
    /// clobbering. With no archive (never synced, or the disposable `sync/` cache was
    /// lost) a fresh record is built and the first save resolves as an ordinary conflict.
    ///
    /// Dictionary fields (`voiceLabels`, `modified`) travel as **sorted-keys JSON
    /// strings**, not as CloudKit dictionaries — CloudKit has no dictionary field type,
    /// and encoding them with the same `CaptureCoding.lineEncoder()` that writes
    /// `journals.json` means a stamp's millisecond resolution is identical on the wire
    /// and on disk. If it were not, a value that merely round-tripped through the cloud
    /// would compare as *newer* than itself and both devices would push forever.
    ///
    /// `voiceLabels` and `modified` are written even when empty (`"{}"`), unlike
    /// `Journal`'s own encoder which omits them: on disk, omitting keeps an untouched
    /// journal's bytes stable; on the wire, omitting a key from a record whose server
    /// copy has it would leave the server's stale value in place, so clearing every voice
    /// label would silently not sync.
    static func journalRecord(journal: Journal,
                              coverFileURL: URL?,
                              deviceID: String,
                              zoneID: CKRecordZone.ID,
                              base: CKRecord? = nil) -> CKRecord {
        let recordID = SyncCloudIdentifiers.recordID(.journal(id: journal.id), zoneID: zoneID)
        let record = base ?? CKRecord(recordType: SyncRecordType.journal, recordID: recordID)

        record[SyncJournalField.name] = journal.name
        record[SyncJournalField.createdAt] = journal.createdAt
        record[SyncJournalField.voiceLabels] = encodeJSON(journal.voiceLabels)
        record[SyncJournalField.modified] = encodeJSON(journal.modified ?? [:])
        record[SyncJournalField.deviceID] = deviceID
        // Assigned in BOTH directions on purpose. Clearing a cover has to travel as an
        // explicit nil — leaving the key untouched would let the server keep the old
        // asset forever, so "remove cover" would be the one journal edit that never
        // synced. Assigning nil removes the key, so an absent cover still produces a
        // record with no `cover` in `allKeys()`.
        record[SyncJournalField.cover] = coverFileURL.map { CKAsset(fileURL: $0) }
        // Same "assigned in both directions" rule as `cover` immediately above: a journal
        // with no span produces no `span` key at all, and clearing a span on a `base:`
        // record that had one removes the key — otherwise "I cleared the span" would be
        // the one journal edit that never syncs.
        record[SyncJournalField.span] = journal.span.map(encodeJSON)
        return record
    }

    /// Sorted-keys JSON, through the same encoder `journals.json` uses — so a stamp's
    /// resolution is identical on the wire and on disk, and two devices holding the same
    /// dictionary produce byte-identical strings rather than one that merely looks changed.
    static func encodeJSON<Value: Encodable>(_ value: [String: Value]) -> String {
        guard let data = try? CaptureCoding.lineEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            // Unreachable for `[String: String]` / `[String: Date]`; degrading to an empty
            // object rather than trapping keeps a bad value costing only that field.
            return "{}"
        }
        return string
    }

    /// Lenient by design, matching `Journal`'s own decoder rule for these two fields: a
    /// damaged `voiceLabels`/`modified` string must cost only that field, never the
    /// journal's identity. An absent field and an unparseable one both read as empty.
    static func decodeJSON<Value: Decodable>(_ string: String?) -> [String: Value] {
        guard let string, let data = string.data(using: .utf8),
              let value = try? CaptureCoding.decoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return value
    }

    /// The single-value sibling of `encodeJSON<Value>(_ value: [String: Value])` above, for
    /// fields that are not dictionaries — `span` is the first (#70). Same rule, same
    /// encoder: a value's wire representation must be byte-identical to its on-disk one, or
    /// a value that merely round-tripped through the cloud could compare as newer than
    /// itself.
    static func encodeJSON<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? CaptureCoding.lineEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// The single-value sibling of `decodeJSON<Value>(_ string: String?) -> [String: Value]`
    /// above. Returns `nil` rather than degrading to some default, because there is no safe
    /// default for an arbitrary value the way `[:]` is for a dictionary — the caller decides
    /// what an absent/damaged value means (for `span`, both read as "no span").
    static func decodeJSON<Value: Decodable>(_ string: String?) -> Value? {
        guard let string, let data = string.data(using: .utf8),
              let value = try? CaptureCoding.decoder().decode(Value.self, from: data) else {
            return nil
        }
        return value
    }
}
