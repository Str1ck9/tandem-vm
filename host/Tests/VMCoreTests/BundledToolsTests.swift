import XCTest
@testable import VMCore

/// Where a packaged Tandem.app keeps its tools, and the fallbacks for an unpackaged build.
final class BundledToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeExecutable(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testHelpersFolderIsFoundFromAnyProgramInsideTheApp() throws {
        let app = root.appendingPathComponent("Tandem.app")
        let main = try makeExecutable("Tandem.app/Contents/MacOS/Tandem")
        let cli = try makeExecutable("Tandem.app/Contents/Helpers/tandem")
        let expected = app.appendingPathComponent("Contents/Helpers").standardizedFileURL.resolvingSymlinksInPath()
        for exe in [main, cli] {
            let found = BundledTools.helpersDirectory(environment: [:], executable: exe)
            XCTAssertEqual(found?.standardizedFileURL.resolvingSymlinksInPath(), expected)
        }
        // A program outside any app (vmctl in a build folder) has none.
        let loose = try makeExecutable("build/debug/vmctl")
        XCTAssertNil(BundledTools.helpersDirectory(environment: [:], executable: loose))
    }

    func testOverrideVariableWins() {
        let custom = root.appendingPathComponent("elsewhere")
        XCTAssertEqual(BundledTools.helpersDirectory(environment: [BundledTools.directoryVariable: custom.path], executable: nil)?.path, custom.path)
    }

    func testToolsAndQEMUComeFromTheAppWhenPresent() throws {
        let main = try makeExecutable("Tandem.app/Contents/MacOS/Tandem")
        XCTAssertNil(BundledTools.tool("zstd", environment: [:], executable: main), "an unpackaged app carries no tools")
        XCTAssertNil(BundledTools.qemuPrefix(environment: [:], executable: main))
        let zstd = try makeExecutable("Tandem.app/Contents/Helpers/tools/zstd")
        let nbd = try makeExecutable("Tandem.app/Contents/Helpers/qemu/bin/qemu-nbd")
        let qemu = try makeExecutable("Tandem.app/Contents/Helpers/qemu/bin/qemu-system-aarch64")
        XCTAssertEqual(BundledTools.tool("zstd", environment: [:], executable: main)?.resolvingSymlinksInPath(), zstd.resolvingSymlinksInPath())
        XCTAssertEqual(BundledTools.tool("qemu-nbd", environment: [:], executable: main)?.resolvingSymlinksInPath(), nbd.resolvingSymlinksInPath())
        XCTAssertEqual(BundledTools.qemuPrefix(environment: [:], executable: main)?.appendingPathComponent("bin/qemu-system-aarch64").resolvingSymlinksInPath(),
                       qemu.resolvingSymlinksInPath())
    }

    func testFallbackIsUsedWhenTheAppHasNoCopy() throws {
        let main = try makeExecutable("Tandem.app/Contents/MacOS/Tandem")
        let brew = try makeExecutable("brew/bin/zstd")
        XCTAssertEqual(BundledTools.locate("zstd", fallbacks: ["/nonexistent/zstd", brew.path], environment: [:], executable: main)?.path, brew.path)
        XCTAssertNil(BundledTools.locate("zstd", fallbacks: ["/nonexistent/zstd"], environment: [:], executable: main))
    }

    func testQEMUDataFolderOnlyForTheAppsOwnQEMU() throws {
        let qemu = try makeExecutable("Tandem.app/Contents/Helpers/qemu/bin/qemu-system-aarch64")
        XCTAssertNil(BundledTools.qemuDataDirectory(forQEMU: qemu), "no firmware in Resources/qemu yet")
        let firmware = root.appendingPathComponent("Tandem.app/Contents/Resources/qemu/edk2-aarch64-code.fd")
        try FileManager.default.createDirectory(at: firmware.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: firmware)
        XCTAssertEqual(BundledTools.qemuDataDirectory(forQEMU: qemu)?.resolvingSymlinksInPath(),
                       firmware.deletingLastPathComponent().resolvingSymlinksInPath())
        // A QEMU installed anywhere else keeps finding its data next to bin/.
        let elsewhere = try makeExecutable("prefix/bin/qemu-system-aarch64")
        XCTAssertNil(BundledTools.qemuDataDirectory(forQEMU: elsewhere))
    }

    func testThe3DQEMUInsideTheAppSharesTheFirmware() throws {
        let main = try makeExecutable("Tandem.app/Contents/MacOS/Tandem")
        XCTAssertNil(BundledTools.qemu3DPrefix(environment: [:], executable: main), "an app without the 3D build")
        let qemu3D = try makeExecutable("Tandem.app/Contents/Helpers/qemu-3d/bin/qemu-system-aarch64")
        XCTAssertEqual(BundledTools.qemu3DPrefix(environment: [:], executable: main)?.appendingPathComponent("bin/qemu-system-aarch64").resolvingSymlinksInPath(),
                       qemu3D.resolvingSymlinksInPath())
        XCTAssertNil(BundledTools.qemuPrefix(environment: [:], executable: main), "the 3D build is not the normal QEMU")
        let firmware = root.appendingPathComponent("Tandem.app/Contents/Resources/qemu/edk2-aarch64-code.fd")
        try FileManager.default.createDirectory(at: firmware.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: firmware)
        XCTAssertEqual(BundledTools.qemuDataDirectory(forQEMU: qemu3D)?.resolvingSymlinksInPath(),
                       firmware.deletingLastPathComponent().resolvingSymlinksInPath())
    }
}
