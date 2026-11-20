import XCTest
import VMCore
@testable import EngineQEMU

/// Review finding R15: a disk that goes missing must stop the VM from starting, not be replaced by an empty one.
final class MissingDiskTests: XCTestCase {
    private var root: URL!
    private var toolchain: QEMUToolchain!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A stand-in qemu-img that makes the file it is asked for: create -q -f qcow2 <path> <size>.
        let qemuImg = root.appendingPathComponent("qemu-img")
        try "#!/bin/sh\nprintf made > \"$5\"\n".write(to: qemuImg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: qemuImg.path)
        let vars = root.appendingPathComponent("vars.fd")
        try Data("vars".utf8).write(to: vars)
        toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/q"), qemuImg: qemuImg, swtpm: nil,
                                  firmwareCode: URL(fileURLWithPath: "/code.fd"), firmwareVarsTemplate: vars, qemuVersion: "11.1.3")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func paths() -> QEMURunPaths {
        QEMURunPaths(directory: root.appendingPathComponent("run-\(UUID().uuidString.prefix(6))", isDirectory: true))
    }

    private func makeBundle(disks: [DiskConfig]? = nil) throws -> VMBundle {
        var config = VMConfig(name: "Q", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024)
        if let disks { config.disks = disks }
        return try VMBundle.create(config: config, in: root.appendingPathComponent("VMs"))
    }

    func testANewDiskIsMadeOnceAndItsMarkerConsumed() throws {
        let bundle = try makeBundle()
        let disk = bundle.config.disks[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.uninitializedMarker(disk).path))
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())
        XCTAssertEqual(try String(contentsOf: bundle.diskURL(disk), encoding: .utf8), "made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.uninitializedMarker(disk).path))
    }

    func testADiskMissingAfterItWasMadeBlocksTheStart() throws {
        let bundle = try makeBundle()
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())
        try FileManager.default.removeItem(at: bundle.diskURL(bundle.config.disks[0]))
        XCTAssertThrowsError(try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("disk0.qcow2") == true, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.diskURL(bundle.config.disks[0]).path), "no empty disk in its place")
    }

    func testAMissingSecondDiskBlocksTheStart() throws {
        let bundle = try makeBundle(disks: [DiskConfig(file: "disk0.qcow2", sizeGiB: 1, bus: .virtio, format: .qcow2),
                                            DiskConfig(file: "data.qcow2", sizeGiB: 1, bus: .virtio, format: .qcow2)])
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("data.qcow2"))
        XCTAssertThrowsError(try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths()))
    }

    func testADiskMadeByAnImportClearsTheMarker() throws {
        let bundle = try makeBundle()
        let disk = bundle.config.disks[0]
        try Data("imported".utf8).write(to: bundle.diskURL(disk))
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())
        XCTAssertEqual(try String(contentsOf: bundle.diskURL(disk), encoding: .utf8), "imported")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.uninitializedMarker(disk).path))
        try FileManager.default.removeItem(at: bundle.diskURL(disk))
        XCTAssertThrowsError(try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths()))
    }

    /// VMs made by an older Tandem have no marker: their disk may still be made while they have never started.
    func testAnOlderNeverStartedVMStillGetsItsDisk() throws {
        let bundle = try makeBundle()
        try FileManager.default.removeItem(at: bundle.uninitializedMarker(bundle.config.disks[0]))
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: paths())
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.diskURL(bundle.config.disks[0]).path))
    }
}
