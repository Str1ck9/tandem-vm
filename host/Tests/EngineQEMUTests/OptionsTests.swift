import CoreGraphics
import XCTest
@testable import EngineQEMU
import VMCore

final class KeyTranslatorTests: XCTestCase {
    private typealias Key = KeyTranslator.Key
    private let cmd: UInt16 = 0x37, ctrl: UInt16 = 0x3B, alt: UInt16 = 0x3A
    private let c: UInt16 = 0x08, v: UInt16 = 0x09, q: UInt16 = 0x0C, e: UInt16 = 0x0E, f4: UInt16 = 0x76

    func testWindowsKeyProfilePassesEverythingThrough() {
        var t = KeyTranslator(profile: .windowsKey)
        XCTAssertEqual(t.translate(code: cmd, down: true), [Key(cmd, true)])
        XCTAssertEqual(t.translate(code: c, down: true), [Key(c, true)])
        XCTAssertEqual(t.translate(code: c, down: false), [Key(c, false)])
        XCTAssertEqual(t.translate(code: cmd, down: false), [Key(cmd, false)])
    }

    func testCommandLetterBecomesControlLetterAndNeverTouchesTheWindowsKey() {
        var t = KeyTranslator(profile: .macShortcuts)
        XCTAssertEqual(t.translate(code: cmd, down: true), [], "Command is held back until its purpose is known")
        XCTAssertEqual(t.translate(code: c, down: true), [Key(ctrl, true), Key(c, true)])
        XCTAssertEqual(t.translate(code: c, down: false), [Key(c, false), Key(ctrl, false)])
        // A second shortcut during the same Command press.
        XCTAssertEqual(t.translate(code: v, down: true), [Key(ctrl, true), Key(v, true)])
        XCTAssertEqual(t.translate(code: v, down: false), [Key(v, false), Key(ctrl, false)])
        XCTAssertEqual(t.translate(code: cmd, down: false), [], "no Windows key tap after a shortcut: that would open the Start menu")
    }

    func testCommandAloneIsATapOfTheWindowsKey() {
        var t = KeyTranslator(profile: .macShortcuts)
        XCTAssertEqual(t.translate(code: cmd, down: true), [])
        XCTAssertEqual(t.translate(code: cmd, down: false), [Key(cmd, true), Key(cmd, false)])
    }

    func testCommandWithAnotherKeyIsStillTheWindowsKey() {
        var t = KeyTranslator(profile: .macShortcuts)
        _ = t.translate(code: cmd, down: true)
        XCTAssertEqual(t.translate(code: e, down: true), [Key(cmd, true), Key(e, true)], "Command-E opens Explorer as Windows-E")
        XCTAssertEqual(t.translate(code: e, down: false), [Key(e, false)])
        XCTAssertEqual(t.translate(code: cmd, down: false), [Key(cmd, false)])
    }

    func testCommandQClosesTheWindow() {
        var t = KeyTranslator(profile: .macShortcuts)
        _ = t.translate(code: cmd, down: true)
        XCTAssertEqual(t.translate(code: q, down: true), [Key(alt, true), Key(f4, true)])
        XCTAssertEqual(t.translate(code: q, down: false), [Key(f4, false), Key(alt, false)])
        XCTAssertEqual(t.translate(code: cmd, down: false), [])
    }

    func testARealControlKeyIsNotReleasedByAShortcut() {
        var t = KeyTranslator(profile: .macShortcuts)
        XCTAssertEqual(t.translate(code: ctrl, down: true), [Key(ctrl, true)])
        _ = t.translate(code: cmd, down: true)
        XCTAssertEqual(t.translate(code: c, down: true), [Key(c, true)])
        XCTAssertEqual(t.translate(code: c, down: false), [Key(c, false)])
        XCTAssertEqual(t.translate(code: ctrl, down: false), [Key(ctrl, false)])
    }

    func testPlainTypingIsUntouchedInTheMacProfile() {
        var t = KeyTranslator(profile: .macShortcuts)
        XCTAssertEqual(t.translate(code: c, down: true), [Key(c, true)])
        XCTAssertEqual(t.translate(code: c, down: false), [Key(c, false)])
    }
}

