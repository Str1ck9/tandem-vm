import XCTest
@testable import Provisioning
import VMCore

final class Windows3DDriverTests: XCTestCase {
    func testReleaseIsPinned() {
        XCTAssertEqual(Windows3DDriver.release.url.host, "github.com")
        XCTAssertTrue(Windows3DDriver.release.url.path.hasPrefix("/utmapp/"))
        XCTAssertEqual(Windows3DDriver.release.checksum, .sha256("ab6add47a4ed992f5920f14e96f68d60566e6f731e2cf816c3d38ab2b78f407a"))
        XCTAssertEqual(Windows3DDriver.release.expectedBytes, 143_898_624)
    }

    func testPowerShellCommandIsUTF16LittleEndianBase64() throws {
        let command = Windows3DDriver.powerShell("exit 7")
        let encoded = try XCTUnwrap(command.split(separator: " ").last.map(String.init))
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(String(data: data, encoding: .utf16LittleEndian), "exit 7")
        XCTAssertTrue(command.hasPrefix("powershell -NoProfile"))
    }

    func testInstallScriptLooksForTheDiscAndInstalls() {
        XCTAssertTrue(Windows3DDriver.installScript.contains("viogpu3d.inf"))
        XCTAssertTrue(Windows3DDriver.installScript.contains("pnputil.exe /add-driver"))
        XCTAssertTrue(Windows3DDriver.installScript.contains("exit $LASTEXITCODE"))
    }

    func testOutcomeReadsPublishedNameAndRestart() {
        let output = """
        Microsoft PnP Utility

        Adding driver package:  viogpu3d.inf
        Driver package added successfully.
        Published Name:         oem42.inf
        Driver package installed on device: PCI\\VEN_1AF4&DEV_1050
        """
        XCTAssertEqual(Windows3DDriver.outcome(exitCode: 0, output: output), .installed(publishedName: "oem42.inf", restartNeeded: false))
        XCTAssertEqual(Windows3DDriver.outcome(exitCode: 3010, output: output), .installed(publishedName: "oem42.inf", restartNeeded: true))
        XCTAssertEqual(Windows3DDriver.outcome(exitCode: 0, output: output + "\nSystem reboot is needed to complete install operations!"),
                       .installed(publishedName: "oem42.inf", restartNeeded: true))
    }

    func testOutcomeFailures() {
        XCTAssertEqual(Windows3DDriver.outcome(exitCode: 2, output: "no driver disc"), .failed("Windows could not find the 3D driver disc."))
        guard case .failed(let why) = Windows3DDriver.outcome(exitCode: 5, output: "Access is denied.") else { return XCTFail() }
        XCTAssertTrue(why.contains("5"))
        XCTAssertTrue(why.contains("Access is denied."))
    }

    func testRemoveCommandNamesThePackage() {
        XCTAssertEqual(Windows3DDriver.removeCommand(publishedName: "oem42.inf"), "pnputil /delete-driver oem42.inf /uninstall /force")
    }

    func testOldConfigsLoadAndTheDriverStateRoundTrips() throws {
        var config = VMConfig(name: "w", guestOS: .windows11arm, engine: .qemu)
        config.display.accelerated3D = true
        config.display.windows3DDriver = Windows3DDriverState(version: "0.1.274", publishedName: "oem3.inf")
        config.removableMedia.append(RemovableMedia(file: Windows3DDriver.discFileName, kind: .driverDisc))
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(VMConfig.self, from: data)
        XCTAssertEqual(back.display.windows3DDriver, config.display.windows3DDriver)
        XCTAssertEqual(back.removableMedia.last?.kind, .driverDisc)
        // A config written before this feature has neither field.
        var plain = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var display = plain["display"] as! [String: Any]
        display.removeValue(forKey: "windows3DDriver")
        plain["display"] = display
        plain["removableMedia"] = []
        let old = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: plain))
        XCTAssertNil(old.display.windows3DDriver)
    }

    /// Needs a guest tools release on disk (TANDEM_TEST_UTM_TOOLS=/path/to/utm-guest-tools-*.iso).
    func testDiscIsBuiltFromTheGuestToolsRelease() throws {
        guard let path = ProcessInfo.processInfo.environment["TANDEM_TEST_UTM_TOOLS"] else { throw XCTSkip("no guest tools disc given") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("w3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disc = folder.appendingPathComponent(Windows3DDriver.discFileName)
        try Windows3DDriver.buildDisc(from: URL(fileURLWithPath: path), to: disc)
        XCTAssertTrue(Windows3DDriver.discExists(in: folder))
        let mount = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Windows3DDriver.hdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, disc.path])
        defer { _ = try? Windows3DDriver.hdiutil(["detach", mount.path, "-force"]) }
        let names = try FileManager.default.contentsOfDirectory(atPath: mount.path).map { $0.lowercased() }
        for required in ["viogpu3d.inf", "viogpu3d.cat", "viogpu3d.sys", "virtio-win_license.txt"] {
            XCTAssertTrue(names.contains(required), "\(required) missing from the driver disc: \(names)")
        }
    }
}
