import Foundation

/// A named collection of entries ("1987 Journal", "Trip to France"). M3 plan: every
/// entry belongs to a journal, and capture happens in the context of the current one.
///
/// Journals live in one registry file rather than one directory each: they are a handful
/// of tiny records, they have no per-journal artifacts (entries are keyed by ULID and
/// filed by reference, not by location), and a directory-per-journal would tempt someone
/// into moving capture directories when a journal is renamed.
struct Journal: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// ULID. Immutable — renaming a journal keeps its id, so entries stay filed.
    var id: String
    var name: String
    var createdAt: Date
    /// Voice id -> display label ("bn" -> "Grandpa"). Additive (T7 Mark Voices, issue
    /// #56, owner ruling): the default render has NO label at all — voices are told
    /// apart by `VoiceDisplay.isItalic` (main voice) vs regular. A label is opt-in per
    /// journal, empty by default. See the house decoder rule below: this field decodes
    /// leniently, unlike `id`/`name`/`createdAt`.
    var voiceLabels: [String: String]

    /// M4 T1: per-field last-writer-wins substrate for CloudKit sync, the same
    /// convention as `EntryMetadata.modified`. Keys are `"name"`, `"voiceLabels"`,
    /// `"cover"` — the three journal attributes an owner can actually edit after
    /// creation (`id`/`createdAt` are immutable, so they need no stamp). `"cover"` is
    /// declared here ahead of any writer stamping it (the cover image itself lives
    /// outside this registry, at `journals/<id>/cover.jpg` via `JournalCoverStore`) —
    /// same "the field lands now so the format doesn't churn later" precedent as
    /// `EntryMetadata.trashedAt` before M3 T5 shipped trash.
    var modified: [String: Date]?

    init(id: String, name: String, createdAt: Date, voiceLabels: [String: String] = [:],
         modified: [String: Date]? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.voiceLabels = voiceLabels
        self.modified = modified
    }

    /// Hand-written per the house decoder rule (§11 of the M2 design): Swift's
    /// synthesized decoder **ignores property defaults**, so a defaulted property still
    /// throws `keyNotFound`. All three fields here are identity fields written at
    /// creation and never absent, so all three stay strict — a record missing one is not
    /// an older journal, it is a damaged registry, and silently substituting a default
    /// would file entries under a journal that isn't the one the user named. Fields
    /// *added later* decode with `decodeIfPresent`. Unknown keys are ignored, so a newer
    /// build's registry still opens here.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Additive and lenient, unlike the three identity fields above: every registry
        // on disk predates this field, and a damaged/garbage voiceLabels value must not
        // take the journal's id/name/createdAt down with it. Absent or garbage -> no
        // labels, which is also what every pre-feature journal actually has.
        voiceLabels = ((try? container.decodeIfPresent([String: String].self, forKey: .voiceLabels)) ?? nil) ?? [:]
        // Additive and lenient, same reasoning as `voiceLabels` immediately above: a
        // damaged sync-stamp map must cost only the stamps, never the journal's identity.
        modified = (try? container.decodeIfPresent([String: Date].self, forKey: .modified)) ?? nil
    }

    /// Hand-written per the same rule: the synthesized encoder does not know
    /// `voiceLabels`'s default is `[:]`, and would write `"voiceLabels":{}` into every
    /// journal — a byte-shape change for the common case that has no labels at all.
    /// `id`/`name`/`createdAt` are always written (identity fields, never optional
    /// omission); `voiceLabels` only when non-empty, so a journal nobody has labelled
    /// yet keeps producing exactly today's bytes.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        if !voiceLabels.isEmpty {
            try container.encode(voiceLabels, forKey: .voiceLabels)
        }
        // Only when non-nil AND non-empty, same "an untouched record's bytes don't
        // change" rule `voiceLabels` follows above.
        if let modified, !modified.isEmpty {
            try container.encode(modified, forKey: .modified)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, voiceLabels, modified
    }
}

enum JournalError: Error, Equatable {
    /// A name that is empty or only whitespace. Rejected at the model layer so the
    /// registry can never hold an unnameable journal.
    case emptyName
    case unknownJournal(String)
    case duplicateID(String)
}

/// The registry file's body, and the pure operations over it. Every rule about journals
/// lives here, in a value type, so the store is nothing but load/encode/replace.
struct JournalRegistry: Codable, Sendable, Equatable {
    /// Insertion order. Sorting is a presentation decision and is made in the UI.
    var journals: [Journal] = []

    init(journals: [Journal] = []) {
        self.journals = journals
    }

