import XCTest
@testable import VMCore

final class CompatibilityTests: XCTestCase {
    /// A Mac with everything installed.
    private func mac(_ change: (inout HostFacts) -> Void = { _ in }) -> HostFacts {
        var host = HostFacts(chip: "Apple M2 Pro", isAppleSilicon: true, macOSMajor: 15, macOSMinor: 5, memoryGiB: 32, cores: 12,
                             freeDiskGiB: 100, qemuVersion: "QEMU emulator version 11.1.3", qemuIsTandemBuild: true, swtpm: true, zstd: true,
                             networkHelper: true, rosetta: true, driverDisc: true, windowsGuestTools: true, linuxGuestTools: true)
        change(&host)
        return host
    }

    private func report(_ host: HostFacts, _ os: GuestOS, arch: GuestArchitecture = .arm64, engine: EngineKind? = nil,
                        memoryMiB: Int? = nil, cpus: Int? = nil, disk: Int? = nil) -> CompatibilityReport {
        Compatibility.evaluate(host: host, request: CompatibilityRequest(guestOS: os, architecture: arch, engine: engine,
                                                                         memoryMiB: memoryMiB, cpuCount: cpus, neededDiskGiB: disk))
    }

    func testWindowsOnAFullyEquippedMacCanBeCreated() {
        let r = report(mac(), .windows11arm)
        XCTAssertTrue(r.canProceed)
        XCTAssertEqual(r.finding("guest")?.level, .supported)
        XCTAssertEqual(r.finding("tpm")?.level, .supported)
        XCTAssertEqual(r.finding("seamless")?.level, .experimental)
        XCTAssertTrue(r.summary.hasPrefix("Ready"))
    }

    func testNothingUnprovenIsReportedAsSupported() {
        for os in GuestOS.allCases {
            let r = report(mac(), os)
            XCTAssertEqual(r.finding("3d")?.level, .notSupported, "3D acceleration has not been built")
            XCTAssertNotEqual(r.finding("usb")?.level, .supported, "USB pass-through has never met a real device")
        }
        XCTAssertEqual(report(mac(), .windows11arm).finding("usb")?.level, .unverified)
        // Rosetta for Linux is offered by Apple's engine but Tandem has not attached or run it.
        XCTAssertEqual(report(mac(), .linux, engine: .vz).finding("intelLinux")?.level, .unverified)
        XCTAssertEqual(report(mac(), .linux, engine: .qemu).finding("intelLinux")?.level, .notSupported)
        XCTAssertEqual(report(mac { $0.rosetta = false }, .linux, engine: .vz).finding("intelLinux")?.level, .needsPrerequisite)
        XCTAssertNil(report(mac(), .windows11arm).finding("intelLinux"), "only Linux guests are asked about Intel Linux programs")
    }

    func testIntelGuestsAreRefused() {
        for os in [GuestOS.windows11arm, .linux] {
            let r = report(mac(), os, arch: .x86_64)
            XCTAssertFalse(r.canProceed)
            XCTAssertEqual(r.blockers.map(\.id), ["guest"])
            XCTAssertEqual(r.finding("guest")?.level, .notSupported)
        }
    }

    func testMissingPrerequisitesBlockOnlyWhereTheVMCannotStart() {
        // No software TPM: Windows cannot be created, Linux can.
        XCTAssertEqual(report(mac { $0.swtpm = false }, .windows11arm).blockers.map(\.id), ["tpm"])
        XCTAssertTrue(report(mac { $0.swtpm = false }, .linux, engine: .qemu).canProceed)
        // No QEMU at all blocks the QEMU engine but not Apple's.
        XCTAssertEqual(report(mac { $0.qemuVersion = nil; $0.qemuIsTandemBuild = false }, .linux, engine: .qemu).blockers.map(\.id), ["qemu"])
        XCTAssertTrue(report(mac { $0.qemuVersion = nil; $0.qemuIsTandemBuild = false }, .linux, engine: .vz).canProceed)
        // Things that only cost a feature do not block: the helper, the driver disc, a stock QEMU.
        let soft = report(mac { $0.networkHelper = false; $0.driverDisc = false; $0.qemuIsTandemBuild = false }, .windows11arm)
        XCTAssertTrue(soft.canProceed)
        XCTAssertEqual(soft.finding("bridged")?.level, .needsPrerequisite)
        XCTAssertNotNil(soft.finding("bridged")?.fix)
        XCTAssertEqual(soft.finding("drivers")?.level, .needsPrerequisite)
        XCTAssertEqual(soft.finding("resolution")?.level, .needsPrerequisite)
        XCTAssertEqual(soft.finding("qemu")?.level, .needsPrerequisite)
        XCTAssertTrue(soft.summary.contains("4 optional features need setup"), soft.summary)
    }

