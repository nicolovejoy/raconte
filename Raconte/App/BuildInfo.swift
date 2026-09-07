import Foundation

/// When this binary was built, surfaced in the UI for smoke testing.
///
/// Exists because a wireless `devicectl` install gives no visible confirmation that the
/// build running on the phone is the one you just made. On 2026-08-02 that question came
/// up mid-pass and could only be answered by re-reading build-tool output on the mini,
/// which is exactly the kind of thing a smoke test should never depend on.
enum BuildInfo {

    /// The executable's mtime — Xcode writes it at link time, and both `devicectl` and
    /// Xcode preserve it through install onto the device.
    ///
    /// Info.plist is the fallback rather than the primary: it is rewritten by any
    /// post-processing step that touches the bundle, so it can drift later than the link.
    static let builtAt: Date? = {
        let manager = FileManager.default
        let candidates = [Bundle.main.executableURL,
                          Bundle.main.url(forResource: "Info", withExtension: "plist")]
        for url in candidates.compactMap({ $0 }) {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            if let date = attributes?[.modificationDate] as? Date { return date }
        }
        return nil
    }()

    /// Always Pacific, never the device's own zone.
    ///
    /// The stamp's only job is to be compared against when you hit build on the mini, and
    /// that is a Pacific wall clock. Rendering it in the phone's zone would silently
    /// break the comparison the moment the phone is somewhere else.
    ///
    /// Labelled "PT", not "PST": the zone is `America/Los_Angeles`, so the offset follows
    /// daylight saving. Half the year a hardcoded "PST" would be an hour off in print
    /// while the number beside it was right.
    ///
    /// `build N: <date>` (#141). N is `CFBundleVersion`, bumped in project.yml for every
    /// build the owner is handed — smoke or TestFlight — and described in
    /// `docs/builds.md`. The date keeps the link-time stamp: two builds can share N only
    /// by mistake, and when they do the time is what tells them apart.
    static func stampText(build: String?, builtAt: Date?) -> String {
        let number = build.flatMap { $0.isEmpty ? nil : $0 }
        let dateText: String? = builtAt.map { date in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
            formatter.dateFormat = "MMM d, h:mm a"
            return "\(formatter.string(from: date)) PT"
        }
        switch (number, dateText) {
        case let (n?, d?): return "build \(n): \(d)"
        case let (n?, nil): return "build \(n): date unavailable"
        case let (nil, d?): return "built \(d)"
        case (nil, nil): return "build date unavailable"
        }
    }

    /// `CFBundleVersion`, raw off the bundle — the one place this Info.plist key is
    /// read. `stamp` below reuses it (so it can't drift from what this returns), and
    /// T13's `AppServices` reuses it again for `ArchiveExporter`'s `build:` field via
    /// `AppVersion.displayString(short: nil, build:)`, which applies the same
    /// empty-is-absent normalization `stampText` already gives this value.
    static let buildNumber: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    static let stamp: String = stampText(build: buildNumber, builtAt: builtAt)
}