    /// `journals` is strict, deliberately.
    ///
    /// The tempting lenient reading — missing key ⇒ `[]` — is exactly issue #11's
    /// mistake in a new place: it turns "this file is not a registry" into "you have no
    /// journals", and the next `create` writes that emptiness back over the real one. An
    /// *absent* file is the only thing that legitimately means "no journals yet", and
    /// that is decided by the store, before any decoding happens.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journals = try container.decode([Journal].self, forKey: .journals)
    }

    func journal(id: String) -> Journal? {
        journals.first { $0.id == id }
    }

    func contains(id: String) -> Bool { journal(id: id) != nil }

    /// Appends a journal and returns what was actually stored — the name is normalized,
    /// so the argument is not it. Returning it saves the caller reaching back into
    /// `journals[count - 1]`, which is only correct while insert appends.
    ///
    /// Names are *not* required to be unique — two "1987 Journal"s are the user's
    /// business, and an id collision is the only thing that would corrupt filing.
    ///
    /// M4 T1: stamps `modified["name"]` — creation is the name's first write, same as
    /// every later `rename`. `now` defaults to `Date()` (the pure-function convention
    /// this file's other mutators don't currently need a clock for) so existing callers
    /// that construct a `Journal` directly and insert it — this type's own tests —
    /// keep compiling unchanged; `JournalStore.create` passes its injected clock.
    @discardableResult
    mutating func insert(_ journal: Journal, now: Date = Date()) throws -> Journal {
        guard !Self.normalized(journal.name).isEmpty else { throw JournalError.emptyName }
        guard !contains(id: journal.id) else { throw JournalError.duplicateID(journal.id) }
        var stored = journal
        stored.name = Self.normalized(journal.name)
        var modified = stored.modified ?? [:]
        modified["name"] = now
        stored.modified = modified
        journals.append(stored)
        return stored
    }

    /// M4 T1: stamps `modified["name"]` only — `voiceLabels`' own stamp (`setVoiceLabels`
    /// below) is untouched, the same per-field cardinality `EntryMetadataStore.update`
    /// pins for the sidecar.
    @discardableResult
    mutating func rename(id: String, to name: String, now: Date = Date()) throws -> Journal {
        let trimmed = Self.normalized(name)
        guard !trimmed.isEmpty else { throw JournalError.emptyName }
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        journals[index].name = trimmed
        var modified = journals[index].modified ?? [:]
        modified["name"] = now
        journals[index].modified = modified
        return journals[index]
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// M4 T5: stamps `modified["cover"]` and nothing else.
    ///
    /// The cover image itself lives outside this registry (`journals/<id>/cover.jpg`, via
    /// `JournalCoverStore`), but its LWW stamp has to live *in* it — that is the only
    /// place a per-field stamp map exists, and the stamp is what a receiving device reads
    /// to decide whether the fetched cover is newer than its own. Routing the stamp
    /// through this type rather than letting `JournalCoverStore` touch `journals.json`
    /// keeps the registry single-writer.
    ///
    /// Unknown journal throws, like every other mutator here: stamping a cover on a
    /// journal that does not exist would leave a stamp nothing can ever explain.
    @discardableResult
    mutating func stampCover(id: String, now: Date = Date()) throws -> Journal {
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        var modified = journals[index].modified ?? [:]
        modified["cover"] = now
        journals[index].modified = modified
        return journals[index]
    }

    /// M4 T5: writes a merged journal back **verbatim** — same values, same `modified`
    /// stamps, no clock read anywhere.
    ///
    /// Deliberately not `insert`/`rename`, and that is the whole reason this method
    /// exists: both of those stamp `modified` with the local clock. A journal arriving
    /// from another device already carries the stamps that say who wrote what and when,
    /// and restamping them with "now" would make this device look like the most recent
    /// writer of a name it merely received — after which a genuinely newer edit on a
    /// third device could never win. A sync-caused write is not an edit.
    ///
    /// Replaces by id when the journal is known, appends when it is not (design §6,
    /// "journals merged by id"). Insertion order is presentation-only, so appending an
    /// ingested journal at the end is the same non-decision `insert` already makes.
    mutating func applySyncMerge(_ journal: Journal) {
        if let index = journals.firstIndex(where: { $0.id == journal.id }) {
            journals[index] = journal
        } else {
            journals.append(journal)
        }
    }

    /// Replaces a journal's voice labels wholesale (T7 Mark Voices, issue #56). Mirrors
    /// `rename`'s shape exactly: find-by-id-or-throw, mutate in place, hand back the
    /// stored result. Values are trimmed, and a value that is empty after trimming is
    /// dropped rather than stored as a blank label — the same "no label configured"
    /// state as never having set one.
    /// M4 T1: stamps `modified["voiceLabels"]` only — `name`'s own stamp is untouched.
    @discardableResult
    mutating func setVoiceLabels(id: String, labels: [String: String], now: Date = Date()) throws -> Journal {
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        var trimmed: [String: String] = [:]
        for (voice, label) in labels {
            let value = Self.normalized(label)
            guard !value.isEmpty else { continue }
            trimmed[voice] = value
        }
        journals[index].voiceLabels = trimmed
        var modified = journals[index].modified ?? [:]
        modified["voiceLabels"] = now
        journals[index].modified = modified
        return journals[index]
    }
}
