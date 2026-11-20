import XCTest
@testable import EngineQEMU
import NetHelperClient

final class USBPlanTests: XCTestCase {
    private let device = HostUSBDevice(vendorID: 0x21c4, productID: 0x0809, name: "USB Flash Drive", vendor: "Lexar", location: 0x0220_0000)

    func testRedirectAddsASocketChardevThenTheDevice() throws {
        let commands = USBPassthroughPlan.redirectCommands(qemuID: device.qemuID, socketPath: "/var/run/tandem-net-usb-3.sock")
        XCTAssertEqual(commands.map(\.0), ["chardev-add", "device_add"])
        let chardev = commands[0].1
        XCTAssertEqual(chardev["id"] as? String, "chr-usbhost-21c4-0809-02200000")
        let backend = try XCTUnwrap(chardev["backend"] as? [String: Any])
        XCTAssertEqual(backend["type"] as? String, "socket")
        let data = try XCTUnwrap(backend["data"] as? [String: Any])
        XCTAssertEqual(data["server"] as? Bool, false, "QEMU connects to the helper's socket")
        let addr = try XCTUnwrap(data["addr"] as? [String: Any])
        XCTAssertEqual(addr["type"] as? String, "unix")
        XCTAssertEqual((addr["data"] as? [String: Any])?["path"] as? String, "/var/run/tandem-net-usb-3.sock")
        let add = commands[1].1
        XCTAssertEqual(add["driver"] as? String, "usb-redir")
        XCTAssertEqual(add["chardev"] as? String, chardev["id"] as? String)
        XCTAssertEqual(add["id"] as? String, device.qemuID)
        XCTAssertEqual(add["bus"] as? String, "usb.0")
        // The commands must survive JSON encoding as sent over QMP.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["execute": commands[0].0, "arguments": chardev]))
    }

    func testDetachRemovesTheDeviceBeforeItsChardev() {
        XCTAssertEqual(USBPassthroughPlan.detachCommands(qemuID: device.qemuID, redirected: true).map(\.0), ["device_del", "chardev-remove"])
        XCTAssertEqual(USBPassthroughPlan.detachCommands(qemuID: device.qemuID, redirected: false).map(\.0), ["device_del"])
    }

    // MARK: Which way a device goes (macOS 26: never capture a device a macOS driver holds)

    private let helperV3 = NetHelper.Info(version: 4, features: ["bridge", "usb", "disk", "probe"])

    func testUSBDriveGoesAsItsDiskThroughTheHelper() {
        var drive = device
        drive.macOSDriver = "IOUSBMassStorageInterfaceNub"
        drive.diskBSDName = "disk5"
        XCTAssertEqual(USBRoute.choose(for: drive, helper: helperV3), .disk(bsd: "disk5"))
        // Without a helper that can do it: refused with advice, never captured.
        guard case .refuse(_, let detail) = USBRoute.choose(for: drive, helper: nil) else { return XCTFail("must refuse") }
        XCTAssertTrue(detail.contains("sudo"), detail)
        guard case .refuse(_, let old) = USBRoute.choose(for: drive, helper: NetHelper.Info(version: 2, features: ["bridge", "usb"])) else { return XCTFail("must refuse") }
        XCTAssertTrue(old.contains("too old"), old)
        // Protocol 3 lent the node by chown, which macOS 26 refuses even root: such a helper is too old.
        guard case .refuse(_, let v3) = USBRoute.choose(for: drive, helper: NetHelper.Info(version: 3, features: ["bridge", "usb", "disk"])) else {
            return XCTFail("a protocol 3 helper must be reported as too old")
        }
        XCTAssertTrue(v3.contains("too old"), v3)
    }

    func testSerialDeviceGoesThroughItsMacPort() {
        var flipper = HostUSBDevice(vendorID: 0x0483, productID: 0x5740, name: "Flipper", vendor: "Flipper Devices Inc.", location: 0x0210_0000)
        flipper.macOSDriver = "AppleUSBACMControl"
        flipper.serialPath = "/dev/cu.usbmodemflip_Test1"
        XCTAssertEqual(USBRoute.choose(for: flipper, helper: nil), .serial(path: "/dev/cu.usbmodemflip_Test1"))
    }

