import XCTest
import VMCore
@testable import Provisioning

final class ParallelsVMTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pvm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Writes a minimal bundle shaped like the ones Parallels Desktop 26/27 writes.
    func makeBundle(name: String = "Test.pvm", osType: Int = 9, tpm: Int = 0, shots: Int = 1, images: Int = 1,
                    engine: String = "{00000000-0000-0000-0000-000000000000}", type: String = "Compressed",
                    extraFiles: [String] = [], writeImages: Bool = true) throws -> URL {
        let bundle = root.appendingPathComponent(name)
        let hdd = bundle.appendingPathComponent("disk-0.hdd")
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        let config = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ParallelsVirtualMachine>
          <Identification><VmName>Test VM</VmName><VmUuid>{aaaaaaaa-0000-4000-8000-000000000001}</VmUuid><SourceVmUuid>{bbbbbbbb-0000-4000-8000-000000000002}</SourceVmUuid></Identification>
          <Settings><General><OsType>\(osType)</OsType></General></Settings>
          <Hardware>
            <Cpu><Number>4</Number></Cpu>
            <Memory><RAM>8192</RAM></Memory>
            <Hdd><Enabled>1</Enabled><Connected>1</Connected><SystemName>disk-0.hdd</SystemName><InterfaceType>2</InterfaceType></Hdd>
            <Hdd><Enabled>0</Enabled><Connected>1</Connected><SystemName>unused.hdd</SystemName></Hdd>
            <NetworkAdapter><MAC>001C42A00C16</MAC></NetworkAdapter>
            <TpmChip><Type>\(tpm)</Type></TpmChip>
          </Hardware>
        </ParallelsVirtualMachine>
        """
        try config.write(to: bundle.appendingPathComponent("config.pvs"), atomically: true, encoding: .utf8)
        let imageXML = (0..<images).map { "<Image><GUID>{g\($0)}</GUID><Type>\(type)</Type><File>disk-0.hdd.\($0).hds</File></Image>" }.joined()
        let shotXML = (0..<shots).map { "<Shot><GUID>{g\($0)}</GUID><ParentGUID>{p}</ParentGUID></Shot>" }.joined()
        let descriptor = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Parallels_disk_image Version="1.0">
          <Disk_Parameters><Disk_size>134217728</Disk_size><LogicSectorSize>512</LogicSectorSize>
            <Encryption><Engine>\(engine)</Engine><Data/><Salt/></Encryption></Disk_Parameters>
          <StorageData><Storage><Start>0</Start><End>134217728</End>\(imageXML)</Storage></StorageData>
          <Snapshots>\(shotXML)</Snapshots>
        </Parallels_disk_image>
        """
        try descriptor.write(to: hdd.appendingPathComponent("DiskDescriptor.xml"), atomically: true, encoding: .utf8)
        if writeImages {
            for i in 0..<images { try Data([0]).write(to: hdd.appendingPathComponent("disk-0.hdd.\(i).hds")) }
        }
        for f in extraFiles { try Data().write(to: bundle.appendingPathComponent(f)) }
        return bundle
    }

    func testReadsHardwareAndDisk() throws {
        let vm = try ParallelsVM.inspect(try makeBundle(osType: 8, tpm: 201))
        XCTAssertEqual(vm.name, "Test VM")
        XCTAssertEqual(vm.guestOS, .windows11arm)
        XCTAssertEqual(vm.cpuCount, 4)
        XCTAssertEqual(vm.memoryMiB, 8192)
        XCTAssertEqual(vm.mac, "00:1c:42:a0:0c:16")
        XCTAssertTrue(vm.hasTPM)
        XCTAssertEqual(vm.disks.count, 1, "disabled disks are skipped")
        XCTAssertEqual(vm.disks[0].sizeBytes, 64 << 30)
        XCTAssertEqual(vm.disks[0].qemuFormat, "parallels")
        XCTAssertEqual(vm.disks[0].images.map(\.lastPathComponent), ["disk-0.hdd.0.hds"])
        XCTAssertEqual(vm.blockers, [])
    }

    func testPlainImageIsRawAndMacvmIsMacOS() throws {
        let vm = try ParallelsVM.inspect(try makeBundle(name: "Mac.macvm", osType: 7, type: "Plain"))
        XCTAssertEqual(vm.guestOS, .macos)
        XCTAssertEqual(vm.disks[0].qemuFormat, "raw")
    }

    func testBlockers() throws {
        XCTAssertTrue(try ParallelsVM.inspect(try makeBundle(name: "a.pvm", shots: 2, images: 2)).blockers.contains { $0.contains("snapshots") })
        XCTAssertTrue(try ParallelsVM.inspect(try makeBundle(name: "b.pvm", engine: "{1a2b3c4d-0000-0000-0000-000000000001}")).blockers.contains { $0.contains("encrypted") })
        XCTAssertTrue(try ParallelsVM.inspect(try makeBundle(name: "c.pvm", extraFiles: ["{abc}.sav"])).blockers.contains { $0.contains("suspended") })
        XCTAssertTrue(try ParallelsVM.inspect(try makeBundle(name: "d.pvm", osType: 6)).blockers.contains { $0.contains("operating system") })
        XCTAssertTrue(try ParallelsVM.inspect(try makeBundle(name: "e.pvm", writeImages: false)).blockers.contains { $0.contains("missing") })
    }

    func testRejectsOtherBundles() {
        XCTAssertThrowsError(try ParallelsVM.inspect(root.appendingPathComponent("thing.utm")))
        XCTAssertThrowsError(try ParallelsVM.inspect(root.appendingPathComponent("absent.pvm")))
    }

    func testProposedConfig() throws {
        let linux = try ParallelsVM.inspect(try makeBundle(name: "l.pvm")).proposedConfig(name: "renamed")
        XCTAssertEqual(linux.name, "renamed")
        XCTAssertEqual(linux.engine, .qemu)
        XCTAssertFalse(linux.tpm)
        XCTAssertEqual(linux.network.mac, "00:1c:42:a0:0c:16")
        XCTAssertEqual(linux.hardwareUUID, UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002"), "the firmware UUID follows SourceVmUuid")
        XCTAssertEqual(linux.install.state, .complete)
        let windows = try ParallelsVM.inspect(try makeBundle(name: "w.pvm", osType: 8)).proposedConfig()
        XCTAssertTrue(windows.tpm)
        let mac = try ParallelsVM.inspect(try makeBundle(name: "m.macvm", osType: 7, type: "Plain")).proposedConfig()
        XCTAssertEqual(mac.engine, .vz)
    }

    func testFormatMAC() {
        XCTAssertEqual(ParallelsVM.formatMAC("001C42F1FF1B"), "00:1c:42:f1:ff:1b")
        XCTAssertNil(ParallelsVM.formatMAC("auto"))
    }
}
