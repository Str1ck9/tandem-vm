import XCTest
@testable import EngineQEMU
import VMCore

/// Hands a raw disk to a real QEMU the way a USB drive reaches the VM: qemu-nbd (run by the helper as
/// root in real use) serves the raw node (`/dev/rdiskN`) on a unix socket, and QEMU reads it over NBD as a
/// removable `usb-storage` device, then lets go again. A disk image attached with hdiutil stands in for the
/// drive (its raw node belongs to the user, so no root is needed). No guest runs: QEMU is started paused.
final class USBDiskQEMUTests: XCTestCase {
    private func tool(_ path: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitForExit(timeout: 60)
        return String(decoding: data, as: UTF8.self)
    }

    func testRawDiskBecomesAUSBStorageDeviceAndGoesAgain() async throws {
        try await withTestTimeout(120) { try await self.rawDiskBody() }
    }

    private func rawDiskBody() async throws {
        guard let toolchain = try? QEMUToolchain.locate() else { throw XCTSkip("QEMU is not installed") }
        let directory = "/tmp/tud-\(getpid())"  // short: unix socket paths are limited to 104 bytes
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try tool("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "MS-DOS FAT16", "-layout", "MBRSPUD", "-o", directory + "/d.dmg"])
        let attached = try tool("/usr/bin/hdiutil", ["attach", "-nomount", directory + "/d.dmg"])
        guard let first = attached.split(separator: "\n").first, let bsd = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
              bsd.hasPrefix("/dev/disk") else { throw XCTSkip("hdiutil attach failed: \(attached)") }
        defer { _ = try? tool("/usr/bin/hdiutil", ["detach", "-force", bsd]) }
        let raw = bsd.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")

        // The helper's part: qemu-nbd on the raw disk, the same arguments as DiskShare uses.
        let qemuNBD = toolchain.qemu.deletingLastPathComponent().appendingPathComponent("qemu-nbd")
        guard FileManager.default.isExecutableFile(atPath: qemuNBD.path) else { throw XCTSkip("this QEMU build has no qemu-nbd") }
        let nbdPath = directory + "/n.sock"
        let server = Process()
        server.executableURL = qemuNBD
        server.arguments = ["--image-opts", "driver=raw,file.driver=host_device,file.filename=\(raw)", "--socket=\(nbdPath)", "--shared=1"]
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.stopAndWait() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: nbdPath) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nbdPath), "qemu-nbd serves the disk")

        let qmpPath = directory + "/q.sock"
        let qemu = Process()
        qemu.executableURL = toolchain.qemu
        qemu.arguments = ["-M", "virt", "-nodefaults", "-display", "none", "-S", "-device", "qemu-xhci,id=usb",
                          "-qmp", "unix:\(qmpPath),server=on,wait=off"]
        qemu.standardError = FileHandle.nullDevice
        try qemu.run()
        defer { qemu.stopAndWait() }
        let qmp = try await QMPClient.connect(path: qmpPath, timeout: 10)
        defer { qmp.close() }

        let id = "usbhost-test-disk"
        for (command, arguments) in USBPassthroughPlan.diskCommands(qemuID: id, socketPath: nbdPath, readOnly: false) {
            try await qmp.execute(command, arguments: arguments)
        }
        let peripherals = try await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"])
        let names = (peripherals["value"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains(id), "the USB storage device is on the bus: \(names)")
        let blocks = try await qmp.execute("query-named-block-nodes")
        let node = (blocks["value"] as? [[String: Any]] ?? []).first { $0["node-name"] as? String == USBPassthroughPlan.nodeName(id) }
        XCTAssertEqual(node?["ro"] as? Bool, false)
        let size = ((node?["image"] as? [String: Any])?["virtual-size"] as? NSNumber)?.intValue
        XCTAssertEqual(size, 16 * 1024 * 1024, "QEMU sees the whole raw disk")

        _ = try await qmp.execute("device_del", arguments: ["id": id])
        var gone = false
        for _ in 0..<50 {
            let list = try await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"])
            if !((list["value"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == id }) { gone = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(gone, "device_del takes the device off the bus")
        // The inner SCSI disk lets go of the node a moment after the device leaves the bus.
        let removed = await qmp.removeBlockNodeWhenFree(USBPassthroughPlan.nodeName(id))
        XCTAssertTrue(removed, "blockdev-del succeeds once QEMU has let go of the node")
        let after = try await qmp.execute("query-named-block-nodes")
        XCTAssertFalse((after["value"] as? [[String: Any]] ?? []).contains { $0["node-name"] as? String == USBPassthroughPlan.nodeName(id) },
                       "the disk is closed in QEMU")
        // Its only client gone, qemu-nbd ends by itself: nothing keeps the disk open.
        for _ in 0..<50 where server.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(server.isRunning, "qemu-nbd exits when QEMU lets go of the disk")
        _ = try? await qmp.execute("quit")
    }

    /// A serial device the way a Flipper Zero reaches the VM: QEMU opens its Mac serial port (here a
    /// pseudo-terminal standing in for /dev/cu.usbmodem…) as a chardev behind a `usb-serial` device, and
    /// lets go again when the device is removed.
    func testSerialPortBecomesAUSBSerialDeviceAndGoesAgain() async throws {
        try await withTestTimeout(120) { try await self.serialPortBody() }
    }

    private func serialPortBody() async throws {
        guard let toolchain = try? QEMUToolchain.locate() else { throw XCTSkip("QEMU is not installed") }
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { close(master); close(slave) }
        let port = String(cString: name)

        let directory = "/tmp/tus-\(getpid())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let qmpPath = directory + "/q.sock"
        let qemu = Process()
        qemu.executableURL = toolchain.qemu
        qemu.arguments = ["-M", "virt", "-nodefaults", "-display", "none", "-S", "-device", "qemu-xhci,id=usb",
                          "-qmp", "unix:\(qmpPath),server=on,wait=off"]
        qemu.standardError = FileHandle.nullDevice
        try qemu.run()
        defer { qemu.stopAndWait() }
        let qmp = try await QMPClient.connect(path: qmpPath, timeout: 10)
        defer { qmp.close() }

        let id = "usbhost-test-serial"
        // Tandem's QEMU build has the CDC ACM device; a stock QEMU gets the FTDI-compatible adapter.
        let hasCDC = (try? await qmp.execute("device-list-properties", arguments: ["typename": USBPassthroughPlan.cdcACMDevice])) != nil
        var identity = HostUSBDevice(vendorID: 0x0483, productID: 0x5740, name: "Test Serial", vendor: "Test", location: 1)
        identity.serialNumber = "T1"
        for (command, arguments) in USBPassthroughPlan.serialCommands(qemuID: id, path: port, identity: hasCDC ? identity : nil) {
            try await qmp.execute(command, arguments: arguments)
        }
        let chardevs = try await qmp.execute("query-chardev")
        let entry = (chardevs["value"] as? [[String: Any]] ?? []).first { $0["label"] as? String == USBPassthroughPlan.chardevID(id) }
        XCTAssertNotNil(entry, "the Mac port is open as a chardev: \(chardevs)")
        XCTAssertEqual(entry?["frontend-open"] as? Int, 1, "the USB serial device has the port open: \(entry ?? [:])")
        let peripherals = try await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"])
        XCTAssertTrue((peripherals["value"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == id }, "the USB serial device is on the bus")

        _ = try await qmp.execute("device_del", arguments: ["id": id])
        for _ in 0..<50 {
            let list = try await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"])
            if !((list["value"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == id }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await qmp.removeChardevWhenFree(USBPassthroughPlan.chardevID(id))
        let after = try await qmp.execute("query-chardev")
        XCTAssertFalse((after["value"] as? [[String: Any]] ?? []).contains { $0["label"] as? String == USBPassthroughPlan.chardevID(id) },
                       "the Mac port is closed again")
        _ = try? await qmp.execute("quit")
    }
}
