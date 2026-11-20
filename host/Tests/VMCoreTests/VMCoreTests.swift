import XCTest
@testable import VMCore

final class ConfigTests: XCTestCase {
    func testRoundTripPreservesEveryField() throws {
        var config = VMConfig(name: "Win 11", guestOS: .windows11arm, cpuCount: 6, memoryMiB: 8192)
        config.removableMedia = [RemovableMedia(file: "/tmp/win.iso", kind: .installerISO)]
        config.network.portForwards = [PortForward(hostPort: 3389, guestPort: 3389)]
        config.sharedFolders = [SharedFolder(hostPath: "/Users/x/Share", name: "Share", readOnly: true)]
        config.guestTools = GuestToolsInfo(installedVersion: "0.1.0", lastSeen: Date(timeIntervalSince1970: 1_700_000_000))
        config.install = InstallInfo(state: .installing, unattended: true, user: "demo")
        let data = try ConfigCoding.encoder().encode(config)
        let decoded = try ConfigCoding.decoder().decode(VMConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testOldConfigWithoutNewerFieldsStillLoads() throws {
        let json = """
        {"id":"7B0E0F0A-0000-4000-8000-000000000001","name":"old","guestOS":"windows11arm","cpuCount":2,"memoryMiB":2048,
         "disks":[{"file":"disk0.qcow2","sizeGiB":64,"bus":"nvme","format":"qcow2"}]}
        """
        let c = try ConfigCoding.decoder().decode(VMConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.engine, .qemu)
        XCTAssertTrue(c.tpm)
        XCTAssertEqual(c.network.mode, .nat)
        XCTAssertEqual(c.install.state, .notStarted)
    }

    func testOptionalSettingsSurviveSaveAndLoad() throws {
        var c = VMConfig(name: "round", guestOS: .linux)
        c.sharedClipboard = false
        c.notes = "note"
        c.hardwareUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        c.network.mode = .bridged
        c.network.bridgedInterface = "en0"
        let back = try ConfigCoding.decoder().decode(VMConfig.self, from: try ConfigCoding.encoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testLinuxToolsDiscContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tools-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = dir.appendingPathComponent("agent-source")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: agent)
        try GuestTools.stageLinux(agent: agent, in: dir.appendingPathComponent("disc"))
        let script = try String(contentsOf: dir.appendingPathComponent("disc/install.sh"), encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        // Here-document terminators must start their line, or the shell reads to the end of the file.
        XCTAssertEqual(script.components(separatedBy: "\nUNIT\n").count, 3)
        XCTAssertTrue(script.contains("\n[Service]\nExecStart=/usr/local/bin/tandem-agent\n"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("disc/tandem-agent")), Data("binary".utf8))
        let check = try ToolRun.run(URL(fileURLWithPath: "/bin/sh"), ["-n", dir.appendingPathComponent("disc/install.sh").path], timeout: 30)
        XCTAssertEqual(check.status, 0, "install.sh must parse")
    }

    func testDefaultsFollowGuestOS() {
        XCTAssertTrue(VMConfig(name: "w", guestOS: .windows11arm).tpm)
        XCTAssertFalse(VMConfig(name: "l", guestOS: .linux).tpm)
        XCTAssertEqual(VMConfig(name: "lq", guestOS: .linux, engine: .qemu).disks[0].bus, .virtio)
        let win = VMConfig(name: "w", guestOS: .windows11arm)
        XCTAssertEqual(win.engine, .qemu)
        XCTAssertEqual(win.disks[0].bus, .nvme)
        XCTAssertEqual(win.disks[0].format, .qcow2)
        let linux = VMConfig(name: "l", guestOS: .linux)
        XCTAssertEqual(linux.engine, .vz)
        XCTAssertEqual(linux.disks[0].format, .raw)
        XCTAssertEqual(VMConfig(name: "m", guestOS: .macos).engine, .vz)
    }

    func testValidationCatchesBadValues() {
        var c = VMConfig(name: " ", guestOS: .linux, cpuCount: 0, memoryMiB: 100)
        c.disks = []
        let problems = c.validate(hostCPUs: 8, hostMemoryMiB: 16384)
        XCTAssertEqual(problems.count, 4)
        XCTAssertTrue(VMConfig(name: "ok", guestOS: .linux).validate(hostCPUs: 8, hostMemoryMiB: 16384).isEmpty)
        XCTAssertFalse(VMConfig(name: "m", guestOS: .macos, engine: .qemu).validate(hostCPUs: 8, hostMemoryMiB: 16384).isEmpty)
        XCTAssertFalse(VMConfig(name: "big", guestOS: .linux, memoryMiB: 99999).validate(hostCPUs: 8, hostMemoryMiB: 16384).isEmpty)
    }

    func testRandomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<50 {
            let first = UInt8(NetworkConfig.randomMAC().prefix(2), radix: 16)!
            XCTAssertEqual(first & 0x01, 0)
            XCTAssertEqual(first & 0x02, 0x02)
        }
    }
}

final class LifecycleTests: XCTestCase {
    /// Every pair of states is checked against the transition table.
    func testTransitionTableIsExact() {
        let allowed: [VMState: Set<VMState>] = [
            .stopped: [.starting],
            .starting: [.running, .stopped, .error],
            .running: [.paused, .stopping, .stopped, .error],
            .paused: [.running, .stopping, .stopped, .error],
            .stopping: [.stopped, .error],
            .error: [.starting, .stopped],
        ]
        for from in VMState.allCases {
            for to in VMState.allCases {
                XCTAssertEqual(from.canTransition(to: to), allowed[from]!.contains(to), "\(from) -> \(to)")
            }
        }
    }

    func testMachineRejectsIllegalTransitionAndKeepsState() {
        let m = LifecycleMachine()
        XCTAssertFalse(m.transition(to: .running))
        XCTAssertEqual(m.state, .stopped)
        XCTAssertTrue(m.transition(to: .starting))
        XCTAssertTrue(m.transition(to: .running))
        XCTAssertFalse(m.transition(to: .starting))
        XCTAssertEqual(m.state, .running)
    }

    func testErrorIsRecordedAndClearedOnRestart() {
        let m = LifecycleMachine()
        m.transition(to: .starting)
        m.transition(to: .error, error: VMError("boom"))
        XCTAssertEqual(m.lastError, VMError("boom"))
        XCTAssertTrue(m.can(.start))
        m.transition(to: .starting)
        XCTAssertNil(m.lastError)
    }

    func testChangeCallbackFiresOncePerTransition() {
        let m = LifecycleMachine()
        let seen = Box()
        m.onChange = { seen.append($0) }
        m.transition(to: .starting); m.transition(to: .paused); m.transition(to: .running)
        XCTAssertEqual(seen.values, [.starting, .running])
    }

    func testActionsMatchStates() {
        let m = LifecycleMachine()
        XCTAssertTrue(m.can(.start)); XCTAssertFalse(m.can(.stop)); XCTAssertFalse(m.can(.forceStop))
        m.transition(to: .starting)
        XCTAssertTrue(m.can(.forceStop)); XCTAssertFalse(m.can(.pause))
        m.transition(to: .running)
        XCTAssertTrue(m.can(.pause)); XCTAssertTrue(m.can(.stop)); XCTAssertFalse(m.can(.resume))
        m.transition(to: .paused)
        XCTAssertTrue(m.can(.resume)); XCTAssertTrue(m.can(.stop)); XCTAssertFalse(m.can(.pause))
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var _values: [VMState] = []
    func append(_ s: VMState) { lock.withLock { _values.append(s) } }
    var values: [VMState] { lock.withLock { _values } }
}

final class BundleAndLibraryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCreateWritesConfigAndSparseDisk() throws {
        let library = try VMLibrary(rootDirectory: root)
        let bundle = try library.create(VMConfig(name: "Ubuntu", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        XCTAssertEqual(bundle.url.pathExtension, VMBundle.pathExtension)
        let disk = bundle.diskURL(bundle.config.disks[0])
        let values = try disk.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        XCTAssertEqual(values.fileSize, 64 << 30)
        XCTAssertLessThan(values.totalFileAllocatedSize ?? .max, 1 << 20, "disk must be sparse")
        XCTAssertEqual(try VMBundle.load(from: bundle.url).config, bundle.config)
    }

    func testListSurvivesReopenAndSortsByName() throws {
        let a = try VMLibrary(rootDirectory: root)
        _ = try a.create(VMConfig(name: "zeta", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        _ = try a.create(VMConfig(name: "Alpha", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        let b = try VMLibrary(rootDirectory: root)
        XCTAssertEqual(b.list().bundles.map(\.config.name), ["Alpha", "zeta"])
    }

    func testDuplicateNameIsRejected() throws {
        let library = try VMLibrary(rootDirectory: root)
        _ = try library.create(VMConfig(name: "one", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        XCTAssertThrowsError(try library.create(VMConfig(name: "one", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)))
    }

    func testInvalidConfigLeavesNothingBehind() throws {
        let library = try VMLibrary(rootDirectory: root)
        XCTAssertThrowsError(try library.create(VMConfig(name: "bad", guestOS: .linux, cpuCount: 0)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.vmsDirectory.path), [])
    }

    func testChosenFolderTakesNewVMsAndOldOnesStayListed() throws {
        let library = try VMLibrary(rootDirectory: root)
        let old = try library.create(VMConfig(name: "old", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        let chosen = root.appendingPathComponent("elsewhere/My VMs")
        try library.setVMsDirectory(chosen)
        let new = try library.create(VMConfig(name: "new", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        XCTAssertEqual(new.url.deletingLastPathComponent().standardizedFileURL, chosen.standardizedFileURL)
        XCTAssertEqual(old.url.deletingLastPathComponent().standardizedFileURL, library.defaultVMsDirectory.standardizedFileURL)
        // A second library object (another process) sees the same choice and both VMs.
        let again = try VMLibrary(rootDirectory: root)
        XCTAssertEqual(again.vmsDirectory.standardizedFileURL, chosen.standardizedFileURL)
        XCTAssertEqual(again.list().bundles.map(\.config.name), ["new", "old"])
        // A folder that has gone away lists nothing from it and refuses new VMs with a clear error.
        try FileManager.default.removeItem(at: chosen)
        XCTAssertEqual(again.list().bundles.map(\.config.name), ["old"])
        XCTAssertThrowsError(try again.create(VMConfig(name: "third", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)))
        try again.setVMsDirectory(nil)
        XCTAssertEqual(again.vmsDirectory.standardizedFileURL, again.defaultVMsDirectory.standardizedFileURL)
    }

    func testDeleteRemovesEverything() throws {
        let library = try VMLibrary(rootDirectory: root)
        let bundle = try library.create(VMConfig(name: "gone", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        try library.delete(bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.path))
        XCTAssertTrue(library.list().bundles.isEmpty)
    }

    func testCorruptConfigIsReportedNotFatal() throws {
        let library = try VMLibrary(rootDirectory: root)
        let good = try library.create(VMConfig(name: "good", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        let bad = try library.create(VMConfig(name: "bad", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        try Data("{not json".utf8).write(to: bad.configURL)
        let listing = library.list()
        XCTAssertEqual(listing.bundles.map(\.id), [good.id])
        XCTAssertEqual(listing.failures.count, 1)
    }

    func testNewerSchemaIsRefused() throws {
        let library = try VMLibrary(rootDirectory: root)
        var bundle = try library.create(VMConfig(name: "future", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        bundle.config.schemaVersion = 99
        try bundle.save()
        XCTAssertThrowsError(try VMBundle.load(from: bundle.url))
    }

    func testFindByNameAndIDPrefix() throws {
        let library = try VMLibrary(rootDirectory: root)
        let bundle = try library.create(VMConfig(name: "findme", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        XCTAssertEqual(try library.find("findme").id, bundle.id)
        XCTAssertEqual(try library.find(String(bundle.id.uuidString.prefix(8)).lowercased()).id, bundle.id)
        XCTAssertThrowsError(try library.find("nope"))
    }

    func testGrowRawRefusesToShrink() throws {
        let url = root.appendingPathComponent("d.img")
        try DiskImage.createSparseRaw(at: url, sizeGiB: 2)
        try DiskImage.growRaw(at: url, toGiB: 3)
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, 3 << 30)
        XCTAssertThrowsError(try DiskImage.growRaw(at: url, toGiB: 1))
    }

    func testSafeFileName() {
        XCTAssertEqual(VMBundle.safeFileName("Win/11: test"), "Win-11- test")
        XCTAssertEqual(VMBundle.safeFileName("///"), "---")
        XCTAssertEqual(VMBundle.safeFileName(""), "vm")
    }
}

final class SnapshotStoreTests: XCTestCase {
    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bundle = try VMBundle.create(config: VMConfig(name: "Snap", guestOS: .linux), in: dir)
        try FileManager.default.createDirectory(at: bundle.tpmDirectory, withIntermediateDirectories: true)
        try Data("tpm1".utf8).write(to: bundle.tpmDirectory.appendingPathComponent("state"))
        return bundle
    }

    private func write(_ text: String, to bundle: VMBundle) throws {
        let handle = try FileHandle(forWritingTo: bundle.diskURL(bundle.config.disks[0]))
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func read(_ bundle: VMBundle) throws -> String {
        let handle = try FileHandle(forReadingFrom: bundle.diskURL(bundle.config.disks[0]))
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: 5) ?? Data(), as: UTF8.self)
    }

    func testSnapshotsFormATree() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let a = try store.create(name: "A", config: bundle.config)
        let b = try store.create(name: "B", config: bundle.config)
        XCTAssertNil(a.parent)
        XCTAssertEqual(b.parent, a.id)
        XCTAssertEqual(store.currentParent(), b.id)
        // Going back to A and taking another snapshot starts a branch.
        try store.revert(to: a.id)
        XCTAssertEqual(store.currentParent(), a.id)
        let c = try store.create(name: "C", config: bundle.config)
        XCTAssertEqual(c.parent, a.id)
        let d = try store.create(name: "D", config: bundle.config)
        XCTAssertEqual(store.parents()[d.id], c.id)
        // Deleting C hands D to A; deleting the snapshot the VM stands on moves the VM up as well.
        try store.delete(c.id)
        XCTAssertEqual(store.parents()[d.id], a.id)
        XCTAssertEqual(store.currentParent(), d.id)
        try store.delete(d.id)
        XCTAssertEqual(store.currentParent(), a.id)
        try store.rename(b.id, name: "B2", note: " kept ")
        let renamed = store.list().first { $0.id == b.id }
        XCTAssertEqual(renamed?.name, "B2")
        XCTAssertEqual(renamed?.note, "kept")
        XCTAssertEqual(store.parents()[b.id], a.id)
    }

    func testSnapshotsFromBeforeParentsWereRecordedFollowByDate() throws {
        let old = #"{"id":"7B0E0F0A-0000-4000-8000-000000000009","name":"old","created":"2026-11-01T10:00:00Z"}"#
        let decoded = try ConfigCoding.decoder().decode(VMSnapshot.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.parentRecorded)
        let again = try ConfigCoding.decoder().decode(VMSnapshot.self, from: try ConfigCoding.encoder().encode(decoded))
        XCTAssertTrue(again.parentRecorded)
        XCTAssertNil(again.parent)
    }

    func testCreateRevertDelete() throws {
        var bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        try write("first", to: bundle)
        let snapshot = try store.create(name: " Before update ", config: bundle.config)
        XCTAssertEqual(snapshot.name, "Before update")
        XCTAssertNil(snapshot.note)
        let size = store.size(of: snapshot.id)
        XCTAssertGreaterThan(size.total, 0)
        XCTAssertLessThanOrEqual(size.exclusive, size.total)
        XCTAssertEqual(store.list().map(\.id), [snapshot.id])

        try write("later", to: bundle)
        bundle.config.name = "Renamed"
        try bundle.save()
        try Data("tpm2".utf8).write(to: bundle.tpmDirectory.appendingPathComponent("state"))
        try Data("x".utf8).write(to: bundle.url.appendingPathComponent("added-later.bin"))

        try store.revert(to: snapshot.id)
        let reverted = try VMBundle.load(from: bundle.url)
        XCTAssertEqual(try read(reverted), "first")
        XCTAssertEqual(reverted.config.name, "Snap")
        XCTAssertEqual(try String(contentsOf: bundle.tpmDirectory.appendingPathComponent("state"), encoding: .utf8), "tpm1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("added-later.bin").path))
        XCTAssertEqual(store.list().count, 1, "reverting keeps the snapshot")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".reverting") }
        XCTAssertEqual(leftovers, [])

        try store.delete(snapshot.id)
        XCTAssertEqual(store.list(), [])
    }

    func testRevertToMissingSnapshotLeavesTheVMAlone() throws {
        let bundle = try makeBundle()
        try write("first", to: bundle)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).revert(to: UUID()))
        XCTAssertEqual(try read(bundle), "first")
    }

    func testNoteIsKept() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        try store.create(name: "A", note: "  before the driver install \n", config: bundle.config)
        XCTAssertEqual(store.list().first?.note, "before the driver install")
    }

    func testRefusesDiskOutsideTheBundle() throws {
        let bundle = try makeBundle()
        var config = bundle.config
        config.disks[0].file = "/tmp/elsewhere.img"
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "x", config: config))
        XCTAssertEqual(SnapshotStore(bundle: bundle).list(), [])
    }
}

final class GuestAppBundleTests: XCTestCase {
    private func picture(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0.4, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    func testIdentifiersAreStableAndDistinct() {
        let vm = UUID(uuidString: "F6421CE0-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "F6421CE0-0000-4000-8000-000000000002")!
        let a = GuestAppBundle.bundleIdentifier(vm: vm, program: "app:notepad.exe")
        XCTAssertEqual(a, GuestAppBundle.bundleIdentifier(vm: vm, program: "APP:Notepad.exe"), "case does not matter")
        XCTAssertNotEqual(a, GuestAppBundle.bundleIdentifier(vm: vm, program: "app:calc.exe"))
        XCTAssertNotEqual(a, GuestAppBundle.bundleIdentifier(vm: other, program: "app:notepad.exe"))
        XCTAssertTrue(a.hasPrefix(TandemIdentity.guestApp + "."))
    }

    func testNamesBecomeSafePathComponents() {
        XCTAssertEqual(GuestAppBundle.fileName("A/B: C\\D"), "A-B- C-D")
        XCTAssertEqual(GuestAppBundle.fileName(" .. "), "Program")
        XCTAssertEqual(GuestAppBundle.fileName("Notepad"), "Notepad")
    }

    func testIconFileHoldsTwoPNGPictures() throws {
        let data = try XCTUnwrap(GuestAppBundle.icns(from: picture(48)))
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "icns")
        let total = data.subdata(in: 4..<8).reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(total, data.count)
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "ic07")
        let first = data.subdata(in: 12..<16).reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(Array(data.subdata(in: 16..<20)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        XCTAssertEqual(String(data: data.subdata(in: (8 + first)..<(12 + first)), encoding: .ascii), "ic08")
    }

    func testWrittenBundleSaysWhatItStandsFor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-guestapp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("stub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: stub)
        let vm = UUID()
        let directory = GuestAppBundle.directory(root: root, vmName: "Windows 11")
        XCTAssertEqual(directory.path, root.appendingPathComponent("Guest Apps/Windows 11").path)
        // Written twice: the second write replaces the first.
        _ = try GuestAppBundle.write(in: directory, name: "Notepad", vm: vm, program: "app:notepad.exe", icon: nil, stub: stub)
        let bundle = try GuestAppBundle.write(in: directory, name: "Notepad", vm: vm, program: "app:notepad.exe", icon: picture(32), stub: stub)
        XCTAssertEqual(bundle.lastPathComponent, "Notepad.app")
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(info["CFBundleName"] as? String, "Notepad")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, GuestAppBundle.bundleIdentifier(vm: vm, program: "app:notepad.exe"))
        XCTAssertEqual(info[GuestAppBundle.vmKey] as? String, vm.uuidString)
        XCTAssertEqual(info[GuestAppBundle.programKey] as? String, "app:notepad.exe")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "icon.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/icon.icns").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/TandemGuestApp").path))
    }
}
