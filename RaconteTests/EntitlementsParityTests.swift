import XCTest
@testable import Raconte

/// Two entitlements files ship in this repo and they must not drift (M4 T4):
///
/// - `Raconte/Raconte.entitlements` — **generated** by `xcodegen` from `project.yml`,
///   what the app is actually signed with.
/// - `Raconte/Raconte-nocloud.entitlements` — hand-written, used only as a
///   `CODE_SIGN_ENTITLEMENTS` override for builds that cannot be signed with a real
///   development certificate (CI, and any local `xcodebuild test`), because the
///   `com.apple.developer.icloud-*` keys are restricted and macOS refuses to
///   ad-hoc-sign a binary carrying them.
///
/// The failure this guards against is quiet and expensive: add a sandbox capability to
/// `project.yml` (a new device permission, say), forget the override file, and the test
/// build silently loses that capability. The whole suite then runs against an app the
/// owner will never ship, and CI reports green on it.
///
/// Reads the files off disk with `#filePath`, like `CaptureLabelTests`' source scans —
/// the point is the repo's contents, not the built product's.
final class EntitlementsParityTests: XCTestCase {

    /// Exactly the keys the override is allowed to omit. Everything about sync lives
    /// here, and nothing else may.
    private let syncOnlyKeys: Set<String> = [
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-services",
        "aps-environment",
    ]

    func testTheNoCloudOverrideIsTheShippingEntitlementsMinusExactlyTheSyncKeys() throws {
        let shipping = try entitlements("Raconte/Raconte.entitlements")
        let override = try entitlements("Raconte/Raconte-nocloud.entitlements")

        XCTAssertFalse(shipping.isEmpty, "read no shipping entitlements — did xcodegen run?")
        XCTAssertEqual(Set(shipping.keys).subtracting(override.keys), syncOnlyKeys,
                       "the override may drop the sync keys and nothing else")
        XCTAssertEqual(Set(override.keys).subtracting(shipping.keys), [],
                       "the override must not carry keys the shipping build lacks")

        for key in override.keys {
            XCTAssertEqual(String(describing: shipping[key]), String(describing: override[key]),
                           "\(key) has a different value in the two files")
        }
    }

    /// The shipping file is the one that actually claims the container; if this ever
    /// reads as absent, the app is signed without sync and every device smoke silently
    /// tests nothing.
    func testShippingEntitlementsClaimTheReservedCloudKitContainer() throws {
        let shipping = try entitlements("Raconte/Raconte.entitlements")
        XCTAssertEqual(shipping["com.apple.developer.icloud-container-identifiers"] as? [String],
                       [SyncCloudIdentifiers.containerIdentifier])
        XCTAssertEqual(shipping["com.apple.developer.icloud-services"] as? [String], ["CloudKit"])
    }

    private func entitlements(_ relativePath: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // RaconteTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any] ?? [:]
    }
}
