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
    /// The span the PAPER journal covers (spec ruling 2). Additive and lenient, exactly
    /// like `voiceLabels` above: every registry on disk predates this field, and a
    /// damaged value must cost only the span, never the journal's id/name/createdAt.
    var span: JournalSpan?

    init(id: String, name: String, createdAt: Date, voiceLabels: [String: String] = [:],
         span: JournalSpan? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.voiceLabels = voiceLabels
        self.span = span
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
        // Additive and lenient, same reasoning as voiceLabels above. `JournalSpan.init(
        // from:)` also re-validates its inverted-bounds invariant on every decode (Task
        // 2) — a structurally valid span whose end < start throws from inside this same
        // `decodeIfPresent`, and `try?` treats that identically to malformed JSON: both
        // are "a damaged span", and a damaged span must cost only the span, never the
        // journal's identity.
        span = (try? container.decodeIfPresent(JournalSpan.self, forKey: .span)) ?? nil
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
        // Only when set, same "an untouched record's bytes don't change" rule the field
        // above follows.
        if let span {
            try container.encode(span, forKey: .span)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, voiceLabels, span
    }
}

enum JournalError: Error, Equatable {
    /// A name that is empty or only whitespace. Rejected at the model layer so the
    /// registry can never hold an unnameable journal.
    case emptyName
    case unknownJournal(String)
    case duplicateID(String)
    case invalidSpan
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
    @discardableResult
    mutating func insert(_ journal: Journal) throws -> Journal {
        guard !Self.normalized(journal.name).isEmpty else { throw JournalError.emptyName }
        guard !contains(id: journal.id) else { throw JournalError.duplicateID(journal.id) }
        var stored = journal
        stored.name = Self.normalized(journal.name)
        journals.append(stored)
        return stored
    }

    @discardableResult
    mutating func rename(id: String, to name: String) throws -> Journal {
        let trimmed = Self.normalized(name)
        guard !trimmed.isEmpty else { throw JournalError.emptyName }
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        journals[index].name = trimmed
        return journals[index]
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces a journal's voice labels wholesale (T7 Mark Voices, issue #56). Mirrors
    /// `rename`'s shape exactly: find-by-id-or-throw, mutate in place, hand back the
    /// stored result. Values are trimmed, and a value that is empty after trimming is
    /// dropped rather than stored as a blank label — the same "no label configured"
    /// state as never having set one.
    @discardableResult
    mutating func setVoiceLabels(id: String, labels: [String: String]) throws -> Journal {
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
        return journals[index]
    }

    /// Sets (or clears, via `nil`) a journal's stored span (spec ruling 2). Mirrors
    /// `setVoiceLabels`'s exact shape: find-by-id-or-throw, mutate in place, hand back
    /// the stored result. `JournalSpan`'s own initializer already refuses an inverted
    /// range, so there is nothing further to validate here.
    @discardableResult
    mutating func setSpan(id: String, span: JournalSpan?) throws -> Journal {
        guard let index = journals.firstIndex(where: { $0.id == id }) else {
            throw JournalError.unknownJournal(id)
        }
        journals[index].span = span
        return journals[index]
    }
}
