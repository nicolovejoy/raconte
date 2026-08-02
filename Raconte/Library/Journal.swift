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

    init(id: String, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
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

    /// Appends a journal. Names are *not* required to be unique — two "1987 Journal"s
    /// are the user's business, and an id collision is the only thing that would corrupt
    /// filing.
    mutating func insert(_ journal: Journal) throws {
        guard !Self.normalized(journal.name).isEmpty else { throw JournalError.emptyName }
        guard !contains(id: journal.id) else { throw JournalError.duplicateID(journal.id) }
        var stored = journal
        stored.name = Self.normalized(journal.name)
        journals.append(stored)
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
}
