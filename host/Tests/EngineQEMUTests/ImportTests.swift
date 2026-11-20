import XCTest
import VMCore
@testable import EngineQEMU

final class ImportTests: XCTestCase {
    func testShellListingDirectoryNames() {
        // Captured from the EDK2 shell on a Kali disk: file names are wrapped in colour escapes.
        let raw = "ls fs0:\\EFI\r\nDirectory of: \u{1B}[1m\u{1B}[37m\u{1B}[40mfs0:\\EFI\\\u{1B}[0m\r\n"
            + "07/21/2025  08:47 <DIR>        16,384  \u{1B}[1m\u{1B}[37m\u{1B}[40m.\u{1B}[0m\u{1B}[37m\u{1B}[40m\r\n"
            + "07/21/2025  08:47 <DIR>             0  \u{1B}[1m\u{1B}[37m\u{1B}[40m..\u{1B}[0m\u{1B}[37m\u{1B}[40m\r\n"
            + "07/21/2025  08:47 <DIR>        16,384  \u{1B}[1m\u{1B}[37m\u{1B}[40mkali\u{1B}[0m\u{1B}[37m\u{1B}[40m\r\n"
            + "07/21/2025  08:47 <DIR>        16,384  \u{1B}[1mMy Distro\u{1B}[0m\r\n"
            + "06/07/2026  21:01             159,744  \u{1B}[1mgrubaa64.efi\u{1B}[0m\r\n"
            + "          1 File(s)     159,744 bytes\r\n          3 Dir(s)\r\n"
        XCTAssertEqual(EFIBootFixer.directoryNames(inListing: EFIBootFixer.plainText(raw)), ["kali", "My Distro"])
        XCTAssertTrue(EFIBootFixer.plainText(raw).contains("grubaa64.efi"))
    }

    func testCursorMovesBecomeLineBreaks() {
        XCTAssertEqual(EFIBootFixer.plainText("a\u{1B}[17;01Hb"), "a\nb")
    }

    func testBackingFingerprintDetectsChange() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backing-\(UUID().uuidString).hds")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 100).write(to: file)
        let backing = try DiskBacking.fingerprint(path: file.path, format: "parallels")
        XCTAssertNil(backing.problem())

        // Survives the config's JSON round trip.
        let disk = DiskConfig(file: "disk0.qcow2", sizeGiB: 64, bus: .virtio, format: .qcow2, backing: backing)
        let decoded = try ConfigCoding.decoder().decode(DiskConfig.self, from: ConfigCoding.encoder().encode(disk))
        XCTAssertEqual(decoded, disk)
        XCTAssertNil(decoded.backing?.problem())

        try Data(repeating: 2, count: 101).write(to: file)
        XCTAssertNotNil(backing.problem())
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(backing.problem()?.contains("missing") == true)
    }

    func testDiskWithoutBackingStillDecodes() throws {
        let old = #"{"file":"disk0.qcow2","sizeGiB":64,"bus":"nvme","format":"qcow2"}"#
        XCTAssertNil(try ConfigCoding.decoder().decode(DiskConfig.self, from: Data(old.utf8)).backing)
    }

    func testUnattendDiskIsACDDrive() throws {
        // Windows cannot read an ISO image attached as a plain USB disk (it shows as RAW).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = VMConfig(name: "w", guestOS: .windows11arm)
        config.removableMedia = [RemovableMedia(file: "/tmp/unattend.iso", kind: .unattendDisk)]
        let bundle = try VMBundle.create(config: config, in: dir)
        let toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/q"), qemuImg: URL(fileURLWithPath: "/qi"), swtpm: nil,
                                      firmwareCode: URL(fileURLWithPath: "/code.fd"), firmwareVarsTemplate: URL(fileURLWithPath: "/vars.fd"), qemuVersion: "11.1.3")
        let args = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: .forVM(bundle.id), display: .none)
        let drive = try XCTUnwrap(args.first { $0.contains("file=/tmp/unattend.iso") })
        XCTAssertTrue(drive.contains("media=cdrom"), drive)
    }

    func testProjectQEMUBuildIsSearchedFirst() {
        let dirs = QEMUToolchain.preferredDirectories(environment: [QEMUToolchain.prefixVariable: "/opt/tandem-qemu"])
        XCTAssertEqual(dirs.first, "/opt/tandem-qemu/bin")
        XCTAssertEqual(dirs.last, QEMUToolchain.defaultBuildPrefix.appendingPathComponent("bin").path)
        XCTAssertEqual(QEMUToolchain.preferredDirectories(environment: [:]).count, 1)
        let stock = QEMUToolchain(qemu: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"), qemuImg: URL(fileURLWithPath: "/qi"), swtpm: nil,
                                  firmwareCode: URL(fileURLWithPath: "/c"), firmwareVarsTemplate: URL(fileURLWithPath: "/v"), qemuVersion: "11.1.3")
        XCTAssertFalse(stock.isPatchedBuild)
    }
}
