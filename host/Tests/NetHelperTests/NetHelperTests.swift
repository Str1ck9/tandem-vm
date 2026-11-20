import XCTest
@testable import NetHelperClient
import VMCore

/// Runs the real helper binary in `--fake` mode (no vmnet, frames are echoed), unprivileged, on a socket
/// in a temporary directory.
final class NetHelperTests: XCTestCase {
    private var directory = ""
    private var process: Process?
    private var savedSocketPath = ""

    private var helperURL: URL {
        Bundle(for: NetHelperTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TandemNetHelper")
    }

    override func setUpWithError() throws {
        savedSocketPath = NetHelper.socketPath
        // Short on purpose: unix socket paths are limited to 103 bytes.
        directory = "/tmp/tnh-\(getpid())-\(UInt16.random(in: 0...UInt16.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NetHelper.socketPath = directory + "/c.sock"
    }

    override func tearDown() {
        process?.stopAndWait()
        NetHelper.socketPath = savedSocketPath
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Tandem's own QEMU build's qemu-nbd, which the helper runs to serve disks (the installer bundles a copy).
    private static let qemuNBD: String? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tandem/qemu/bin/qemu-nbd").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()
    private static let qemuIO: String? = qemuNBD.map { ($0 as NSString).deletingLastPathComponent + "/qemu-io" }

    private func startHelper(allowUID: uid_t = getuid(), fake: Bool = true, usbredirect: String? = nil,
                             qemuNBD: String? = NetHelperTests.qemuNBD, extra: [String] = [], environment: [String: String] = [:]) throws {
        let p = Process()
        if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        p.executableURL = helperURL
        p.arguments = ["--socket", NetHelper.socketPath, "--allow-uid", "\(allowUID)"] + (fake ? ["--fake"] : [])
            + (usbredirect.map { ["--usbredirect", $0] } ?? []) + (qemuNBD.map { ["--qemu-nbd", $0] } ?? []) + extra
        // Its error output goes to a file, so an early exit can say why (once).
        let errorPath = directory + "/helper.err"
        FileManager.default.createFile(atPath: errorPath, contents: nil)
        p.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: errorPath))
        try p.run()
        process = p
        let deadline = Date().addingTimeInterval(5)
        // The socket file appears at bind(), before listen(): wait until a connection is accepted.
        while !NetHelper.isInstalled || (try? NetHelper.Connection()) == nil {
            guard p.isRunning else {
                let reason = (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? ""
                XCTFail("the helper exited early (status \(p.terminationStatus)): \(reason)")
                throw HelperDidNotStart()
            }
            guard Date() < deadline else { XCTFail("the helper did not create its socket"); throw HelperDidNotStart() }
            usleep(20_000)
        }
    }
    private struct HelperDidNotStart: Error {}

    func testNotInstalled() {
        XCTAssertFalse(NetHelper.isInstalled)
        XCTAssertThrowsError(try NetHelper.interfaces())
    }

    func testVersionAndInterfaces() throws {
        try startHelper()
        let connection = try NetHelper.Connection()
        XCTAssertEqual(try connection.request(["op": "version"])["version"] as? Int, 4)
        XCTAssertThrowsError(try connection.request(["op": "nonsense"]))
        connection.close()
        XCTAssertEqual(try NetHelper.interfaces(), ["fake0"])
        var info = stat()
        XCTAssertEqual(lstat(NetHelper.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testBridgeEchoesFullSizeFrames() throws {
        try startHelper()
        let peer = directory + "/vm.dgram"
        // The VM's socket does not exist yet when the bridge is requested, as with QEMU.
        let lease = try NetHelper.bridge(interface: "fake0", peerPath: peer)
        XCTAssertEqual(lease.mtu, 1500)
        XCTAssertEqual(lease.maxPacketSize, 1514)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.helperSocketPath))

        let fd = try NetHelper.makeClientSocket(at: peer, connectedTo: lease.helperSocketPath)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        for size in [60, 1514] {
            let frame = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ size) }
            XCTAssertEqual(send(fd, frame, frame.count, 0), frame.count, "send of \(size) bytes: \(String(cString: strerror(errno)))")
            var back = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &back, back.count, 0)
            XCTAssertEqual(n, size)
            XCTAssertEqual(Array(back.prefix(max(n, 0))), frame)
        }

        // A second bridge on its own connection gets its own socket.
        let other = try NetHelper.bridge(interface: "fake0", peerPath: directory + "/vm2.dgram")
        XCTAssertNotEqual(other.helperSocketPath, lease.helperSocketPath)
        other.close()

