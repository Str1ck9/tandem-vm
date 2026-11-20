import XCTest
@testable import VMCore

/// Review finding R03: a revert that fails part-way must never delete the only copy of the VM's own files.
final class SnapshotRevertFailureTests: XCTestCase {
    /// Fails `moveItem` calls whose (source name, destination folder kind) match, a chosen number of times.
    final class FailingMoves: FileManager, @unchecked Sendable {
        var failMove: (URL, URL) -> Bool = { _, _ in false }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if failMove(srcURL, dstURL) { throw CocoaError(.fileWriteOutOfSpace) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapfail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bundle = try VMBundle.create(config: VMConfig(name: "Snap", guestOS: .linux, cpuCount: 1, memoryMiB: 1024), in: dir)
        try FileManager.default.createDirectory(at: bundle.tpmDirectory, withIntermediateDirectories: true)
        try Data("tpm-old".utf8).write(to: bundle.tpmDirectory.appendingPathComponent("state"))
        return bundle
    }

    private func setDisk(_ text: String, _ bundle: VMBundle) throws {
        let handle = try FileHandle(forWritingTo: bundle.diskURL(bundle.config.disks[0]))
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func disk(_ bundle: VMBundle) throws -> String {
        let handle = try FileHandle(forReadingFrom: bundle.diskURL(bundle.config.disks[0]))
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: 5) ?? Data(), as: UTF8.self)
    }

