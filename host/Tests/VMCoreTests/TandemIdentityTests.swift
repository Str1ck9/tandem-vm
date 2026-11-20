import XCTest
@testable import VMCore

final class TandemIdentityTests: XCTestCase {
    override func tearDown() {
        TandemIdentity.overrideForTesting(nil)
        super.tearDown()
    }

    func testDefaultsShareOnePrefix() {
        let base = TandemIdentity.Base.standard
        XCTAssertEqual(base.prefix, "local.tandem")
        XCTAssertEqual(base.app, "local.tandem.app")
        TandemIdentity.overrideForTesting(base)
        XCTAssertEqual(TandemIdentity.app, "local.tandem.app")
        XCTAssertEqual(TandemIdentity.helper, "local.tandem.helper")
        XCTAssertEqual(TandemIdentity.helperPlistName, "local.tandem.helper.plist")
        XCTAssertEqual(TandemIdentity.scriptHelper, "local.tandem.nethelper")
        XCTAssertEqual(TandemIdentity.guestAgent, "local.tandem.agent")
        XCTAssertEqual(TandemIdentity.documentType, "local.tandem.vm")
        XCTAssertEqual(TandemIdentity.tool("qemu-nbd"), "local.tandem.qemu-nbd")
        XCTAssertEqual(GuestTools.macOSDaemonLabel, TandemIdentity.guestAgent)
        XCTAssertEqual(GuestAppBundle.hostBundleIdentifier, TandemIdentity.app)
        XCTAssertTrue(GuestAppBundle.quitNotification.hasPrefix(TandemIdentity.guestApp + "."))
    }

    func testAnotherPrefixChangesEveryDerivedIdentifier() {
        TandemIdentity.overrideForTesting(.init(prefix: "org.example.tandem", app: "org.example.tandem"))
        XCTAssertEqual(TandemIdentity.app, "org.example.tandem")
        XCTAssertEqual(TandemIdentity.helper, "org.example.tandem.helper")
        XCTAssertEqual(TandemIdentity.documentType, "org.example.tandem.vm")
        XCTAssertEqual(TandemIdentity.tool("usbredirect"), "org.example.tandem.usbredirect")
        XCTAssertEqual(TandemIdentity.guestApp, "org.example.tandem.guestapp")
    }

    func testResolveOrderIsEnvironmentThenInfoPlistsThenDefaults() {
        let plist: [String: Any] = [TandemIdentity.prefixKey: "org.example.plist", TandemIdentity.appKey: "org.example.plist.app"]
        let other: [String: Any] = [TandemIdentity.prefixKey: "org.example.other"]
        // Environment first.
        XCTAssertEqual(TandemIdentity.resolve(environment: ["TANDEM_BUNDLE_PREFIX": "org.example.env", "TANDEM_APP_ID": "org.example.env.main"],
                                              infoDictionaries: [plist]),
                       .init(prefix: "org.example.env", app: "org.example.env.main"))
        // The app identifier defaults to <prefix>.app.
        XCTAssertEqual(TandemIdentity.resolve(environment: ["TANDEM_BUNDLE_PREFIX": "org.example.env"], infoDictionaries: [plist]),
                       .init(prefix: "org.example.env", app: "org.example.env.app"))
        // Then the first Info.plist that names a prefix.
        XCTAssertEqual(TandemIdentity.resolve(environment: [:], infoDictionaries: [[:], plist, other]),
                       .init(prefix: "org.example.plist", app: "org.example.plist.app"))
        XCTAssertEqual(TandemIdentity.resolve(environment: [:], infoDictionaries: [other]),
                       .init(prefix: "org.example.other", app: "org.example.other.app"))
        // Then the defaults.
        XCTAssertEqual(TandemIdentity.resolve(environment: [:], infoDictionaries: [[:]]), .standard)
    }

    func testMalformedValuesAreIgnored() {
        // The values end up in launchd labels, file names and code signing requirements.
        for bad in ["", " ", "a b", "a\"b", "x\" or anchor apple", "../x", "-x", "a/b", String(repeating: "a", count: 200)] {
            XCTAssertFalse(TandemIdentity.isValidIdentifier(bad), bad)
            XCTAssertEqual(TandemIdentity.resolve(environment: ["TANDEM_BUNDLE_PREFIX": bad], infoDictionaries: []), .standard, bad)
        }
        XCTAssertEqual(TandemIdentity.resolve(environment: ["TANDEM_BUNDLE_PREFIX": "org.example", "TANDEM_APP_ID": "bad id"], infoDictionaries: []),
                       .init(prefix: "org.example", app: "org.example.app"), "a malformed app id falls back to <prefix>.app")
        XCTAssertTrue(TandemIdentity.isValidIdentifier("com.example.tandem-2_x"))
    }

    func testFindsTheInfoPlistOfTheEnclosingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("Fake.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let info: [String: Any] = [TandemIdentity.prefixKey: "org.example.built", TandemIdentity.appKey: "org.example.built.app"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let found = TandemIdentity.enclosingAppInfo(of: helpers.appendingPathComponent("TandemNetHelper").path)
        XCTAssertEqual(found?[TandemIdentity.prefixKey] as? String, "org.example.built")
        XCTAssertNil(TandemIdentity.enclosingAppInfo(of: root.appendingPathComponent("elsewhere/tool").path), "not inside an app")
    }
}
