import XCTest
@testable import VMCore

/// Review finding R02: a disk path in a config must never make Tandem write outside the VM's bundle.
final class DiskPathRulesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-diskpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func config(_ files: [String], format: DiskFormat = .raw) -> VMConfig {
        VMConfig(name: "Disk test", guestOS: .linux, cpuCount: 1, memoryMiB: 1024,
                 disks: files.map { DiskConfig(file: $0, sizeGiB: 1, bus: .virtio, format: format) })
    }

    func testOrdinaryNamesAreAccepted() {
        XCTAssertNil(DiskPathRules.problem(with: "disk0.img"))
        XCTAssertNil(DiskPathRules.problem(with: "disk0.qcow2"))
        XCTAssertNil(DiskPathRules.problem(with: "data/disk1.img"))
        XCTAssertTrue(config(["disk0.img", "disk1.img"]).validate(hostCPUs: 8, hostMemoryMiB: 8192).isEmpty)
    }

    func testTraversalAbsoluteEmptyAndReservedNamesAreRefused() {
        for bad in ["../outside.img", "a/../../outside.img", "data/../../x.img", "/tmp/x.img", "", ".", "..",
                    "a//b.img", "config.json", "Config.JSON", "run", "run/qmp.sock", "logs/x", "snapshots/s/disk0.img",
                    "efi-vars.fd", "aux.img", "suspend.state", ".reverting-123/disk0.img", "bad\0name.img", "a\\b.img"] {
            XCTAssertNotNil(DiskPathRules.problem(with: bad), "accepted \(bad.debugDescription)")
            XCTAssertFalse(config([bad]).validate(hostCPUs: 8, hostMemoryMiB: 8192).isEmpty, "validated \(bad.debugDescription)")
        }
    }

    func testTwoDisksSharingAFileAreRefused() {
        XCTAssertFalse(config(["disk0.img", "DISK0.img"]).validate(hostCPUs: 8, hostMemoryMiB: 8192).isEmpty)
    }

    /// The reproduction from the review: `../outside.img` used to replace a sibling file with 1 GiB of zeros.
    func testCreateDoesNotTouchAFileOutsideTheBundle() throws {
        let outside = root.appendingPathComponent("outside.img")
        try Data("precious".utf8).write(to: outside)
        XCTAssertThrowsError(try VMBundle.create(config: config(["../outside.img"]), in: root))
        XCTAssertEqual(try Data(contentsOf: outside), Data("precious".utf8))
    }

    func testCreateNeverOverwritesAnExistingFile() throws {
        let target = root.appendingPathComponent("existing.img")
        try Data("keep".utf8).write(to: target)
        XCTAssertThrowsError(try DiskImage.createSparseRaw(at: target, sizeGiB: 1))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testCreateDoesNotFollowALinkInTheDisksPlace() throws {
        let outside = root.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: outside)
        let link = root.appendingPathComponent("link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try DiskImage.createSparseRaw(at: link, sizeGiB: 1))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testASymlinkedFolderLeadingOutIsRefused() throws {
        let bundle = root.appendingPathComponent("vm.tandemvm")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("data"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try DiskPathRules.containedURL("data/disk1.img", in: bundle))
        XCTAssertEqual(try DiskPathRules.containedURL("disk0.img", in: bundle).lastPathComponent, "disk0.img")
    }

    func testCreateMakesTheDisksAndCanLeaveThemOut() throws {
        let made = try VMBundle.create(config: config(["disk0.img"]), in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.diskURL(made.config.disks[0]).path))
        var other = config(["disk0.img"]); other.name = "Second"
        let bare = try VMBundle.create(config: other, in: root, createDisks: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.diskURL(bare.config.disks[0]).path))
    }
}