    func testDriverHeldDeviceIsRefusedAndDriverlessDeviceGoesDirectly() {
        var keyboard = HostUSBDevice(vendorID: 0x05ac, productID: 0x024f, name: "Keyboard", vendor: nil, location: 0x0100_0000)
        keyboard.macOSDriver = "AppleUserHIDDevice"
        guard case .refuse(let message, let detail) = USBRoute.choose(for: keyboard, helper: helperV3) else { return XCTFail("must refuse") }
        XCTAssertTrue(message.contains("AppleUserHIDDevice"), message)
        XCTAssertTrue(detail.contains("plugged in again"), detail)
        let board = HostUSBDevice(vendorID: 0x2e8a, productID: 0x0003, name: "RP2 Boot", vendor: nil, location: 0x0100_0000)
        XCTAssertEqual(USBRoute.choose(for: board, helper: nil), .host)
    }

    func testDiskCommandsReadTheHelpersNBDSocketAsARemovableUSBStorageDevice() throws {
        let commands = USBPassthroughPlan.diskCommands(qemuID: device.qemuID, socketPath: "/var/run/tandem-net-disk-3/nbd.sock", readOnly: true)
        XCTAssertEqual(commands.map(\.0), ["blockdev-add", "device_add"])
        let node = commands[0].1
        XCTAssertEqual(node["read-only"] as? Bool, true)
        let file = try XCTUnwrap(node["file"] as? [String: Any])
        XCTAssertEqual(file["driver"] as? String, "nbd")
        XCTAssertEqual(file["read-only"] as? Bool, true)
        let server = try XCTUnwrap(file["server"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "unix")
        XCTAssertEqual(server["path"] as? String, "/var/run/tandem-net-disk-3/nbd.sock")
        XCTAssertEqual(commands[1].1["driver"] as? String, "usb-storage")
        XCTAssertEqual(commands[1].1["drive"] as? String, node["node-name"] as? String)
        XCTAssertEqual(USBPassthroughPlan.diskCleanupCommands(qemuID: device.qemuID).map(\.0), ["blockdev-del"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: node))
    }

    func testSerialCommandsOpenThePortAsAChardev() throws {
        let commands = USBPassthroughPlan.serialCommands(qemuID: device.qemuID, path: "/dev/cu.usbmodem1")
        XCTAssertEqual(commands.map(\.0), ["chardev-add", "device_add"])
        let backend = try XCTUnwrap(commands[0].1["backend"] as? [String: Any])
        XCTAssertEqual(backend["type"] as? String, "serial")
        XCTAssertEqual((backend["data"] as? [String: Any])?["device"] as? String, "/dev/cu.usbmodem1")
        XCTAssertEqual(commands[1].1["driver"] as? String, "usb-serial")
    }

    func testSerialDeviceKeepsItsIdentityAsACDCACMPort() throws {
        var flipper = device
        flipper.vendorID = 0x0483; flipper.productID = 0x5740
        flipper.name = "Flipper Urc0p0un"; flipper.vendor = "Flipper Devices Inc."; flipper.serialNumber = "flip_Urc0p0un"
        let commands = USBPassthroughPlan.serialCommands(qemuID: flipper.qemuID, path: "/dev/cu.usbmodemflip_Urc0p0un1", identity: flipper)
        XCTAssertEqual(commands.map(\.0), ["chardev-add", "device_add"])
        let added = commands[1].1
        XCTAssertEqual(added["driver"] as? String, "usb-cdc-acm")
        XCTAssertEqual(added["vendorid"] as? Int, 0x0483)
        XCTAssertEqual(added["productid"] as? Int, 0x5740)
        XCTAssertEqual(added["product"] as? String, "Flipper Urc0p0un")
        XCTAssertEqual(added["manufacturer"] as? String, "Flipper Devices Inc.")
        XCTAssertEqual(added["serial"] as? String, "flip_Urc0p0un")
        XCTAssertEqual(added["chardev"] as? String, USBPassthroughPlan.chardevID(flipper.qemuID))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: added))
    }

    func testDescriptorStringsStayPrintableASCII() {
        XCTAssertEqual(USBPassthroughPlan.descriptorString("Café\tUSB"), "Caf??USB")
        XCTAssertEqual(USBPassthroughPlan.descriptorString(String(repeating: "x", count: 300)).count, 126)
    }

    func testHostFallbackNamesTheDeviceByIDs() {
        let commands = USBPassthroughPlan.hostCommands(device)
        XCTAssertEqual(commands.map(\.0), ["device_add"])
        XCTAssertEqual(commands[0].1["driver"] as? String, "usb-host")
        XCTAssertEqual(commands[0].1["vendorid"] as? Int, 0x21c4)
        XCTAssertEqual(commands[0].1["productid"] as? Int, 0x0809)
    }
}
