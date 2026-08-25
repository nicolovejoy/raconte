import Foundation

/// #90: which CloudKit environment this binary talks to, and where that answer
/// comes from. Design: docs/plans/2026-08-24-90-environment-tag-design.md.
///
/// The `com.apple.developer.icloud-container-environment` entitlement is injected
/// at signing/export time (it is absent from the source entitlements), and iOS
/// offers no public API to read the running signature — so detection parses the
/// embedded provisioning profile instead. No profile, or no key, means production:
/// App Store installs strip the embedded profile, and App Store is production.
///
/// Known imprecision, accepted: a manually-run simulator build has no embedded
/// profile and detects `.production` while actually talking to Development. Sync
/// in a simulator is already gated to rare manual runs (`shouldSync` excludes the
/// test/preview runners), and a wrong tag costs one bookkeeping wipe — a resync,
/// never data.
enum CloudKitEnvironment: String, Sendable, Equatable {
    case development
    case production

    /// Pure core: extract the environment from raw provisioning-profile bytes.
    /// The profile is a CMS blob wrapping a plaintext XML plist; the plist range
    /// is found by byte scan, then decoded. Any structural surprise is nil —
    /// callers decide the default.
    static func parse(profileData: Data) -> CloudKitEnvironment? {
        guard let start = profileData.range(of: Data("<plist".utf8)),
              let end = profileData.range(of: Data("</plist>".utf8),
                                          in: start.upperBound..<profileData.endIndex)
        else { return nil }
        let plistData = profileData.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let raw = entitlements["com.apple.developer.icloud-container-environment"] as? String
        else { return nil }
        return CloudKitEnvironment(rawValue: raw.lowercased())
    }

    /// Thin shell: find the embedded profile in `bundle` and parse it.
    /// iOS: `embedded.mobileprovision` at the bundle root. macOS:
    /// `Contents/embedded.provisionprofile`. Absent or unparseable ⇒ `.production`.
    static func detectFromBundle(_ bundle: Bundle = .main) -> CloudKitEnvironment {
        #if os(macOS)
        let url = bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        #endif
        guard let data = try? Data(contentsOf: url),
              let parsed = parse(profileData: data) else { return .production }
        return parsed
    }
}
