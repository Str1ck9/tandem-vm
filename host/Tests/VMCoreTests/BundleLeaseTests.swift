import XCTest
@testable import VMCore

/// R07 (code review 16 Nov): the bundle lease is the one claim on a VM, across engines, processes and
/// offline work; R20: that work runs away from the main actor.
final class BundleLeaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tbl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func bundle(_ name: String = "Leased") throws -> VMBundle {
        try VMLibrary(rootDirectory: root).create(VMConfig(name: name, guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
    }

    func testASecondClaimInTheSameProcessIsRefusedUntilTheFirstIsReleased() throws {
        let b = try bundle()
        let first = try BundleLease.acquire(b, purpose: "running")
        XCTAssertTrue(first.covers(b))
        // A second engine (or a clone, or a revert) in this same process: refused, and told why.
        XCTAssertThrowsError(try BundleLease.acquire(b, purpose: "running")) { error in
            XCTAssertEqual((error as? VMError)?.message, "“Leased” is busy: running.")
        }
        XCTAssertNil(BundleLease.tryAcquire(b, purpose: "being cloned"))
        first.release()
        XCTAssertFalse(first.isHeld)
        first.release() // harmless twice
        let second = try BundleLease.acquire(b, purpose: "being cloned")
        XCTAssertTrue(second.isHeld)
    }

    func testDroppingTheLeaseObjectReleasesIt() throws {
        let b = try bundle()
        do { _ = try BundleLease.acquire(b, purpose: "running") }
        XCTAssertNotNil(BundleLease.tryAcquire(b, purpose: "running"), "deinit gives the claim up")
    }

    func testOfConcurrentClaimsExactlyOneWins() throws {
        let b = try bundle()
        let winners = Locked(0)
        let leases = Locked<[BundleLease]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let lease = BundleLease.tryAcquire(b, purpose: "racing") {
                winners.mutate { $0 += 1 }
                leases.mutate { $0.append(lease) } // keep it held until every racer has tried
            }
        }
        XCTAssertEqual(winners.value, 1)
    }

    /// Another process (another Tandem, or vmctl) holds the claim; once it dies the kernel frees it.
    func testAClaimHeldByAnotherProcessIsRefusedAndFreedWhenItsOwnerIsKilled() throws {
        let b = try bundle()
        let lockPath = b.url.appendingPathComponent(BundleLease.fileName).path
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "use Fcntl ':flock'; open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print \"locked\\n\"; sleep 60",
                            lockPath]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.stopAndWait() }
        XCTAssertEqual(String(data: out.fileHandleForReading.availableData, encoding: .utf8), "locked\n")

        XCTAssertThrowsError(try BundleLease.acquire(b, purpose: "running")) { error in
            XCTAssertTrue((error as? VMError)?.message.hasPrefix("“Leased” is in use by") == true, "\(error)")
        }
        // The owner is killed: no stale claim survives it.
        kill(holder.processIdentifier, SIGKILL)
        XCTAssertTrue(holder.waitForExit(timeout: 10))
        XCTAssertNotNil(BundleLease.tryAcquire(b, purpose: "running"))
    }

    func testTheBusyMessageNamesTheOtherProgram() {
        let holder = BundleLease.Holder(pid: 99999, process: "vmctl", purpose: "running", since: Date())
        let error = BundleLease.busyError(name: "Win", holder: holder, wanted: "being cloned")
        XCTAssertEqual(error.message, "“Win” is in use by vmctl (process 99999): running.")
    }

    func testTheLockFileIsNeverCopiedIntoSnapshotsOrClones() throws {
        let b = try bundle()
        let lease = try BundleLease.acquire(b, purpose: "taking a snapshot")
        let snapshot = try SnapshotStore(bundle: b).create(name: "one", config: b.config)
        lease.release()
        let folder = b.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(BundleLease.fileName).path))

        let hooks = CloneHooks(rebaseDisk: { _, _, _ in }, renewVZMachineIdentifier: { _ in })
        let copy = try VMCloner.clone(b, into: root.appendingPathComponent("Clones"), taken: [], hooks: hooks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.appendingPathComponent(BundleLease.fileName).path))
    }

    // MARK: Offline work against a running VM

    func testMaintenanceIsRefusedWhileTheVMRunsAndWorksUnderTheRunsOwnLease() async throws {
        let b = try bundle()
        let engineLease = try BundleLease.acquire(b, purpose: "running")
        // Cloning (or reverting) a VM that runs: refused at once, before any copying.
        do {
            _ = try await BundleWork.run(b, purpose: "being cloned") { XCTFail("must not run"); return 0 }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? VMError)?.message, "“Leased” is busy: running.")
        }
        // A snapshot of the running VM goes under the engine's own lease.
        let value = try await BundleWork.run(b, purpose: "taking a snapshot", holding: engineLease) { 42 }
        XCTAssertEqual(value, 42)
        // Someone else's lease does not count.
        let other = try bundle("Other")
        let otherLease = try BundleLease.acquire(other, purpose: "running")
        do {
            _ = try await BundleWork.run(b, purpose: "taking a snapshot", holding: otherLease) { 0 }
            XCTFail("expected a refusal")
        } catch {}
        engineLease.release(); otherLease.release()
    }

    @MainActor
    func testSlowBundleWorkLeavesTheMainActorFree() async throws {
        let b = try bundle()
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        // A slow copy (a clone on a disk without APFS clones), here a plain blocking wait.
        try await BundleWork.run(b, purpose: "being cloned") { Thread.sleep(forTimeInterval: 0.6) }
        ticker.cancel()
        XCTAssertGreaterThanOrEqual(ticks, 10, "the main run loop kept going while the work ran")
        XCTAssertNotNil(BundleLease.tryAcquire(b, purpose: "running"), "the work's lease is given back")
    }

    func testCancellingACloneStopsItAndLeavesNoPartialCopy() async throws {
        let b = try bundle()
        for index in 0..<6 {
            FileManager.default.createFile(atPath: b.url.appendingPathComponent("item\(index).img").path, contents: Data(count: 1024))
        }
        let into = root.appendingPathComponent("Clones")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let hooks = CloneHooks(rebaseDisk: { _, _, _ in }, renewVZMachineIdentifier: { _ in })
        do {
            _ = try await BundleWork.run(b, purpose: "being cloned") {
                try VMCloner.clone(b, into: into, taken: [], hooks: hooks, progress: { fraction in
                    // Stop part-way, as the clone sheet's Stop button does.
                    if fraction > 0.3 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: into.path), [], "the partial copy is removed")
        XCTAssertNotNil(BundleLease.tryAcquire(b, purpose: "running"))
    }

    func testCancellingTheCallerCancelsTheBackgroundWork() async throws {
        let b = try bundle()
        let caller = Task {
            try await BundleWork.run(b, purpose: "going back to a snapshot") {
                for _ in 0..<500 { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.01) }
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        caller.cancel()
        do { try await caller.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }

    // MARK: Run records are descriptions, and their failures are reported

    func testAFailedRunRecordWriteIsReported() throws {
        let b = try bundle()
        try FileManager.default.removeItem(at: b.runDirectory)
        FileManager.default.createFile(atPath: b.runDirectory.path, contents: Data()) // a file where the folder belongs
        XCTAssertNotNil(b.writeRunRecord(RunRecord()))
        XCTAssertNil(b.readRunRecord())
    }
}

/// A value shared between threads in a test.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; change(&stored) }
}
