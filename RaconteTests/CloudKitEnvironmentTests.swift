import XCTest
@testable import Raconte

/// #90: the pure parser over embedded-provisioning-profile bytes. The profile is a
/// CMS blob wrapping a plaintext XML plist; fixtures reproduce that shape as
/// junk + plist + junk, because the parser must find the plist range itself.
final class CloudKitEnvironmentTests: XCTestCase {

    private func profileFixture(entitlements: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Name</key><string>raconte appstore</string>
            <key>Entitlements</key>
            <dict>
        \(entitlements)
                <key>com.apple.developer.icloud-container-identifiers</key>
                <array><string>iCloud.org.pianohouseproject.raconte</string></array>
            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x1a, 0x2b, 0x06, 0x09])  // CMS-ish leading junk
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xff, 0x30, 0x82]))            // trailing signature junk
        return data
    }

    func testParsesDevelopmentTag() {
        let data = profileFixture(entitlements: """
                <key>com.apple.developer.icloud-container-environment</key>
                <string>Development</string>
        """)
        XCTAssertEqual(CloudKitEnvironment.parse(profileData: data), .development)
    }

    func testParsesProductionTag() {
        let data = profileFixture(entitlements: """
                <key>com.apple.developer.icloud-container-environment</key>
                <string>Production</string>
        """)
        XCTAssertEqual(CloudKitEnvironment.parse(profileData: data), .production)
    }

    func testMissingKeyParsesNil() {
        XCTAssertNil(CloudKitEnvironment.parse(profileData: profileFixture(entitlements: "")))
    }

    func testGarbageParsesNil() {
        XCTAssertNil(CloudKitEnvironment.parse(profileData: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(CloudKitEnvironment.parse(profileData: Data("<plist".utf8)))  // start, no end
    }

    /// The App Store case: no embedded profile in the bundle at all ⇒ production.
    /// The unit-test bundle has no embedded.provisionprofile, so it IS that case.
    func testDetectWithoutProfileDefaultsToProduction() {
        XCTAssertEqual(CloudKitEnvironment.detectFromBundle(Bundle(for: Self.self)), .production)
    }
}