final class ScalingTests: XCTestCase {
    private let screen = RFBClient.Size(width: 800, height: 600)

    func testFitKeepsProportionsAndCentres() {
        XCTAssertEqual(GuestInput.screenRect(viewSize: CGSize(width: 1600, height: 900), framebuffer: screen),
                       CGRect(x: 200, y: 0, width: 1200, height: 900))
    }

    func testStretchFillsTheView() {
        let view = CGSize(width: 1600, height: 900)
        XCTAssertEqual(GuestInput.screenRect(viewSize: view, framebuffer: screen, scaling: .stretch), CGRect(origin: .zero, size: view))
        let p = GuestInput.framebufferPoint(viewPoint: CGPoint(x: 800, y: 450), viewSize: view, framebuffer: screen, scaling: .stretch)
        XCTAssertEqual(p?.x, 400); XCTAssertEqual(p?.y, 300)
    }

    func testActualSizeIsNeverScaledUpButShrinksToFit() {
        XCTAssertEqual(GuestInput.screenRect(viewSize: CGSize(width: 1600, height: 900), framebuffer: screen, scaling: .actualSize),
                       CGRect(x: 400, y: 150, width: 800, height: 600))
        XCTAssertEqual(GuestInput.screenRect(viewSize: CGSize(width: 400, height: 600), framebuffer: screen, scaling: .actualSize),
                       CGRect(x: 0, y: 150, width: 400, height: 300))
        let p = GuestInput.framebufferPoint(viewPoint: CGPoint(x: 400, y: 150), viewSize: CGSize(width: 1600, height: 900),
                                            framebuffer: screen, scaling: .actualSize)
        XCTAssertEqual(p?.x, 0); XCTAssertEqual(p?.y, 0)
    }
}

final class BootAndSoundArgumentTests: XCTestCase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-options-\(UUID().uuidString)")
    let toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/x/bin/qemu-system-aarch64"), qemuImg: URL(fileURLWithPath: "/x/bin/qemu-img"),
                                  swtpm: nil, firmwareCode: URL(fileURLWithPath: "/x/code.fd"), firmwareVarsTemplate: URL(fileURLWithPath: "/x/vars.fd"),
                                  qemuVersion: "QEMU emulator version 11.1.3")
    let paths = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tandem-test"))

    override func setUpWithError() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func args(_ config: VMConfig, display: QEMUDisplayMode = .embedded) throws -> [String] {
        try QEMUCommandBuilder.arguments(bundle: try VMBundle.create(config: config, in: root), toolchain: toolchain, paths: paths, display: display)
    }

    private func device(_ a: [String], _ prefix: String) -> String? {
        zip(a, a.dropFirst()).first { $0.0 == "-device" && $0.1.hasPrefix(prefix) }?.1
    }

    private func linux(_ name: String) -> VMConfig {
        var config = VMConfig(name: name, guestOS: .linux, engine: .qemu)
        config.removableMedia = [RemovableMedia(file: "/isos/linux.iso", kind: .installerISO)]
        return config
    }

    func testDefaultOrderIsDiskThenDiscAndTheNetworkIsNotABootDevice() throws {
        let a = try args(linux("default"))
        XCTAssertEqual(device(a, "virtio-blk-pci,drive=disk0"), "virtio-blk-pci,drive=disk0,bootindex=0")
        XCTAssertEqual(device(a, "usb-storage,bus=usb.0,drive=media0"), "usb-storage,bus=usb.0,drive=media0,removable=on,bootindex=1")
        XCTAssertFalse(device(a, "virtio-net-pci,netdev=net0")?.contains("bootindex") ?? true)
        XCTAssertFalse(a.contains("-boot"))
    }

    func testChosenOrderSetsTheIndexesAndLeftOutDevicesGetNone() throws {
        var config = linux("ordered")
        config.boot = BootConfig(order: [.cd, .network, .hardDisk], menu: true)
        var a = try args(config)
        XCTAssertEqual(device(a, "usb-storage,bus=usb.0,drive=media0"), "usb-storage,bus=usb.0,drive=media0,removable=on,bootindex=0")
        XCTAssertTrue(device(a, "virtio-net-pci,netdev=net0")?.hasSuffix(",bootindex=1") ?? false)
        XCTAssertEqual(device(a, "virtio-blk-pci,drive=disk0"), "virtio-blk-pci,drive=disk0,bootindex=2")
        XCTAssertEqual(zip(a, a.dropFirst()).first { $0.0 == "-boot" }?.1, "menu=on,splash-time=5000")

        config.name = "disc-only"
        config.id = UUID()
        config.boot = BootConfig(order: [.cd])
        a = try args(config)
        XCTAssertEqual(device(a, "virtio-blk-pci,drive=disk0"), "virtio-blk-pci,drive=disk0")
        XCTAssertEqual(device(a, "usb-storage,bus=usb.0,drive=media0"), "usb-storage,bus=usb.0,drive=media0,removable=on,bootindex=0")
    }

    func testSoundCardFollowsTheSettings() throws {
        var config = linux("sound")
        var a = try args(config)
        XCTAssertNotNil(device(a, "hda-output,audiodev=audio0"), "by default: sound out, and the Mac's microphone is never opened")
        XCTAssertNil(device(a, "hda-duplex"))

        config.id = UUID(); config.name = "mic"
        config.sound = SoundConfig(output: true, microphone: true)
        a = try args(config)
        XCTAssertNotNil(device(a, "hda-duplex,audiodev=audio0"))

        config.id = UUID(); config.name = "silent"
        config.sound = SoundConfig(output: false, microphone: false)
        a = try args(config)
        XCTAssertFalse(a.contains("-audiodev"))
        XCTAssertNil(device(a, "ich9-intel-hda"))
    }
}

