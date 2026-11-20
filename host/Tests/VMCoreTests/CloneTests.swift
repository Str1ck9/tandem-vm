import XCTest
@testable import VMCore

final class CloneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clone-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    final class Calls: @unchecked Sendable { var rebases: [(String, String, String)] = []; var renewed = 0 }

    private func hooks(_ calls: Calls) -> CloneHooks {
        CloneHooks(rebaseDisk: { disk, backing, format in calls.rebases.append((disk.lastPathComponent, backing, format)) },
                   renewVZMachineIdentifier: { _ in calls.renewed += 1 })
    }

    /// A Windows-like QEMU VM whose disk is layered on a base file inside its own bundle, with a TPM,
    /// suspend state, a snapshot and leftovers in run/ and logs/.
    private func makeSource() throws -> VMBundle {
        var config = VMConfig(name: "Win", guestOS: .windows11arm, engine: .qemu, cpuCount: 2, memoryMiB: 2048)
        config.disks[0].format = .qcow2
        config.disks[0].file = "disk0.qcow2"
        var bundle = try VMBundle.create(config: config, in: root.appendingPathComponent("VMs"))
        let base = bundle.url.appendingPathComponent("base.hds")
        try Data("base".utf8).write(to: base)
        bundle.config.disks[0].backing = try DiskBacking.fingerprint(path: base.path, format: "parallels")
        try bundle.save()
        try Data("overlay".utf8).write(to: bundle.url.appendingPathComponent("disk0.qcow2"))
        try FileManager.default.createDirectory(at: bundle.tpmDirectory, withIntermediateDirectories: true)
        try Data("tpm".utf8).write(to: bundle.tpmDirectory.appendingPathComponent("tpm2-00.permall"))
        try Data("mem".utf8).write(to: bundle.url.appendingPathComponent("suspend.state"))
        try Data("x".utf8).write(to: bundle.runDirectory.appendingPathComponent("host.json"))
        try Data("log".utf8).write(to: bundle.logsDirectory.appendingPathComponent("qemu.log"))
        let snapshot = bundle.snapshotsDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try ConfigCoding.encoder().encode(bundle.config).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("snap".utf8).write(to: snapshot.appendingPathComponent("disk0.qcow2"))
        return bundle
    }

    func testDefaultNameIsUnique() {
        XCTAssertEqual(VMCloner.defaultName(for: "Win", taken: ["Win"]), "Win Copy")
        XCTAssertEqual(VMCloner.defaultName(for: "Win", taken: ["Win", "Win Copy"]), "Win Copy 2")
        XCTAssertEqual(VMCloner.defaultName(for: "Win", taken: ["Win", "Win Copy", "Win Copy 2"]), "Win Copy 3")
    }

    func testConfigGetsANewIdentityUnlessKept() {
        var source = VMConfig(name: "Win", guestOS: .windows11arm, engine: .qemu, cpuCount: 2, memoryMiB: 2048)
        source.hardwareUUID = nil
        let fresh = VMCloner.cloneConfig(source, name: "A", options: CloneOptions())
        XCTAssertNotEqual(fresh.id, source.id)
        XCTAssertNotEqual(fresh.network.mac, source.network.mac)
        XCTAssertNil(fresh.hardwareUUID, "a new machine: the firmware UUID follows the new id")
        XCTAssertEqual(fresh.pendingGuestIdentityReset, true)

        let kept = VMCloner.cloneConfig(source, name: "B", options: CloneOptions(keepHardwareIdentity: true))
        XCTAssertEqual(kept.hardwareUUID, source.id, "keeping the identity pins the UUID the source showed (its id)")
        XCTAssertNotEqual(kept.id, source.id)

        var imported = source; imported.hardwareUUID = UUID()
        XCTAssertEqual(VMCloner.cloneConfig(imported, name: "C", options: CloneOptions(keepHardwareIdentity: true)).hardwareUUID, imported.hardwareUUID)

        let mac = VMConfig(name: "Mac", guestOS: .macos, engine: .vz, cpuCount: 2, memoryMiB: 4096)
        XCTAssertNil(VMCloner.cloneConfig(mac, name: "D", options: CloneOptions()).pendingGuestIdentityReset, "macOS has no guest reset")
        XCTAssertNil(VMCloner.cloneConfig(source, name: "E", options: CloneOptions(resetGuestIdentity: false)).pendingGuestIdentityReset)
    }

    func testDefaultCloneIsANewMachineWithItsOwnBase() throws {
        let source = try makeSource()
        let calls = Calls()
        let clone = try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: hooks(calls))
        let fm = FileManager.default
        XCTAssertEqual(clone.config.name, "Win Copy")
        XCTAssertNotEqual(clone.url, source.url)
        XCTAssertTrue(fm.fileExists(atPath: clone.url.appendingPathComponent("base.hds").path))
        XCTAssertEqual(try String(contentsOf: clone.url.appendingPathComponent("disk0.qcow2"), encoding: .utf8), "overlay")
        XCTAssertFalse(clone.isSuspended, "the suspend state is left behind by default")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: clone.tpmDirectory.path), [], "a fresh TPM")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: clone.runDirectory.path), [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: clone.logsDirectory.path), [])
        XCTAssertFalse(fm.fileExists(atPath: clone.snapshotsDirectory.path), "snapshots are left behind by default")
        // The disk now points at the clone's own base, in the header and in the config.
        let ownBase = clone.url.appendingPathComponent("base.hds").path
        XCTAssertEqual(calls.rebases.count, 1)
        XCTAssertEqual(calls.rebases.first?.1, ownBase)
        XCTAssertEqual(calls.rebases.first?.2, "parallels")
        let reloaded = try VMBundle.load(from: clone.url)
        XCTAssertEqual(reloaded.config.disks[0].backing?.path, ownBase)
        XCTAssertNil(reloaded.config.disks[0].backing?.problem(), "cp -p keeps size and date, so the fingerprint still matches")
        // The source is untouched.
        let sourceAgain = try VMBundle.load(from: source.url)
        XCTAssertEqual(sourceAgain.config, source.config)
        XCTAssertTrue(sourceAgain.isSuspended)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.tpmDirectory.path), ["tpm2-00.permall"])
    }

    func testKeptIdentitySnapshotsAndSuspendState() throws {
        let source = try makeSource()
        let calls = Calls()
        let options = CloneOptions(name: "Twin", includeSnapshots: true, keepSuspendState: true, keepHardwareIdentity: true)
        let clone = try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], options: options, hooks: hooks(calls))
        XCTAssertEqual(clone.config.name, "Twin")
        XCTAssertTrue(clone.isSuspended)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clone.tpmDirectory.path), ["tpm2-00.permall"])
        XCTAssertEqual(clone.config.hardwareUUID, source.id)
        // The snapshot was copied and now describes the clone, pointing at the clone's base in its root.
        let folders = try FileManager.default.contentsOfDirectory(at: clone.snapshotsDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let snapshotConfig = try ConfigCoding.decoder().decode(VMConfig.self, from: Data(contentsOf: folders[0].appendingPathComponent("config.json")))
        XCTAssertEqual(snapshotConfig.id, clone.config.id)
        XCTAssertEqual(snapshotConfig.network.mac, clone.config.network.mac)
        XCTAssertEqual(snapshotConfig.disks[0].backing?.path, clone.url.appendingPathComponent("base.hds").path)
        XCTAssertEqual(calls.rebases.count, 2, "the clone's disk and the snapshot's disk")
    }

    func testNameClashIsRefusedAndNothingIsLeft() throws {
        let source = try makeSource()
        XCTAssertThrowsError(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win", "Taken"],
                                                options: CloneOptions(name: "Taken"), hooks: hooks(Calls())))
        let bundles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("VMs").path)
        XCTAssertEqual(bundles.count, 1)
    }

    func testAFailedStepRemovesTheHalfMadeClone() throws {
        let source = try makeSource()
        let failing = CloneHooks(rebaseDisk: { _, _, _ in throw VMError("no qemu-img") }, renewVZMachineIdentifier: { _ in })
        XCTAssertThrowsError(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: failing))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("VMs").path).count, 1)
    }

    func testGuestResetCommands() {
        XCTAssertEqual(GuestIdentityReset.hostName(for: "Ubuntu Desktop Copy 2"), "ubuntu-desktop-copy-2")
        XCTAssertEqual(GuestIdentityReset.hostName(for: "Win 11 (DEL ME) Copy", maxLength: 15), "win-11-del-me-c")
        XCTAssertEqual(GuestIdentityReset.hostName(for: "???"), "tandem-vm")
        let linux = GuestIdentityReset.command(for: VMConfig(name: "Deb Copy", guestOS: .linux, cpuCount: 1, memoryMiB: 1024))
        XCTAssertEqual(linux?.elevated, false)
        XCTAssertTrue(linux?.command.contains("hostnamectl set-hostname 'deb-copy'") == true)
        XCTAssertTrue(linux?.command.contains("ssh-keygen -A") == true)
        let windows = GuestIdentityReset.command(for: VMConfig(name: "Win Copy", guestOS: .windows11arm, cpuCount: 2, memoryMiB: 2048))
        XCTAssertEqual(windows?.elevated, true)
        XCTAssertTrue(windows?.command.contains("Rename-Computer -NewName 'WIN-COPY'") == true)
        XCTAssertNil(GuestIdentityReset.command(for: VMConfig(name: "M", guestOS: .macos, engine: .vz, cpuCount: 2, memoryMiB: 4096)))
    }

    // MARK: Review finding R04: a clone must not share a writable disk with its source.

    private func bundleCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("VMs").path)) ?? []).count
    }

    func testAnExternalWritableDiskIsRefused() throws {
        var source = try makeSource()
        let external = root.appendingPathComponent("external.qcow2")
        try Data("shared".utf8).write(to: external)
        source.config.disks[0].file = external.path
        try source.save()
        let before = bundleCount()
        XCTAssertThrowsError(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: hooks(Calls()))) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("outside the VM") == true)
        }
        XCTAssertEqual(bundleCount(), before, "nothing is left behind")
        XCTAssertEqual(try Data(contentsOf: external), Data("shared".utf8))
    }

    func testADiskLinkedOutOfTheBundleIsRefused() throws {
        let source = try makeSource()
        let external = root.appendingPathComponent("elsewhere.qcow2")
        try Data("shared".utf8).write(to: external)
        let disk = source.url.appendingPathComponent("disk0.qcow2")
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: external)
        XCTAssertThrowsError(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: hooks(Calls())))
    }

    func testASnapshotWithAnExternalDiskIsRefusedOnlyWhenSnapshotsAreCopied() throws {
        let source = try makeSource()
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: source.snapshotsDirectory, includingPropertiesForKeys: nil).first)
        var snapshotConfig = source.config
        snapshotConfig.disks[0].file = root.appendingPathComponent("external.qcow2").path
        try ConfigCoding.encoder().encode(snapshotConfig).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"],
                                                options: CloneOptions(includeSnapshots: true), hooks: hooks(Calls())))
        XCTAssertNoThrow(try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: hooks(Calls())))
    }

    func testAReadOnlyBackingOutsideTheBundleStaysShared() throws {
        var source = try makeSource()
        let original = root.appendingPathComponent("Parallels-original.hds")
        try Data("original".utf8).write(to: original)
        source.config.disks[0].backing = try DiskBacking.fingerprint(path: original.path, format: "parallels")
        try source.save()
        let calls = Calls()
        let clone = try VMCloner.clone(source, into: root.appendingPathComponent("VMs"), taken: ["Win"], hooks: hooks(calls))
        XCTAssertEqual(clone.config.disks[0].backing?.path, original.path, "both overlays read the same original")
        XCTAssertTrue(calls.rebases.isEmpty, "the overlay's header is left alone")
        XCTAssertNotEqual(clone.diskURL(clone.config.disks[0]).path, source.diskURL(source.config.disks[0]).path)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }
}
