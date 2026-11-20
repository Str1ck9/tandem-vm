import Provisioning
import Virtualization
import VMCore
import XCTest
@testable import EngineVZ

/// What can be checked about new macOS VMs without Apple's servers and without the virtualization
/// entitlement: the provider's facts, the disk-space check, and the files a macOS VM is made of.
final class MacOSInstallTests: XCTestCase {
    private var root: URL!

    /// The hardware model of Apple's macOS 26.6.2 restore image (build 25G83), as the framework hands it out.
    private let model = Data(base64Encoded: "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxAaEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc")!

    private var release: MacOSRestoreImages.Release {
        MacOSRestoreImages.Release(version: "26.6.2", build: "25G83",
                                   url: URL(string: "https://updates.cdn-apple.com/x/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
                                   hardwareModel: model, minimumCPUCount: 2, minimumMemoryMiB: 4096)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-macos-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func newBundle(diskGiB: Int = 64, cpus: Int = 1, memoryMiB: Int = 2048) throws -> VMBundle {
        var config = VMConfig(name: "macOS", guestOS: .macos, engine: .vz, cpuCount: cpus, memoryMiB: memoryMiB)
        config.disks[0].sizeGiB = diskGiB
        return try VMLibrary(rootDirectory: root).create(config)
    }

    func testProviderFillsTheMacOSSlotOnAppleVirtualization() {
        let provider = MacOSRestoreImages()
        XCTAssertEqual(provider.slot, SystemCatalog.macOS)
        XCTAssertEqual(provider.engine, .vz)
        XCTAssertEqual(provider.guestOS, .macos)
        XCTAssertFalse(provider.wantsAccount, "Apple's Setup Assistant makes the account, not Tandem")
        MacOSRestoreImages.register()
        XCTAssertNotNil(SystemCatalog.provider(for: SystemCatalog.macOS))
    }

    func testOptionAndDownloadRequestComeFromTheRelease() {
        let option = MacOSRestoreImages.option(for: release, downloadBytes: 19_772_231_540)
        XCTAssertEqual(option.id, "macos-25g83")
        XCTAssertEqual(option.title, "macOS 26.6.2")
        XCTAssertTrue(option.detail.contains("25G83"))
        XCTAssertEqual(option.downloadBytes, 19_772_231_540)
        let request = MacOSRestoreImages.request(for: release, bytes: 19_772_231_540)
        XCTAssertEqual(request.fileName, "UniversalMac_26.6.2_25G83_Restore.ipsw")
        XCTAssertNil(request.checksum, "Apple publishes none; the image is checked by size and by the framework reading it")
        XCTAssertEqual(request.expectedBytes, 19_772_231_540)
    }

    func testDefaultsAndDisplay() {
        let provider = MacOSRestoreImages()
        let option = MacOSRestoreImages.option(for: release, downloadBytes: nil)
        let defaults = provider.defaults(for: option)
        XCTAssertEqual(defaults.minimumDiskGiB, 40)
        XCTAssertGreaterThanOrEqual(defaults.diskGiB, defaults.minimumDiskGiB)
        var config = VMConfig(name: "m", guestOS: .macos, engine: .vz)
        provider.adjust(&config, for: option)
        XCTAssertEqual(config.display.width, 1920)
        XCTAssertTrue(config.validate().isEmpty)
    }

    func testDiskSpaceIsCheckedBeforeTheDownload() {
        let gib: Int64 = 1 << 30
        XCTAssertNoThrow(try MacOSInstall.checkDiskSpace(freeBytes: 60 * gib, downloadBytes: 20 * gib, installBytes: 25 * gib))
        XCTAssertThrowsError(try MacOSInstall.checkDiskSpace(freeBytes: 30 * gib, downloadBytes: 20 * gib, installBytes: 25 * gib)) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("not enough free disk space") == true)
        }
        // With the image already in the cache only the install has to fit.
        XCTAssertNoThrow(try MacOSInstall.checkDiskSpace(freeBytes: 30 * gib, downloadBytes: 0, installBytes: 25 * gib))
    }

    func testLayOutWritesTheFilesTheEngineStartsFrom() throws {
        guard let hardware = VZMacHardwareModel(dataRepresentation: model), hardware.isSupported else {
            throw XCTSkip("this Mac does not support the fixture's hardware model")
        }
        var bundle = try newBundle()
        try MacOSInstall.layOut(&bundle, release: release)

        XCTAssertEqual(try Data(contentsOf: bundle.hardwareModelURL), model)
        XCTAssertNotNil(VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path))
        // Raised to what this macOS needs, and saved.
        let saved = try VMBundle.load(from: bundle.url)
        XCTAssertEqual(saved.config.cpuCount, 2)
        XCTAssertEqual(saved.config.memoryMiB, 4096)
        XCTAssertEqual(saved.config.install.state, .installing)

        // The engine's own builder accepts the result: this is the configuration the installer runs on.
        // (Validation needs the virtualization entitlement, which the test runner does not have; the
        // signed `vmctl` covers it in the real install.)
        let configuration: VZVirtualMachineConfiguration
        do { configuration = try VZConfigurationBuilder.build(for: saved) }
        catch let error as VMError where error.detail?.contains("com.apple.security.virtualization") == true {
            throw XCTSkip("the test runner is not signed with the virtualization entitlement")
        }
        XCTAssertTrue(configuration.platform is VZMacPlatformConfiguration)
        XCTAssertTrue(configuration.bootLoader is VZMacOSBootLoader)
        XCTAssertEqual(configuration.storageDevices.count, 1)
    }

    func testTwoVMsGetDifferentMachineIdentifiers() throws {
        guard let hardware = VZMacHardwareModel(dataRepresentation: model), hardware.isSupported else {
            throw XCTSkip("this Mac does not support the fixture's hardware model")
        }
        var a = try newBundle()
        try MacOSInstall.layOut(&a, release: release)
        let first = try Data(contentsOf: a.machineIdentifierURL)
        // Laying out again (a retried install) makes a new identity and new auxiliary storage.
        try MacOSInstall.layOut(&a, release: release)
        XCTAssertNotEqual(first, try Data(contentsOf: a.machineIdentifierURL))
    }

    func testLayOutRefusesWhatCannotWork() throws {
        var small = try newBundle(diskGiB: 20)
        XCTAssertThrowsError(try MacOSInstall.layOut(&small, release: release)) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("at least 40") == true)
        }
        var bad = release
        bad.hardwareModel = Data([1, 2, 3])
        var bundle = try VMLibrary(rootDirectory: root.appendingPathComponent("second")).create(
            VMConfig(name: "macOS", guestOS: .macos, engine: .vz, cpuCount: 2, memoryMiB: 4096))
        XCTAssertThrowsError(try MacOSInstall.layOut(&bundle, release: bad), "a hardware model this Mac cannot read is an unsupported host")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path))
    }
}
