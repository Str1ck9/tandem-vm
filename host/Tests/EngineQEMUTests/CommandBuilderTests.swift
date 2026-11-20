import XCTest
import VMCore
@testable import EngineQEMU

final class CommandBuilderTests: XCTestCase {
    var root: URL!
    let toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/x/bin/qemu-system-aarch64"), qemuImg: URL(fileURLWithPath: "/x/bin/qemu-img"),
                                  swtpm: URL(fileURLWithPath: "/x/bin/swtpm"), firmwareCode: URL(fileURLWithPath: "/x/share/code.fd"),
                                  firmwareVarsTemplate: URL(fileURLWithPath: "/x/share/vars.fd"), qemuVersion: "QEMU emulator version 11.1.3")
    let paths = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tandem-test"))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-qemu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func args(_ config: VMConfig, display: QEMUDisplayMode = .none) throws -> [String] {
        let bundle = try VMBundle.create(config: config, in: root)
        return try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: display)
    }
    func value(_ a: [String], after flag: String, containing needle: String) -> String? {
        zip(a, a.dropFirst()).first { $0.0 == flag && $0.1.contains(needle) }?.1
    }

    func testWindowsGetsTPMNVMeRamfbAndLocalRTC() throws {
        var config = VMConfig(name: "win", guestOS: .windows11arm, cpuCount: 4, memoryMiB: 8192)
        config.removableMedia = [RemovableMedia(file: "/isos/win.iso", kind: .installerISO)]
        let a = try args(config)
        XCTAssertNotNil(value(a, after: "-device", containing: "nvme,drive=disk0"))
        XCTAssertNotNil(value(a, after: "-device", containing: "tpm-tis-device,tpmdev=tpm0,ppi=off"), "ppi must be off under HVF")
        XCTAssertNotNil(value(a, after: "-chardev", containing: "path=/tmp/tandem-test/tpm.sock"))
        XCTAssertTrue(a.contains("ramfb"))
        XCTAssertNotNil(value(a, after: "-rtc", containing: "base=localtime"))
        XCTAssertNotNil(value(a, after: "-device", containing: "usb-storage,bus=usb.0,drive=media0,removable=on,bootindex=1"))
        XCTAssertNotNil(value(a, after: "-drive", containing: "media=cdrom,format=raw,readonly=on,file=/isos/win.iso"))
        XCTAssertNotNil(value(a, after: "-smp", containing: "4"))
        XCTAssertNotNil(value(a, after: "-m", containing: "8192"))
    }

    func testDataFolderIsPassedOnlyWhenQEMUCannotFindItsOwn() throws {
        let config = VMConfig(name: "data", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 512)
        XCTAssertFalse(try args(config).contains("-L"), "a QEMU with share/ next to bin/ finds its data itself")
        var packaged = toolchain
        packaged.dataDirectory = URL(fileURLWithPath: "/Applications/Tandem.app/Contents/Resources/qemu")
        let bundle = try VMBundle.create(config: VMConfig(name: "data2", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 512), in: root)
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: packaged, paths: paths, display: .none)
        let i = try XCTUnwrap(a.firstIndex(of: "-L"))
        XCTAssertEqual(a[i + 1], "/Applications/Tandem.app/Contents/Resources/qemu")
    }

    func testLinuxHasNoTPMAndUsesVirtio() throws {
        let a = try args(VMConfig(name: "lin", guestOS: .linux, engine: .qemu))
        XCTAssertFalse(a.contains { $0.contains("tpm") })
        XCTAssertNotNil(value(a, after: "-device", containing: "virtio-blk-pci,drive=disk0"))
        XCTAssertTrue(a.contains { $0.hasPrefix("virtio-gpu-pci,xres=") })
        XCTAssertFalse(a.contains("-rtc"))
    }

    func testEveryVMGetsHVFFirmwareGuestChannelAndQMP() throws {
        let a = try args(VMConfig(name: "any", guestOS: .linux, engine: .qemu))
        XCTAssertNotNil(value(a, after: "-machine", containing: "accel=hvf"))
        XCTAssertNotNil(value(a, after: "-drive", containing: "if=pflash,format=raw,readonly=on,file=/x/share/code.fd"))
        XCTAssertNotNil(value(a, after: "-drive", containing: "efi-vars.fd"))
        XCTAssertNotNil(value(a, after: "-device", containing: "virtserialport,chardev=gl,name=guestlink.0"))
        XCTAssertNotNil(value(a, after: "-qmp", containing: "unix:/tmp/tandem-test/qmp.sock,server=on,wait=off"))
        XCTAssertTrue(a.contains("-nodefaults"))
    }

    func testDisplayModes() throws {
        let headless = try args(VMConfig(name: "h", guestOS: .linux, engine: .qemu), display: .none)
        XCTAssertNotNil(value(headless, after: "-display", containing: "none"))
        XCTAssertFalse(headless.contains("-audiodev"))
        let window = try args(VMConfig(name: "w", guestOS: .linux, engine: .qemu), display: .cocoa)
        XCTAssertNotNil(value(window, after: "-display", containing: "cocoa"))
        XCTAssertTrue(window.contains("-audiodev"))
    }

    func testPublishedServicesGetPrivateLoopbackForwardsOnTheSharedNetworkOnly() throws {
        var config = VMConfig(name: "svc", guestOS: .linux, engine: .qemu)
        config.network.mac = "02:00:00:00:00:02"
        let bundle = try VMBundle.create(config: config, in: root)
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none,
                                                 serviceBackends: [8080: 40001, 22: 40002])
        // The relay in front decides who may connect; QEMU itself never listens beyond this Mac.
        XCTAssertNotNil(value(a, after: "-netdev", containing: "user,id=net0,hostfwd=tcp:127.0.0.1:40002-:22,hostfwd=tcp:127.0.0.1:40001-:8080"))
        XCTAssertFalse(a.contains { $0.contains("0.0.0.0") })
    }

    func testPortForwardsBindToLoopback() throws {
        var config = VMConfig(name: "pf", guestOS: .linux, engine: .qemu)
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22), PortForward(hostPort: 3389, guestPort: 3389)]
        config.network.mac = "02:00:00:00:00:01"
        let a = try args(config)
        XCTAssertNotNil(value(a, after: "-netdev", containing: "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:3389-:3389"))
        XCTAssertNotNil(value(a, after: "-device", containing: "virtio-net-pci,netdev=net0,mac=02:00:00:00:00:01"))
    }

    func testRejectsWrongEngineAndMacOS() throws {
        let vz = try VMBundle.create(config: VMConfig(name: "vz", guestOS: .linux), in: root)
        XCTAssertThrowsError(try QEMUCommandBuilder.arguments(bundle: vz, toolchain: toolchain, paths: paths, display: .none))
    }

    func testRunPathsFitUnixSocketLimit() {
        let p = QEMURunPaths.forVM(UUID())
        for path in [p.qmp, p.guestLink, p.tpm, p.display, p.network] { XCTAssertLessThanOrEqual(path.utf8.count, UnixSocket.maxPathLength, path) }
    }

    /// R16: two VMs whose identifiers start alike never share sockets.
    func testRunPathsUseTheWholeIdentifier() throws {
        let a = try XCTUnwrap(UUID(uuidString: "ABCDEF01-0000-4000-8000-00000000000A"))
        let b = try XCTUnwrap(UUID(uuidString: "ABCDEF01-0000-4000-8000-00000000000B"))
        XCTAssertNotEqual(QEMURunPaths.forVM(a).directory, QEMURunPaths.forVM(b).directory)
        XCTAssertTrue(RunFolder.names(for: a).contains(QEMURunPaths.forVM(a).directory.lastPathComponent))
    }

    /// Review R14: every path inside a comma-separated QEMU option has its commas doubled.
    func testPathsWithCommasAreEscapedInEveryOption() throws {
        root = root.appendingPathComponent("Work, Archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = VMConfig(name: "Win, test", guestOS: .windows11arm, cpuCount: 2, memoryMiB: 4096)
        config.removableMedia = [RemovableMedia(file: "/Volumes/ISOs, old/win.iso", kind: .installerISO)]
        let bundle = try VMBundle.create(config: config, in: root)
        let commaPaths = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tandem,run"))
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: commaPaths, display: .embedded)
        XCTAssertEqual(value(a, after: "-name", containing: "Win"), "Win,, test")
        // Read back the way QEMU does (",," is a comma, "," ends the value), every file is whole.
        let expected = Set([toolchain.firmwareCode.path, bundle.efiVarsURL.path, bundle.diskURL(bundle.config.disks[0]).path,
                            "/Volumes/ISOs, old/win.iso"])
        let files = zip(a, a.dropFirst()).filter { $0.0 == "-drive" }.compactMap { _, drive -> String? in
            guard let file = drive.range(of: "file=") else { return nil }
            return String(drive[file.upperBound...]).replacingOccurrences(of: ",,", with: "\u{0}")
                .split(separator: ",").first.map { $0.replacingOccurrences(of: "\u{0}", with: ",") }
        }
        XCTAssertEqual(Set(files), expected)
        XCTAssertNotNil(value(a, after: "-drive", containing: "file=\(bundle.url.path.replacingOccurrences(of: ",", with: ",,"))/"))
        XCTAssertNotNil(value(a, after: "-drive", containing: "file=/Volumes/ISOs,, old/win.iso"))
        XCTAssertNotNil(value(a, after: "-chardev", containing: "path=/tmp/tandem,,run/tpm.sock"))
        XCTAssertNotNil(value(a, after: "-chardev", containing: "path=/tmp/tandem,,run/gl.sock,server=on"))
        XCTAssertEqual(value(a, after: "-qmp", containing: "unix:"), "unix:/tmp/tandem,,run/qmp.sock,server=on,wait=off")
        XCTAssertEqual(value(a, after: "-vnc", containing: "unix:"), "unix:/tmp/tandem,,run/vnc.sock")
        // -serial file: takes its path as it is (QEMU does not undo doubled commas there).
        XCTAssertEqual(value(a, after: "-serial", containing: "file:"), "file:\(bundle.logsDirectory.path)/console.log")
        // swtpm cannot take a comma at all: it is given links in the run folder instead.
        let s = QEMUCommandBuilder.swtpmArguments(bundle: bundle, paths: commaPaths)
        XCTAssertEqual(value(s, after: "--tpmstate", containing: "dir="), "dir=/tmp/tandem,run/tpm-state")
        XCTAssertEqual(value(s, after: "--log", containing: "file="), "file=/tmp/tandem,run/logs/swtpm.log,level=1")
        XCTAssertEqual(QEMUCommandBuilder.swtpmLinks(bundle: bundle, paths: commaPaths).map(\.target),
                       [bundle.tpmDirectory.path, bundle.logsDirectory.path])
        XCTAssertEqual(QEMUOption.value("a,b,,c"), "a,,b,,,,c")
    }

    /// Review R14, checked against the real parser: Tandem's QEMU opens a disk in a folder with a comma.
    func testTandemsQEMUParsesTheEscapedPath() throws {
        let qemu = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tandem/qemu/bin/qemu-system-aarch64")
        guard FileManager.default.isExecutableFile(atPath: qemu.path) else { throw XCTSkip("Tandem's QEMU is not installed") }
        let folder = root.appendingPathComponent("Work, Archive")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let disk = folder.appendingPathComponent("disk,1.img")
        try DiskImage.createSparseRaw(at: disk, sizeGiB: 1)
        func launch(_ drive: String) throws -> (alive: Bool, output: String) {
            let p = Process()
            p.executableURL = qemu
            p.arguments = ["-machine", "none", "-nodefaults", "-display", "none", "-drive", drive]
            let out = root.appendingPathComponent("qemu-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            p.standardOutput = handle; p.standardError = handle
            try p.run()
            usleep(1_000_000)
            let alive = p.isRunning
            let output = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            p.stopAndWait()
            return (alive, output)
        }
        let escaped = try launch("if=none,id=d,format=raw,file=\(QEMUOption.value(disk.path))")
        XCTAssertTrue(escaped.alive && escaped.output.isEmpty, "the escaped path opens: \(escaped.output)")
        let plain = try launch("if=none,id=d,format=raw,file=\(disk.path)")
        XCTAssertFalse(plain.alive && plain.output.isEmpty, "unescaped, QEMU misreads it (the failure R14 describes)")
    }

    /// swtpm started the engine's way (links for comma paths) runs and writes into the VM's own folders.
    func testSwtpmRunsThroughTheLinksForCommaPaths() throws {
        guard let swtpm = ["/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("swtpm is not installed")
        }
        root = root.appendingPathComponent("Work, Archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config: VMConfig(name: "w", guestOS: .windows11arm), in: root)
        try FileManager.default.createDirectory(at: bundle.tpmDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        let run = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tsw-\(getpid())"))
        try FileManager.default.createDirectory(at: run.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        for (link, target) in QEMUCommandBuilder.swtpmLinks(bundle: bundle, paths: run) { XCTAssertEqual(symlink(target, link), 0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: swtpm)
        p.arguments = QEMUCommandBuilder.swtpmArguments(bundle: bundle, paths: run)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: run.tpm), p.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertTrue(p.isRunning, "swtpm accepted its arguments")
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.tpm), "its control socket is up")
        p.stopAndWait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.logsDirectory.appendingPathComponent("swtpm.log").path), "the log is in the VM's folder")
    }

    func testSwtpmArguments() throws {
        let bundle = try VMBundle.create(config: VMConfig(name: "t", guestOS: .windows11arm), in: root)
        let a = QEMUCommandBuilder.swtpmArguments(bundle: bundle, paths: paths)
        XCTAssertEqual(Array(a.prefix(2)), ["socket", "--tpm2"])
        XCTAssertTrue(a.contains("dir=\(bundle.tpmDirectory.path)"))
        XCTAssertTrue(a.contains("type=unixio,path=/tmp/tandem-test/tpm.sock"))
        XCTAssertTrue(a.contains("--terminate"))
    }

    func testLinuxSharedFoldersToolsDiscAndHardwareUUID() throws {
        var config = VMConfig(name: "lin", guestOS: .linux, engine: .qemu)
        config.sharedFolders = [SharedFolder(hostPath: "/Users/me/Docs", name: "Docs"), SharedFolder(hostPath: "/Users/me/a,b", name: "Odd", readOnly: true)]
        config.hardwareUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        let bundle = try VMBundle.create(config: config, in: root)
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none,
                                                 guestToolsISO: URL(fileURLWithPath: "/x/tools.iso"))
        XCTAssertNotNil(value(a, after: "-uuid", containing: "11111111-2222-3333-4444-555555555555"))
        XCTAssertNotNil(value(a, after: "-fsdev", containing: "local,id=share0,path=/Users/me/Docs,security_model=none"))
        XCTAssertEqual(value(a, after: "-fsdev", containing: "id=share1"), "local,id=share1,path=/Users/me/a,,b,security_model=none,readonly=on")
        XCTAssertNotNil(value(a, after: "-device", containing: "virtio-9p-pci,id=sharedev1,bus=shareport1,fsdev=share1,mount_tag=tandem1"))
        XCTAssertNotNil(value(a, after: "-device", containing: "pcie-root-port,id=shareport1,bus=pcie.0,chassis=2"), "each folder device is on a hot-plug port, so it can be removed from a running guest")
        XCTAssertNotNil(value(a, after: "-drive", containing: "id=tools,media=cdrom,format=raw,readonly=on,file=/x/tools.iso"))
        // Windows shares travel over the network instead, and it gets no Linux tools disc.
        var windows = VMConfig(name: "win2", guestOS: .windows11arm)
        windows.sharedFolders = config.sharedFolders
        let w = try QEMUCommandBuilder.arguments(bundle: try VMBundle.create(config: windows, in: root), toolchain: toolchain, paths: paths,
                                                 display: .none, guestToolsISO: URL(fileURLWithPath: "/x/tools.iso"))
        XCTAssertFalse(w.contains("-fsdev"))
        XCTAssertNil(value(w, after: "-drive", containing: "id=tools"))
        XCTAssertNotNil(value(w, after: "-uuid", containing: windows.id.uuidString.lowercased()))
    }

    // MARK: Sharing policy

    func testTheSharingProfileCutsTheNetworkDown() throws {
        var config = VMConfig(name: "restricted", guestOS: .windows11arm, cpuCount: 2, memoryMiB: 4096)
        config.network.mode = .bridged
        config.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        config.sharing = .restricted
        let bundle = try VMBundle.create(config: config, in: root)
        // Bridged is not allowed, so no helper socket is needed and the VM is on the shared network;
        // connections in are not allowed, so the port forward is not opened.
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none, hostServicePort: 47123)
        XCTAssertEqual(value(a, after: "-netdev", containing: "id=net0"), "user,id=net0")
        XCTAssertNil(value(a, after: "-netdev", containing: "hostfwd"))
        XCTAssertNil(value(a, after: "-netdev", containing: "id=net1"))
        // Not even when a caller hands over ports for published services.
        let b = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none, serviceBackends: [80: 48123])
        XCTAssertNil(value(b, after: "-netdev", containing: "hostfwd"))
    }

    func testAVMWithoutNetworkAccessKeepsOnlyThePathToItsMacFolders() throws {
        var config = VMConfig(name: "isolated", guestOS: .windows11arm, cpuCount: 2, memoryMiB: 4096)
        config.sharing.network.outbound = false
        let bundle = try VMBundle.create(config: config, in: root)
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none, hostServicePort: 47123)
        XCTAssertEqual(value(a, after: "-netdev", containing: "id=net0"),
                       "user,id=net0,restrict=on,guestfwd=tcp:10.0.2.2:47123-cmd:/usr/bin/nc 127.0.0.1 47123")
        let b = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none)
        XCTAssertEqual(value(b, after: "-netdev", containing: "id=net0"), "user,id=net0,restrict=on")
    }

    func testBridgedNetworkUsesTheHelperSocket() throws {
        var config = VMConfig(name: "br", guestOS: .linux, engine: .qemu)
        config.network.mode = .bridged
        let bundle = try VMBundle.create(config: config, in: root)
        XCTAssertThrowsError(try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none))
        let a = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none, bridgeSocket: "/var/run/tandem-net-1.dgram")
        XCTAssertEqual(value(a, after: "-netdev", containing: "id=net0"),
                       "dgram,id=net0,local.type=unix,local.path=/tmp/tandem-test/net.sock,remote.type=unix,remote.path=/var/run/tandem-net-1.dgram")
        XCTAssertNotNil(value(a, after: "-device", containing: "virtio-net-pci,netdev=net0,mac=\(config.network.mac)"))
        XCTAssertNil(value(a, after: "-netdev", containing: "id=net1"), "no second adapter without a folder server")
        // With shared folders served on the Mac, a bridged VM gets an isolated second adapter that reaches only them.
        let b = try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .none,
                                                 bridgeSocket: "/var/run/tandem-net-1.dgram", hostServicePort: 47123)
        XCTAssertEqual(value(b, after: "-netdev", containing: "id=net1"),
                       "user,id=net1,restrict=on,guestfwd=tcp:10.0.2.2:47123-cmd:/usr/bin/nc 127.0.0.1 47123")
        XCTAssertNotNil(value(b, after: "-device", containing: "virtio-net-pci,netdev=net1,mac=\(QEMUCommandBuilder.secondMAC(config.network.mac))"))
        XCTAssertEqual(QEMUCommandBuilder.secondMAC("02:00:00:00:00:01"), "02:00:00:00:00:81")
        // A VM on the shared network already reaches the Mac, and is resumed with -incoming.
        var nat = VMConfig(name: "nat", guestOS: .linux, engine: .qemu)
        nat.network.mode = .nat
        let c = try QEMUCommandBuilder.arguments(bundle: try VMBundle.create(config: nat, in: root), toolchain: toolchain, paths: paths,
                                                 display: .none, incoming: "file:/x/suspend.state", hostServicePort: 47123)
        XCTAssertNil(value(c, after: "-netdev", containing: "id=net1"))
        XCTAssertNotNil(value(c, after: "-incoming", containing: "file:/x/suspend.state"))
    }
}
