import Foundation

/// #89: the About page's version+build string, e.g. "1.0 (7)". Pure core + thin
/// bundle shell, per the repo's testable-core convention (`CloudKitEnvironment.parse`
/// / `detectFromBundle` is the adjacent precedent).
enum AppVersion {

    /// Pure core. Empty is as absent as nil: a malformed Info.plist must degrade to
    /// a readable string, never crash and never render "1.0 ()".
    static func displayString(short: String?, build: String?) -> String {
        let short = short.flatMap { $0.isEmpty ? nil : $0 }
        let build = build.flatMap { $0.isEmpty ? nil : $0 }
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil):    return short
        case let (nil, build?):    return build
        case (nil, nil):           return "unknown"
        }
    }

    /// Thin shell: CFBundleShortVersionString is the marketing version ("1.0"),
    /// CFBundleVersion the build number ("7") — the pair TestFlight shows as 1.0 (7).
    static func current(bundle: Bundle = .main) -> String {
        displayString(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// T13: `CFBundleShortVersionString` alone, normalized through the same
    /// empty-is-absent rule `displayString` already applies to it — the source
    /// `AppServices` reads for `ArchiveExporter`'s `appVersion:` field, so the export
    /// manifest and this screen's own "Version" row can never independently decide
    /// what "unknown" means, and there is exactly one place that knows this Info.plist
    /// key.
    static func shortVersion(bundle: Bundle = .main) -> String {
        displayString(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      build: nil)
    }
}