    func testEngineAndGuestMustMatch() {
        XCTAssertEqual(report(mac(), .macos, engine: .qemu).blockers.map(\.id), ["guest"])
        XCTAssertEqual(report(mac(), .windows11arm, engine: .vz).blockers.map(\.id), ["guest"])
        XCTAssertTrue(report(mac(), .macos).canProceed)
        XCTAssertEqual(report(mac(), .macos).finding("clipboard")?.level, .notSupported)
    }

    func testTheMacItself() {
        XCTAssertEqual(report(mac { $0.isAppleSilicon = false; $0.chip = "Intel Core i9" }, .linux).blockers.first?.id, "host")
        let old = report(mac { $0.macOSMajor = 14 }, .linux)
        XCTAssertEqual(old.finding("host")?.level, .needsPrerequisite)
        XCTAssertFalse(old.canProceed)
    }

    func testResourcesMustFit() {
        XCTAssertEqual(report(mac(), .linux, memoryMiB: 64 * 1024).blockers.map(\.id), ["memory"])
        let tight = report(mac(), .linux, memoryMiB: 28 * 1024)
        XCTAssertTrue(tight.canProceed)
        XCTAssertEqual(tight.finding("memory")?.level, .experimental)
        XCTAssertNil(report(mac(), .linux, memoryMiB: 8192).finding("memory"))
        XCTAssertEqual(report(mac(), .linux, cpus: 16).blockers.map(\.id), ["cpu"])
        XCTAssertEqual(report(mac { $0.freeDiskGiB = 5 }, .windows11arm, disk: 20).blockers.map(\.id), ["disk"])
    }

    func testReportRoundTripsThroughJSONAndPrints() throws {
        let r = report(mac { $0.swtpm = false }, .windows11arm)
        let decoded = try JSONDecoder().decode(CompatibilityReport.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
        let text = r.text()
        XCTAssertTrue(text.contains("brew install swtpm"))
        XCTAssertTrue(text.hasSuffix("Result: 1 blocking problem."))
    }

    // MARK: Installer images

    func testArchitectureFromFileNames() {
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "Win11_25H2_English_x64.iso"), .x86_64)
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "Windows11_Client_arm64_en-us_26300_9457.iso"), .arm64)
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "ubuntu-24.04.3-desktop-amd64.iso"), .x86_64)
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "ubuntu-24.04.3-live-server-arm64.iso"), .arm64)
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "Fedora-Workstation-Live-aarch64-41.iso"), .arm64)
        XCTAssertEqual(InstallerImage.architecture(fromFileName: "debian-12.8.0-x86_64-netinst.iso"), .x86_64)
        XCTAssertNil(InstallerImage.architecture(fromFileName: "kali-linux-2025.2-installer.iso"))
        XCTAssertNil(InstallerImage.architecture(fromFileName: "max64-tools.iso"), "x64 must be a word of its own")
    }

    func testArchitectureFromTheDiscsBootFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func disc(_ name: String, _ records: [Data]) throws -> URL {
            // Padding puts a name across the 4 MiB boundary the scanner reads in, to prove nothing is lost there.
            var data = Data(repeating: 0, count: (4 << 20) - 5)
            for record in records { data.append(record); data.append(Data(repeating: 0x20, count: 3000)) }
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        func wide(_ s: String) -> Data { var d = Data(); for b in s.utf8 { d.append(0); d.append(b) }; return d }
        XCTAssertEqual(InstallerImage.architecture(scanning: try disc("a.iso", [Data("BOOTAA64.EFI;1".utf8)])), .arm64)
        XCTAssertEqual(InstallerImage.architecture(scanning: try disc("b.iso", [Data("bootx64.efi".utf8)])), .x86_64)
        XCTAssertEqual(InstallerImage.architecture(scanning: try disc("c.iso", [wide("BOOTX64.EFI")])), .x86_64, "Joliet names are 16-bit")
        XCTAssertEqual(InstallerImage.architecture(scanning: try disc("d.iso", [Data("BOOTX64.EFI".utf8), Data("BOOTAA64.EFI".utf8)])), .arm64,
                       "a disc with both loaders starts on ARM")
        XCTAssertNil(InstallerImage.architecture(scanning: try disc("e.iso", [Data("NOTHING.TXT".utf8)])))
        // The disc's own files win over a misleading name.
        let renamed = try disc("windows-x64.iso", [Data("BOOTAA64.EFI".utf8)])
        XCTAssertEqual(InstallerImage.inspect(renamed), InstallerImage.Guess(architecture: .arm64, evidence: "boot files on the disc"))
        XCTAssertEqual(InstallerImage.inspect(try disc("thing-amd64.iso", [])), InstallerImage.Guess(architecture: .x86_64, evidence: "file name"))
    }
}