final class DiskMaintenanceTests: XCTestCase {
    func testCompactGivesBackFreedSpaceAndKeepsTheContents() throws {
        guard let toolchain = try? QEMUToolchain.locate() else { throw XCTSkip("QEMU is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = VMConfig(name: "compact", guestOS: .linux, engine: .qemu)
        config.disks[0].sizeGiB = 1
        let bundle = try VMBundle.create(config: config, in: root)
        let disk = bundle.diskURL(bundle.config.disks[0])
        try? FileManager.default.removeItem(at: disk)
        try QEMUToolchain.run(toolchain.qemuImg, ["create", "-q", "-f", "qcow2", disk.path, "1G"])
        let qemuIO = toolchain.qemuImg.deletingLastPathComponent().appendingPathComponent("qemu-io")
        guard FileManager.default.isExecutableFile(atPath: qemuIO.path) else { throw XCTSkip("qemu-io is not installed") }
        // 64 MiB of data, then 48 MiB of it zeroed without giving the clusters back: what a guest's deleted files look like.
        try QEMUToolchain.run(qemuIO, ["-f", "qcow2", "-c", "write -P 0x5a 0 64M", "-c", "write -P 0 16M 48M", disk.path])
        let before = DiskMaintenance.allocatedBytes(of: disk)
        let reference = root.appendingPathComponent("reference.raw")
        try QEMUToolchain.run(toolchain.qemuImg, ["convert", "-f", "qcow2", "-O", "raw", disk.path, reference.path])

        let freed = try DiskMaintenance.compact(bundle: bundle, toolchain: toolchain)
        let after = DiskMaintenance.allocatedBytes(of: disk)
        XCTAssertGreaterThan(freed, 40 << 20)
        XCTAssertEqual(before - after, freed)
        XCTAssertNoThrow(try QEMUToolchain.run(toolchain.qemuImg, ["compare", "-f", "qcow2", "-F", "raw", disk.path, reference.path]),
                         "the guest must see the same disk as before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.deletingLastPathComponent().appendingPathComponent(".compact-" + disk.lastPathComponent).path))
        XCTAssertEqual(try DiskMaintenance.compact(bundle: bundle, toolchain: toolchain), 0, "a second run has nothing to free")
    }
}
