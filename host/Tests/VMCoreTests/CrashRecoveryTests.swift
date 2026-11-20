import XCTest
@testable import VMCore

final class CrashRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tcr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func bundle() throws -> VMBundle {
        try VMLibrary(rootDirectory: root).create(VMConfig(name: "Crashy", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
    }

    private func launch(_ path: String, _ arguments: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// The pid of a process that has come and gone.
    private func deadPID() throws -> Int32 {
        let p = try launch("/usr/bin/true", [])
        XCTAssertTrue(p.waitForExit(timeout: 10))
        return p.processIdentifier
    }

    func testRecordOfThisProcessIsAliveAndRoundTrips() throws {
        let b = try bundle()
        let record = RunRecord(childPIDs: [123], runFolder: "/tmp/x")
        XCTAssertTrue(record.hostIsAlive)
        b.writeRunRecord(record)
        XCTAssertEqual(b.readRunRecord()?.childPIDs, [123])
        XCTAssertEqual(b.readRunRecord()?.hostPID, getpid())
        XCTAssertNil(CrashRecovery.recover(b), "a VM run by a live process is not touched")
        b.clearRunRecord()
        XCTAssertNil(b.readRunRecord())
    }

    func testAReusedProcessNumberDoesNotCountAsTheHost() throws {
        let other = try launch("/bin/sleep", ["30"])
        defer { other.stopAndWait() }
        // Same number, but another program: the host that wrote the record is gone.
        let record = RunRecord(hostPID: other.processIdentifier, hostName: "Tandem", hostStarted: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(record.hostIsAlive)
    }

    func testRecoveryCleansUpAfterADeadHostAndSaysSo() throws {
        let b = try bundle()
        let fm = FileManager.default
        // Leftovers of a run: QEMU's socket folder, a half-written suspend file, temporary grants, drops.
        let runFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(RunFolder.name(for: b.id))
        try fm.createDirectory(at: runFolder, withIntermediateDirectories: true)
        fm.createFile(atPath: runFolder.appendingPathComponent("qmp.sock").path, contents: nil)
        fm.createFile(atPath: b.url.appendingPathComponent(".suspend.partial").path, contents: Data([1]))
        try fm.createDirectory(at: b.runDirectory.appendingPathComponent("drops"), withIntermediateDirectories: true)
        fm.createFile(atPath: b.runDirectory.appendingPathComponent("temporary-sharing.json").path, contents: Data("{}".utf8))
        // A child that is not QEMU or swtpm must never be signalled, whatever the record says.
        let bystander = try launch("/bin/sleep", ["30"])
        defer { bystander.stopAndWait() }
        b.writeRunRecord(RunRecord(hostPID: try deadPID(), hostName: "Tandem", childPIDs: [bystander.processIdentifier],
                                   runFolder: runFolder.path))

        let outcome = try XCTUnwrap(CrashRecovery.recover(b))
        XCTAssertEqual(outcome.stoppedProcesses, 0)
        XCTAssertTrue(bystander.isRunning, "an unrelated process is left alone")
        XCTAssertFalse(fm.fileExists(atPath: runFolder.path))
        XCTAssertFalse(fm.fileExists(atPath: b.url.appendingPathComponent(".suspend.partial").path))
        XCTAssertFalse(fm.fileExists(atPath: b.runDirectory.appendingPathComponent("drops").path))
        XCTAssertFalse(fm.fileExists(atPath: b.runDirectory.appendingPathComponent("temporary-sharing.json").path))
        XCTAssertNil(b.readRunRecord())
        XCTAssertTrue(outcome.message.contains("“Crashy” was stopped because Tandem quit unexpectedly"))
        XCTAssertNil(CrashRecovery.recover(b), "it is said once")
    }

    func testOnlyTandemsOwnTemporaryFoldersAreDeleted() {
        let temp = NSTemporaryDirectory()
        XCTAssertTrue(CrashRecovery.isOwnRunFolder(temp + "tandem-1234abcd"))
        XCTAssertFalse(CrashRecovery.isOwnRunFolder(temp + "somebody-else"))
        XCTAssertFalse(CrashRecovery.isOwnRunFolder("/Users/someone/tandem-1234abcd"))
        XCTAssertFalse(CrashRecovery.isOwnRunFolder(temp + "tandem-x/../../etc"))
    }

    func testAVMRunByAnotherLiveProcessCannotBeStartedHere() throws {
        let b = try bundle()
        let other = try launch("/bin/sleep", ["30"])
        defer { other.stopAndWait() }
        b.writeRunRecord(RunRecord(hostPID: other.processIdentifier, hostName: "sleep",
                                   hostStarted: RunRecord.processStart(other.processIdentifier)))
        XCTAssertThrowsError(try CrashRecovery.requireNotRunningElsewhere(b)) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("already running in another program") == true)
        }
        XCTAssertNil(CrashRecovery.recover(b), "a live run is never cleaned up")
    }

    // MARK: R08: a recorded process number is never enough to signal a process

    /// A stand-in for a VM's QEMU: a program that only sleeps, under QEMU's name, so only its identity tells
    /// it apart. (A copy of /bin/sleep is not allowed to run elsewhere, so it is built here.)
    private func fakeQEMU() throws -> Process {
        let dir = root.appendingPathComponent("fake-qemu")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("sleeper.c")
        try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let path = dir.appendingPathComponent("qemu-system-aarch64").path
        let cc = try launch("/usr/bin/cc", ["-o", path, source.path])
        XCTAssertTrue(cc.waitForExit(timeout: 60))
        guard cc.terminationStatus == 0 else { throw XCTSkip("no C compiler to build a stand-in process") }
        let p = try launch(path, [])
        usleep(150_000)
        XCTAssertTrue(p.isRunning)
        return p
    }

    private final class Signals: @unchecked Sendable {
        var sent: [(Int32, Int32)] = []
        var onTerm: ((Int32) -> Void)?
        func send(_ pid: Int32, _ signal: Int32) -> Int32 {
            sent.append((pid, signal))
            if signal == SIGTERM { onTerm?(pid) }
            return 0
        }
    }

    private func deadHostRecord(children pid: Int32) throws -> RunRecord {
        RunRecord(hostPID: try deadPID(), hostName: "Tandem", hostStarted: Date(timeIntervalSince1970: 0), childPIDs: [pid])
    }

    func testAProvedLeftoverIsTerminatedThenKilled() throws {
        let b = try bundle()
        let qemu = try fakeQEMU()
        defer { qemu.stopAndWait() }
        let record = try deadHostRecord(children: qemu.processIdentifier)
        XCTAssertEqual(record.children?.first?.pid, qemu.processIdentifier, "the identity is recorded with the number")
        b.writeRunRecord(record)
        let signals = Signals()
        let outcome = try XCTUnwrap(CrashRecovery.recover(b, signal: signals.send, settle: {}))
        XCTAssertEqual(outcome.stoppedProcesses, 1)
        XCTAssertEqual(signals.sent.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertTrue(signals.sent.allSatisfy { $0.0 == qemu.processIdentifier })
    }

    func testAReusedNumberWithAnotherStartTimeIsLeftAlone() throws {
        let b = try bundle()
        let qemu = try fakeQEMU()
        defer { qemu.stopAndWait() }
        var record = try deadHostRecord(children: qemu.processIdentifier)
        // The recorded QEMU started ten seconds before the process that now has its number.
        let now = try XCTUnwrap(ChildProcess.current(qemu.processIdentifier))
        record.children = [ChildProcess(pid: now.pid, path: now.path, started: now.started.addingTimeInterval(-10))]
        b.writeRunRecord(record)
        let signals = Signals()
        let outcome = try XCTUnwrap(CrashRecovery.recover(b, signal: signals.send, settle: {}))
        XCTAssertTrue(signals.sent.isEmpty, "another VM's QEMU that reused the number is not touched")
        XCTAssertEqual(outcome.stoppedProcesses, 0)
        XCTAssertEqual(outcome.unconfirmedProcesses, [], "it is provably not this VM's")
    }

    func testASameNamedProgramElsewhereIsLeftAlone() throws {
        let b = try bundle()
        let qemu = try fakeQEMU()
        defer { qemu.stopAndWait() }
        var record = try deadHostRecord(children: qemu.processIdentifier)
        let now = try XCTUnwrap(ChildProcess.current(qemu.processIdentifier))
        record.children = [ChildProcess(pid: now.pid, path: "/Applications/Other.app/Contents/MacOS/qemu-system-aarch64", started: now.started)]
        b.writeRunRecord(record)
        let signals = Signals()
        XCTAssertNotNil(CrashRecovery.recover(b, signal: signals.send, settle: {}))
        XCTAssertTrue(signals.sent.isEmpty)
    }

    func testARecordFromAnOlderBuildIsReportedNotSignalled() throws {
        let b = try bundle()
        let qemu = try fakeQEMU()
        defer { qemu.stopAndWait() }
        var record = try deadHostRecord(children: qemu.processIdentifier)
        record.children = nil // older builds wrote numbers only
        b.writeRunRecord(record)
        let signals = Signals()
        let outcome = try XCTUnwrap(CrashRecovery.recover(b, signal: signals.send, settle: {}))
        XCTAssertTrue(signals.sent.isEmpty)
        XCTAssertEqual(outcome.unconfirmedProcesses, [qemu.processIdentifier])
        XCTAssertTrue(outcome.message.contains("could not be confirmed"), outcome.message)
        XCTAssertTrue(qemu.isRunning)
    }

    func testAProcessReplacedBetweenTerminateAndKillIsNotKilled() throws {
        let b = try bundle()
        let qemu = try fakeQEMU()
        defer { qemu.stopAndWait() }
        b.writeRunRecord(try deadHostRecord(children: qemu.processIdentifier))
        let signals = Signals()
        // The leftover exits on the polite signal; whatever has its number afterwards is not ours.
        signals.onTerm = { pid in kill(pid, SIGKILL); _ = qemu.waitForExit(timeout: 5) }
        XCTAssertNotNil(CrashRecovery.recover(b, signal: signals.send, settle: {}))
        XCTAssertEqual(signals.sent.map(\.1), [SIGTERM], "no SIGKILL for a process that is gone")
    }

    func testAVMSomeoneHoldsIsNotRecoveredEvenWithADeadHostRecord() throws {
        let b = try bundle()
        b.writeRunRecord(RunRecord(hostPID: try deadPID(), hostName: "Tandem", hostStarted: Date(timeIntervalSince1970: 0)))
        let lease = try BundleLease.acquire(b, purpose: "running")
        XCTAssertNil(CrashRecovery.recover(b), "the lease's holder is running it now")
        XCTAssertNotNil(CrashRecovery.recover(b, holding: lease), "the holder itself cleans up before it starts")
        lease.release()
    }

    // MARK: R16: run folders are named for the whole VM identifier

    func testRunFoldersOfVMsWithTheSamePrefixDiffer() throws {
        let a = try XCTUnwrap(UUID(uuidString: "12345678-0000-4000-8000-000000000001"))
        let b = try XCTUnwrap(UUID(uuidString: "12345678-0000-4000-8000-000000000002"))
        XCTAssertNotEqual(RunFolder.name(for: a), RunFolder.name(for: b))
        XCTAssertEqual(RunFolder.name(for: a, in: "/tmp/"), "tandem-12345678000040008000000000000001")
        // Recovery only removes the folder named for its own VM (or that VM's old 8-character one).
        let temp = NSTemporaryDirectory()
        XCTAssertTrue(CrashRecovery.isOwnRunFolder(temp + RunFolder.name(for: a), for: a))
        XCTAssertTrue(CrashRecovery.isOwnRunFolder(temp + "tandem-12345678", for: a))
        XCTAssertFalse(CrashRecovery.isOwnRunFolder(temp + RunFolder.name(for: b), for: a))
    }

    func testALongTemporaryDirectoryGetsTheCompactNameWithinTheSocketLimit() throws {
        let id = UUID()
        let long = "/private/var/folders/" + String(repeating: "x", count: 34) + "/T/" // too long for 32 hex digits, not for 26
        let name = RunFolder.name(for: id, longestSocketName: "qmp.sock", in: long)
        XCTAssertEqual(name, "tandem-" + RunFolder.base32(id))
        XCTAssertEqual(RunFolder.base32(id).count, 26)
        XCTAssertLessThanOrEqual((long + name + "/qmp.sock").utf8.count, UnixSocket.maxPathLength)
        // 128 bits each: different identifiers never meet.
        let others = (0..<500).map { _ in RunFolder.base32(UUID()) }
        XCTAssertEqual(Set(others).count, others.count)
    }

    func testStopAndWaitEndsAProcessThatIgnoresTerminate() throws {
        let stubborn = try launch("/bin/sh", ["-c", "trap '' TERM; sleep 30"])
        usleep(200_000)
        let start = Date()
        stubborn.stopAndWait(grace: 0.5)
        XCTAssertTrue(stubborn.hasEnded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        // Already ended: returns at once, and is harmless on a process that never ran.
        stubborn.stopAndWait()
        Process().stopAndWait()
    }
}
