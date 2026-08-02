import Foundation

/// The one-key store behind `CurrentJournal`, abstracted so tests never touch the real
/// user defaults database (which is process-wide, survives the test run, and would make
/// two tests in the same suite observe each other).
protocol JournalPreferenceStore: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// `UserDefaults` is documented as thread-safe but is not marked `Sendable`, hence the
/// `@unchecked` — the wrapper also keeps the protocol free of a Foundation conformance
/// and names the one key we own.
struct UserDefaultsJournalPreferenceStore: JournalPreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func setString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Which journal new captures are filed into.
///
/// In `UserDefaults`, not the registry file: it is a per-device UI preference, not
/// journal data. Putting it in the registry would sync it (M3 T9) and make the Mac's
/// current journal follow the phone's, which is not what "current" means.
///
/// The stored id is validated against the registry on read rather than on write. A
/// journal can vanish between launches (a future delete, or a sync that hasn't landed
/// yet), and a dangling id must degrade to "no current journal" instead of filing entries
/// under a journal that does not exist.
struct CurrentJournal: Sendable {
    static let defaultsKey = "org.pianohouseproject.raconte.currentJournalID"

    private let store: any JournalPreferenceStore
    private let key: String

    init(store: any JournalPreferenceStore = UserDefaultsJournalPreferenceStore(),
         key: String = CurrentJournal.defaultsKey) {
        self.store = store
        self.key = key
    }

    /// The raw stored id, whether or not it still resolves.
    var storedID: String? {
        guard let value = store.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    func select(_ journalID: String?) {
        store.setString(journalID, forKey: key)
    }

    func select(_ journal: Journal) { select(journal.id) }

    /// The current journal if it still exists in `registry`, else nil. Does **not**
    /// clear the stored id: a journal missing because sync hasn't arrived yet should come
    /// back when it does, and erasing the preference here would make that unrecoverable.
    func resolve(in registry: JournalRegistry) -> Journal? {
        guard let id = storedID else { return nil }
        return registry.journal(id: id)
    }
}

/// In-memory `JournalPreferenceStore` for tests and previews.
final class InMemoryJournalPreferenceStore: JournalPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init(values: [String: String] = [:]) { self.values = values }

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func setString(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