        lease.close()
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: lease.helperSocketPath) && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.helperSocketPath), "the bridge socket should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.helperSocketPath))
    }

    func testBridgeRejectsBadRequests() throws {
        try startHelper()
        XCTAssertThrowsError(try NetHelper.bridge(interface: "en99", peerPath: directory + "/vm.dgram"))
        XCTAssertThrowsError(try NetHelper.bridge(interface: "fake0", peerPath: "relative.dgram"))
    }

    func testOtherUserIsRefused() throws {
        // The helper is told to serve a different user than the one running the test.
        try startHelper(allowUID: getuid() + 1)
        XCTAssertThrowsError(try NetHelper.interfaces()) { error in
            XCTAssertTrue("\(error)".contains("may not use"), "\(error)")
        }
    }

    /// Without root, vmnet refuses to make an interface. The helper must report that, not crash.
    func testRealBridgeFailsCleanlyWithoutRoot() throws {
        try XCTSkipIf(getuid() == 0, "only meaningful without root")
        try startHelper(fake: false)
        let names = try NetHelper.interfaces()
        guard let first = names.first else { throw XCTSkip("no bridgeable interface on this Mac") }
        XCTAssertThrowsError(try NetHelper.bridge(interface: first, peerPath: directory + "/vm.dgram")) { error in
            print("unprivileged bridge error: \(error)")
        }
        XCTAssertTrue(process?.isRunning ?? false, "the helper must survive a failed bridge")
        XCTAssertEqual(try NetHelper.interfaces(), names)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".dgram") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: USB

    /// A stand-in for usbredirect: connects to the `--to` address it is given and echoes every byte back,
    /// so a test can check the relay from the user's unix socket to it and back. Exits when the stream ends.
    private func fakeUsbredirect(failWith message: String? = nil) throws -> String {
        let path = directory + "/fake-usbredirect"
        let body: String
        if let message {
            body = "import sys\nsys.stderr.write(\"\(message)\\n\")\nsys.exit(1)\n"
        } else {
            body = """
            import socket, sys
            host, port = sys.argv[sys.argv.index("--to") + 1].rsplit(":", 1)
            s = socket.create_connection((host, int(port)))
            while True:
                data = s.recv(65536)
                if not data:
                    break
                s.sendall(data)

            """
        }
        try ("#!/usr/bin/python3 -I\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func testVersionSaysWhetherUSBIsOffered() throws {
        try startHelper(qemuNBD: "/usr/bin/true")
        XCTAssertEqual(try NetHelper.info(), NetHelper.Info(version: 4, features: ["bridge", "disk", "probe", "restart", "status"]))
        XCTAssertTrue(try NetHelper.info().supportsDisks)
        XCTAssertTrue(try NetHelper.info().supportsProbe)
        XCTAssertFalse(try NetHelper.info().supportsUSB)
        XCTAssertThrowsError(try NetHelper.usb(vendor: 1, product: 2, location: 3)) { error in
            XCTAssertTrue("\(error)".contains("too old"), "\(error)")
        }
    }

    func testHelperWithoutQemuNBDDoesNotOfferDisks() throws {
        try startHelper(qemuNBD: nil)
        XCTAssertEqual(try NetHelper.info(), NetHelper.Info(version: 4, features: ["bridge", "probe", "restart", "status"]))
        XCTAssertThrowsError(try NetHelper.disk(bsd: "disk9")) { error in
            XCTAssertTrue("\(error)".contains("too old"), "\(error)")
        }
    }

    func testUSBStreamIsRelayedAndEndsWithTheLease() throws {
        try startHelper(usbredirect: try fakeUsbredirect())
        XCTAssertTrue(try NetHelper.info().supportsUSB)
        let lease = try NetHelper.usb(vendor: 0x0781, product: 0x5581, location: 0x0210_0000)
        var info = stat()
        XCTAssertEqual(lstat(lease.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "only the user may open the device's socket")

        // What QEMU's usb-redir chardev does: connect to the socket, then talk.
        let fd = try UnixSocket.connect(path: lease.socketPath)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let message = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let writer = Thread {
            message.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
        writer.start()
        var back: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while back.count < message.count {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            back += chunk[0..<n]
        }
        XCTAssertEqual(back, message, "bytes must come back unchanged through the helper and the stand-in")

        lease.close()
        let deadline = Date().addingTimeInterval(8)
        while FileManager.default.fileExists(atPath: lease.socketPath) && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.socketPath), "the device's socket goes with the lease")
        // The user's side sees the stream end.
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(read(fd, &byte, 1), 0)
        close(fd)
        XCTAssertTrue(process?.isRunning ?? false)
    }

    func testUSBFailureCarriesUsbredirectsReason() throws {
        try startHelper(usbredirect: try fakeUsbredirect(failWith: "Failed to open device!"))
        XCTAssertThrowsError(try NetHelper.usb(vendor: 1, product: 2, location: 3)) { error in
            XCTAssertTrue("\(error)".contains("Failed to open device"), "\(error)")
        }
        XCTAssertTrue(process?.isRunning ?? false, "the helper must survive a failed device")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.contains("-usb-") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: Disks

    private func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let result = try ToolRun.run(URL(fileURLWithPath: path), arguments, timeout: 120)
        return result.outputText + result.errorText
    }

    /// A mounted 32 MB disk image with one FAT volume; returns its whole-disk name (`diskN`).
    private func attachTestDisk() throws -> String {
        let image = directory + "/t.dmg"
        _ = try runTool("/usr/bin/hdiutil", ["create", "-quiet", "-size", "32m", "-fs", "MS-DOS FAT16", "-volname", "TNHTEST",
                                            "-layout", "MBRSPUD", "-o", image])
        let attached = try runTool("/usr/bin/hdiutil", ["attach", image])
        guard let line = attached.split(separator: "\n").first, let name = line.split(separator: " ").first?.split(separator: "/").last else {
            throw XCTSkip("hdiutil attach failed: \(attached)")
        }
        return String(name)
    }

    private func isMounted(_ bsd: String) throws -> Bool {
        try runTool("/sbin/mount", []).contains("/dev/\(bsd)s1 ")
    }

    func testUSBDiskIsHandedOverUnmountedAndGivenBack() throws {
        try startHelper()
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        XCTAssertTrue(try isMounted(bsd), "precondition: the test volume is mounted")

        guard let qemuIO = Self.qemuIO, Self.qemuNBD != nil else { throw XCTSkip("Tandem's QEMU build (qemu-nbd, qemu-io) is not installed") }
        let lease = try NetHelper.disk(bsd: bsd)
        XCTAssertFalse(lease.readOnly)
        XCTAssertEqual(lease.size, 32 * 1024 * 1024)
        XCTAssertFalse(try isMounted(bsd), "the Mac must not have the volume mounted while the VM has the disk")
        // The disk is served over NBD on a socket in a folder only this user may enter; the device node
        // itself is left as it was (macOS 26 refuses even root a chown of it).
        var info = stat()
        XCTAssertEqual(stat(lease.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        var folder = stat()
        XCTAssertEqual(stat((lease.socketPath as NSString).deletingLastPathComponent, &folder), 0)
        XCTAssertEqual(folder.st_mode & 0o777, 0o711, "the folder stays the helper's: passable, not listable")
        XCTAssertEqual(folder.st_uid, getuid())
        // Read the MBR's signature through NBD, the way QEMU does: bytes 510-511 are 55 aa.
        let read = try runTool(qemuIO, ["--image-opts", "driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=\(lease.socketPath)",
                                        "-c", "read -v 0 512"])
        XCTAssertTrue(read.contains("000001f0:") && read.contains("55 aa"), "the first sector ends in the MBR signature: \(read)")
        // The Mac does not mount it while it is lent, even when asked.
        _ = try runTool("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsd)"])
        XCTAssertFalse(try isMounted(bsd), "mounting is refused while the VM has the disk")

        lease.release()
        let deadline = Date().addingTimeInterval(10)
        while !(try isMounted(bsd)) && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(try isMounted(bsd), "released disks are mounted on the Mac again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (lease.socketPath as NSString).deletingLastPathComponent), "the socket folder is removed")
        XCTAssertTrue(process?.isRunning ?? false)
    }

    func testDiskProbeReportsWithoutChangingAnything() throws {
        try startHelper()
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        let probe = try NetHelper.diskProbe(bsd: bsd)
        XCTAssertEqual(probe.bsd, bsd)
        XCTAssertEqual(probe.raw?.path, "/dev/r\(bsd)")
        XCTAssertEqual(probe.raw?.stat, "ok")
        XCTAssertEqual(probe.block?.path, "/dev/\(bsd)")
        XCTAssertEqual(probe.effectiveUID, Int(geteuid()))
        XCTAssertNotNil(probe.fullDiskAccess)
        // An image this user attached opens for this user; the probe says so and changes nothing.
        XCTAssertEqual(probe.raw?.openRead, "ok", probe.report.joined(separator: "\n"))
        XCTAssertTrue(probe.canServe)
        XCTAssertTrue(try isMounted(bsd), "probing leaves the disk mounted")
        XCTAssertThrowsError(try NetHelper.diskProbe(bsd: "../etc")) { error in XCTAssertTrue("\(error)".contains("whole disk"), "\(error)") }
    }

    func testProbeVerdictNamesFullDiskAccessWhenRootIsRefused() {
        func probe(read: String, write: String = "ok", fda: String) -> DiskProbe {
            DiskProbe(["ok": true, "bsd": "disk5", "euid": 0, "fullDiskAccess": fda,
                       "raw": ["path": "/dev/rdisk5", "stat": "ok", "openRead": read, "openWrite": write, "chown": "Operation not permitted"],
                       "block": ["path": "/dev/disk5", "stat": "ok", "openRead": read, "openWrite": write, "chown": "Operation not permitted"]])
        }
        let refused = probe(read: "Operation not permitted", write: "Operation not permitted", fda: "no")
        XCTAssertFalse(refused.canServe)
        XCTAssertTrue(refused.verdict.contains("Full Disk Access for '\(TandemIdentity.scriptHelper)'"), refused.verdict)
        XCTAssertTrue(refused.verdict.contains("/Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper)"), refused.verdict)
        let fine = probe(read: "ok", fda: "no")
        XCTAssertTrue(fine.canServe)
        XCTAssertTrue(fine.verdict.contains("can be served"), fine.verdict)
        let readOnly = probe(read: "ok", write: "Resource busy", fda: "yes")
        XCTAssertTrue(readOnly.verdict.contains("reading only"), readOnly.verdict)
        let stillRefused = probe(read: "Operation not permitted", fda: "yes")
        XCTAssertTrue(stillRefused.verdict.contains("even though"), stillRefused.verdict)
        XCTAssertEqual(refused.report.count, 4)
    }

    func testDiskThatIsDroppedWithoutReleaseStaysUnmounted() throws {
        try startHelper()
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        let lease = try NetHelper.disk(bsd: bsd)
        lease.abandon()
        usleep(1_000_000)
        XCTAssertFalse(try isMounted(bsd), "the VM may still hold it, so it is not mounted again")
    }

    /// Review R09: a second connection may not lend a disk that one connection already lends.
    func testADiskLentOnOneConnectionIsRefusedOnAnother() throws {
        guard Self.qemuNBD != nil else { throw XCTSkip("Tandem's QEMU build (qemu-nbd) is not installed") }
        try startHelper()
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        let first = try NetHelper.disk(bsd: bsd)
        XCTAssertThrowsError(try NetHelper.disk(bsd: bsd)) { error in
            XCTAssertTrue("\(error)".contains("already lent"), "\(error)")
        }
        // The refused attempt must not have taken the first lease's protection away.
        _ = try runTool("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsd)"])
        XCTAssertFalse(try isMounted(bsd), "still refused: the first lease holds the disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.socketPath), "the first lease's server still runs")
        XCTAssertNil(first.release())
        try waitUntilMounted(bsd)
    }

    /// Review R09: the delayed clean-up of a dropped lease must not end the protection of a newer lease.
    func testCleanupOfADroppedLeaseLeavesTheNextLeaseProtected() throws {
        guard Self.qemuNBD != nil else { throw XCTSkip("Tandem's QEMU build (qemu-nbd) is not installed") }
        try startHelper(extra: ["--disk-cooldown", "1"])
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        let old = try NetHelper.disk(bsd: bsd)
        old.abandon()
        // A dropped lease's disk may be taken over at once (the same VM starting again, typically).
        var newer: DiskLease?
        let deadline = Date().addingTimeInterval(5)
        while newer == nil, Date() < deadline {
            newer = try? NetHelper.disk(bsd: bsd)
            if newer == nil { usleep(100_000) }
        }
        let lease = try XCTUnwrap(newer, "the dropped disk can be lent again")
        usleep(2_000_000)   // the old lease's 1 s clean-up has run
        _ = try runTool("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsd)"])
        XCTAssertFalse(try isMounted(bsd), "the newer lease keeps the disk unmounted")
        XCTAssertNil(lease.release())
        try waitUntilMounted(bsd)
    }

    /// Review R10: when the server cannot start, the protection is lifted first and the disk mounted again.
    func testAFailedHandoffGivesTheDiskBackToTheMac() throws {
        let failing = directory + "/failing-qemu-nbd"
        try "#!/bin/sh\necho 'cannot open the disk: test failure' >&2\nexit 1\n".write(toFile: failing, atomically: true, encoding: .utf8)
        chmod(failing, 0o755)
        try startHelper(qemuNBD: failing)
        let bsd = try attachTestDisk()
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(bsd)"]) }
        XCTAssertThrowsError(try NetHelper.disk(bsd: bsd)) { error in
            XCTAssertTrue("\(error)".contains("test failure"), "the server's reason is passed on: \(error)")
            XCTAssertFalse("\(error)".contains("could not mount"), "the remount worked: \(error)")
        }
        XCTAssertTrue(try isMounted(bsd), "the volume is mounted again straight away")
        // And the disk is free for the next try.
        XCTAssertThrowsError(try NetHelper.disk(bsd: bsd)) { error in
            XCTAssertFalse("\(error)".contains("already lent"), "\(error)")
        }
    }

    private func waitUntilMounted(_ bsd: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while !(try isMounted(bsd)) && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(try isMounted(bsd), "released disks are mounted on the Mac again")
    }

    func testOnlyWholeUSBDisksAreHandedOver() throws {
        try startHelper()
        XCTAssertThrowsError(try NetHelper.disk(bsd: "disk0")) { error in
            XCTAssertTrue("\(error)".contains("not a USB disk"), "the Mac's internal disk must be refused: \(error)")
        }
        XCTAssertThrowsError(try NetHelper.disk(bsd: "disk0s1")) { error in
            XCTAssertTrue("\(error)".contains("whole disk"), "\(error)")
        }
        XCTAssertThrowsError(try NetHelper.disk(bsd: "../etc/passwd")) { error in
            XCTAssertTrue("\(error)".contains("whole disk"), "\(error)")
        }
        XCTAssertThrowsError(try NetHelper.disk(bsd: "disk987")) { error in
            XCTAssertTrue("\(error)".contains("no disk"), "\(error)")
        }
    }

    /// Outside fake mode the device is looked up in the Mac's USB registry first.
    func testUnpluggedDeviceIsReported() throws {
        try startHelper(fake: false, usbredirect: try fakeUsbredirect())
        XCTAssertThrowsError(try NetHelper.usb(vendor: 0xFFFF, product: 0xFFFE, location: 0x7F00_0000)) { error in
            XCTAssertTrue("\(error)".contains("not plugged in"), "\(error)")
        }
    }

    func testStatusSaysWhoItIs() throws {
        try startHelper()
        let status = try NetHelper.status()
        XCTAssertEqual(status.version, 4)
        XCTAssertTrue(status.features.contains("status"))
        XCTAssertTrue(status.canRestart)
        XCTAssertEqual(status.fromBundle, false)
        XCTAssertEqual(status.pid, Int(process?.processIdentifier ?? -1))
        XCTAssertEqual(status.busy, 0)
        XCTAssertNotNil(status.fullDiskAccess)
    }

    /// The label launchd started it under (XPC_SERVICE_NAME) is in its status, so the app can tell whose helper
    /// is running (a daemon registered by another copy of Tandem has another label).
    func testStatusReportsTheLaunchdLabel() throws {
        try startHelper(environment: ["XPC_SERVICE_NAME": "org.example.other.helper"])
        let other = try NetHelper.status()
        XCTAssertEqual(other.label, "org.example.other.helper")
        process?.stopAndWait(); process = nil
        unlink(NetHelper.socketPath)
        try startHelper(environment: ["XPC_SERVICE_NAME": TandemIdentity.helper])
        XCTAssertEqual(try NetHelper.status().label, TandemIdentity.helper)
    }

    func testRestartWaitsForVMsThenExits() throws {
        try startHelper()
        let lease = try NetHelper.bridge(interface: "fake0", peerPath: directory + "/vm.dgram")
        XCTAssertEqual(try NetHelper.status().busy, 1)
        XCTAssertThrowsError(try NetHelper.restart()) { error in
            XCTAssertTrue("\((error as? VMError)?.detail ?? "")".contains("stop those VMs first"), "\(error)")
        }
        XCTAssertTrue(process?.isRunning == true)
        lease.close()
        let deadline = Date().addingTimeInterval(5)
        while (try? NetHelper.status().busy) != 0, Date() < deadline { usleep(50_000) }
        try NetHelper.restart()
        // Under launchd KeepAlive starts it again; here it simply exits.
        let gone = Date().addingTimeInterval(5)
        while process?.isRunning == true, Date() < gone { usleep(50_000) }
        XCTAssertFalse(process?.isRunning == true, "the helper did not exit after restart")
    }
}