    private func hidden(_ bundle: VMBundle) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }.sorted()
    }

    /// The VM after the snapshot: disk "newer", config name "Now", tpm "tpm-new".
    private func bundleWithSnapshot() throws -> (VMBundle, VMSnapshot) {
        var bundle = try makeBundle()
        try setDisk("older", bundle)
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "s", config: bundle.config)
        try setDisk("newer", bundle)
        bundle.config.name = "Now"
        try bundle.save()
        try Data("tpm-new".utf8).write(to: bundle.tpmDirectory.appendingPathComponent("state"))
        return (bundle, snapshot)
    }

    private func assertUnchanged(_ bundle: VMBundle, file: StaticString = #filePath, line: UInt = #line) throws {
        let loaded = try VMBundle.load(from: bundle.url)
        XCTAssertEqual(loaded.config.name, "Now", file: file, line: line)
        XCTAssertEqual(try disk(loaded), "newer", file: file, line: line)
        XCTAssertEqual(try String(contentsOf: bundle.tpmDirectory.appendingPathComponent("state"), encoding: .utf8), "tpm-new", file: file, line: line)
    }

    func testACopyFailingPartWayLeavesTheVMUntouched() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        var calls = 0
        let failing: SnapshotStore.Copier = { source, destination in
            calls += 1
            // Leave a partial copy behind, as a recursive copy cut off by a full disk would.
            if calls == 2 { try Data("partial".utf8).write(to: destination); throw CocoaError(.fileWriteOutOfSpace) }
            try SnapshotStore.cloneItem(source, destination)
        }
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).revert(to: snapshot.id, copy: failing))
        try assertUnchanged(bundle)
        XCTAssertEqual(try hidden(bundle), [], "no staging, journal or aside left")
    }

    func testEachMoveFailingInTurnLeavesTheVMWhole() throws {
        // Fail the n-th move of the swap, for every n; the rollback itself works.
        for n in 1...8 {
            let (bundle, snapshot) = try bundleWithSnapshot()
            let fm = FailingMoves()
            var count = 0
            var rollingBack = false
            fm.failMove = { _, _ in
                if rollingBack { return false }
                count += 1
                if count == n { rollingBack = true; return true }
                return false
            }
            do {
                try SnapshotStore(bundle: bundle).revert(to: snapshot.id, fileManager: fm)
                // n beyond the number of moves: the revert simply worked.
                XCTAssertEqual(try VMBundle.load(from: bundle.url).config.name, "Snap", "n=\(n)")
            } catch {
                try assertUnchanged(bundle)
                XCTAssertEqual(try hidden(bundle), [], "n=\(n)")
            }
        }
    }

    /// The case the review reproduced: the swap fails and so does moving the originals back.
    func testAFailedRollbackKeepsTheRecoveryCopyAndRecoversLater() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        let fm = FailingMoves()
        var swapMoves = 0
        fm.failMove = { source, destination in
            // Moving originals aside works for the first two items, then the third fails; every move back out of
            // the aside folder fails too.
            if source.deletingLastPathComponent().lastPathComponent.hasPrefix(".reverting-") { return true }
            if destination.deletingLastPathComponent().lastPathComponent.hasPrefix(".reverting-") {
                swapMoves += 1
                return swapMoves == 3
            }
            return false
        }
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).revert(to: snapshot.id, fileManager: fm)) { error in
            XCTAssertTrue("\((error as? VMError)?.detail ?? "")".contains(".reverting-"), "the error says where the files are")
        }
        let leftovers = try hidden(bundle)
        XCTAssertTrue(leftovers.contains(SnapshotStore.journalName))
        XCTAssertTrue(leftovers.contains { $0.hasPrefix(".reverting-") }, "the VM's own files are kept")

        // Next time the bundle is opened (now with a working file system) it is put back as it was.
        try assertUnchanged(bundle)
        XCTAssertEqual(try hidden(bundle), [])
    }

    func testARevertCutOffMidSwapIsRolledBackWhenTheBundleIsOpened() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        let store = SnapshotStore(bundle: bundle)
        // Simulate a crash: stage, move two originals aside, place one snapshot item, then stop.
        let fm = FileManager.default
        let staging = bundle.url.appendingPathComponent(".revert-staging-test")
        let aside = bundle.url.appendingPathComponent(".reverting-test")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let source = bundle.url.appendingPathComponent("snapshots/\(snapshot.id.uuidString.lowercased())")
        for item in ["config.json", "disk0.img"] { try SnapshotStore.cloneItem(source.appendingPathComponent(item), staging.appendingPathComponent(item)) }
        let journal = SnapshotStore.RevertJournal(snapshot: snapshot.id, staging: staging.lastPathComponent, aside: aside.lastPathComponent,
                                                  phase: .placing, pid: 999_999)
        try JSONEncoder().encode(journal).write(to: bundle.url.appendingPathComponent(SnapshotStore.journalName))
        for item in try fm.contentsOfDirectory(atPath: bundle.url.path) where !item.hasPrefix(".") && !["logs", "run", "snapshots"].contains(item) {
            try fm.moveItem(at: bundle.url.appendingPathComponent(item), to: aside.appendingPathComponent(item))
        }
        try fm.moveItem(at: staging.appendingPathComponent("config.json"), to: bundle.url.appendingPathComponent("config.json"))

        try assertUnchanged(bundle) // load() recovers first
        XCTAssertEqual(try hidden(bundle), [])
        XCTAssertNil(try store.recoverInterruptedRevert())
    }

    func testARevertCutOffWhileMovingFilesAsideIsRolledBack() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        let fm = FileManager.default
        let aside = bundle.url.appendingPathComponent(".reverting-test")
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let journal = SnapshotStore.RevertJournal(snapshot: snapshot.id, staging: ".revert-staging-test", aside: aside.lastPathComponent,
                                                  phase: .movingAside, pid: 999_999)
        try JSONEncoder().encode(journal).write(to: bundle.url.appendingPathComponent(SnapshotStore.journalName))
        // Only the config went aside before the crash; the disk and TPM are still in place and must stay.
        try fm.moveItem(at: bundle.url.appendingPathComponent("config.json"), to: aside.appendingPathComponent("config.json"))
        try assertUnchanged(bundle)
        XCTAssertEqual(try hidden(bundle), [])
    }

    func testARevertCutOffWhileCopyingIsAbandoned() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        let staging = bundle.url.appendingPathComponent(".revert-staging-test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("disk0.img"))
        let journal = SnapshotStore.RevertJournal(snapshot: snapshot.id, staging: staging.lastPathComponent, aside: ".reverting-test",
                                                  phase: .staging, pid: 999_999)
        try JSONEncoder().encode(journal).write(to: bundle.url.appendingPathComponent(SnapshotStore.journalName))
        try assertUnchanged(bundle)
        XCTAssertEqual(try hidden(bundle), [])
    }

    func testARevertStillRunningInAnotherProcessIsLeftAlone() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        let journal = SnapshotStore.RevertJournal(snapshot: snapshot.id, staging: ".revert-staging-x", aside: ".reverting-x",
                                                  phase: .movingAside, pid: getppid())
        try JSONEncoder().encode(journal).write(to: bundle.url.appendingPathComponent(SnapshotStore.journalName))
        let result = try SnapshotStore(bundle: bundle).recoverInterruptedRevert()
        XCTAssertEqual(result?.kept, true)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).revert(to: snapshot.id))
        try assertUnchanged(bundle)
    }

    func testASuccessfulRevertLeavesNoWorkFiles() throws {
        let (bundle, snapshot) = try bundleWithSnapshot()
        try SnapshotStore(bundle: bundle).revert(to: snapshot.id)
        let loaded = try VMBundle.load(from: bundle.url)
        XCTAssertEqual(loaded.config.name, "Snap")
        XCTAssertEqual(try disk(loaded), "older")
        XCTAssertEqual(try hidden(bundle), [])
    }
}
