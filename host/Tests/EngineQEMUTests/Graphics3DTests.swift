import XCTest
import VMCore
@testable import EngineQEMU

/// Experimental 3D acceleration for Linux guests: which VMs get it and what QEMU is told.
final class Graphics3DTests: XCTestCase {
    var root: URL!
    let toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/x/bin/qemu-system-aarch64"), qemuImg: URL(fileURLWithPath: "/x/bin/qemu-img"),
                                  swtpm: nil, firmwareCode: URL(fileURLWithPath: "/x/share/code.fd"),
                                  firmwareVarsTemplate: URL(fileURLWithPath: "/x/share/vars.fd"), qemuVersion: "QEMU emulator version 10.0.12")
    let paths = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tandem-3d"))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-3d-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func args(_ config: VMConfig) throws -> [String] {
        let bundle = try VMBundle.create(config: config, in: root)
        return try QEMUCommandBuilder.arguments(bundle: bundle, toolchain: toolchain, paths: paths, display: .embedded)
    }

    func testLinuxWith3DRendersHeadlessAndShowsThroughTandemsDisplaySocket() throws {
        var config = VMConfig(name: "lin", guestOS: .linux, engine: .qemu)
        config.display.accelerated3D = true
        let a = try args(config)
        XCTAssertTrue(a.contains { $0.hasPrefix("virtio-gpu-gl-pci,xres=1440,yres=900") })
        XCTAssertFalse(a.contains { $0.hasPrefix("virtio-gpu-pci") })
        XCTAssertTrue(a.contains("egl-headless,gl=core"), "GL on Apple's OpenGL, read back for VNC")
        XCTAssertFalse(a.contains { $0.hasPrefix("cocoa") }, "no window of QEMU's own")
        let vnc = try XCTUnwrap(a.firstIndex(of: "-vnc"))
        XCTAssertTrue(a[vnc + 1].hasPrefix("unix:"), "the same display socket Tandem's window reads for 2D VMs")
    }

    func testANGLEIsTheGLESVariant() {
        XCTAssertEqual(QEMUCommandBuilder.display3D(es: true), "egl-headless,gl=es")
        XCTAssertEqual(QEMUCommandBuilder.display3D(es: false), "egl-headless,gl=core")
    }

    func testWithout3DNothingChanges() throws {
        let a = try args(VMConfig(name: "lin", guestOS: .linux, engine: .qemu))
        XCTAssertTrue(a.contains { $0.hasPrefix("virtio-gpu-pci,") })
        XCTAssertFalse(a.contains("-spice"))
    }

    func testWindowsWith3DGetsTheNeptuneDeviceAndSmallPages() throws {
        var config = VMConfig(name: "win", guestOS: .windows11arm, memoryMiB: 8192)
        config.display.accelerated3D = true
        config.display.virtioGPU = true
        XCTAssertTrue(QEMUCommandBuilder.uses3D(config))
        XCTAssertTrue(QEMUCommandBuilder.usesWindows3D(config))
        let a = try args(config)
        XCTAssertTrue(a.contains("virtio-ramfb-gl,xres=1440,yres=900,neptune=on,blob=on,hostmem=4096M"))
        XCTAssertFalse(a.contains { $0.hasPrefix("virtio-gpu-pci") || $0 == "ramfb" }, "the 3D device brings its own ramfb")
        XCTAssertTrue(a.contains("hvf,ipa-granule-size=0x1000"))
        XCTAssertTrue(a.contains("virt,highmem=on"), "the accelerator is given with -accel, not on the machine")
        XCTAssertTrue(a.contains("egl-headless,gl=core"), "same in-window display as Linux 3D")
        XCTAssertTrue(a.contains("-vnc"))
    }

    func testWindowsHostMemoryWindowIsHalfTheGuestWithinLimits() {
        XCTAssertEqual(QEMUCommandBuilder.windows3DHostMemoryMiB(VMConfig(name: "a", guestOS: .windows11arm, memoryMiB: 32768)), 8192)
        XCTAssertEqual(QEMUCommandBuilder.windows3DHostMemoryMiB(VMConfig(name: "b", guestOS: .windows11arm, memoryMiB: 1024)), 1024)
    }

    func testWindowsWithout3DKeepsItsPlainDisplay() throws {
        var config = VMConfig(name: "win", guestOS: .windows11arm)
        config.display.virtioGPU = true
        XCTAssertFalse(QEMUCommandBuilder.uses3D(config))
        let a = try args(config)
        XCTAssertTrue(a.contains { $0.hasPrefix("virtio-gpu-pci,") })
        XCTAssertTrue(a.contains("virt,accel=hvf,highmem=on"))
    }

    func testWindows3DPrefersTheMain3DBuild() {
        let names = QEMUToolchain.prefixes3D(environment: [:], windows: true).map(\.lastPathComponent)
        XCTAssertEqual(names, ["qemu-3d", "qemu-3d.staged", "qemu-3d-win", "qemu-3d-win.staged"])
        XCTAssertEqual(QEMUToolchain.prefixes3D(environment: [:]).map(\.lastPathComponent), ["qemu-3d", "qemu-3d.staged"])
        XCTAssertEqual(QEMUToolchain.dxmtLibrary(in: URL(fileURLWithPath: "/p")).path, "/p/Frameworks/dxmt-native.framework/dxmt-native")
        XCTAssertEqual(QEMUToolchain.prefix(of: URL(fileURLWithPath: "/p/bin/qemu-system-aarch64")).path, "/p")
    }

    func testOldConfigsLoadWithout3D() throws {
        let json = #"{"width":1280,"height":800,"dynamicResize":true}"#
        let display = try JSONDecoder().decode(DisplayConfig.self, from: Data(json.utf8))
        XCTAssertNil(display.accelerated3D)
        var on = display; on.accelerated3D = true
        let back = try JSONDecoder().decode(DisplayConfig.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(back.accelerated3D, true)
    }

    func testThe3DBuildIsLookedForInItsOwnPlacesOnly() {
        let prefixes = QEMUToolchain.prefixes3D(environment: ["TANDEM_QEMU_3D_PREFIX": "/custom/q3d"]).map(\.lastPathComponent)
        XCTAssertEqual(prefixes, ["q3d", "qemu-3d", "qemu-3d.staged"])
    }

    func testThePackagedAppsOwn3DBuildComesBeforeTheStagedOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("q3d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("Tandem.app/Contents/MacOS/Tandem")
        let qemu = root.appendingPathComponent("Tandem.app/Contents/Helpers/qemu-3d/bin/qemu-system-aarch64")
        for file in [main, qemu] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let prefixes = QEMUToolchain.prefixes3D(environment: ["TANDEM_QEMU_3D_PREFIX": "/custom/q3d"], windows: true, executable: main)
        XCTAssertEqual(prefixes.map(\.lastPathComponent), ["q3d", "qemu-3d", "qemu-3d", "qemu-3d.staged", "qemu-3d-win", "qemu-3d-win.staged"])
        XCTAssertEqual(prefixes[1].resolvingSymlinksInPath(), qemu.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath(),
                       "the copy inside the app, right after the override")
    }
}
