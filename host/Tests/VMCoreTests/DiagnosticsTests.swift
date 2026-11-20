import XCTest
@testable import VMCore

final class DiagnosticsTests: XCTestCase {
    func testSettingsLoseSecretsNotesAndMacPaths() throws {
        let json = #"""
        {"name":"Win","notes":"my bank stuff","install":{"user":"tester","password":"hunter2","productKey":"AAAAA"},
         "sharing":{"folders":[{"hostPath":"/Users/someone/Documents/Taxes","name":"Taxes"}]},
         "disks":[{"file":"disk0.qcow2","backing":{"path":"/Users/someone/Parallels/W.pvm/x.hds"}}]}
        """#
        let cleaned = String(decoding: try Diagnostics.cleanedJSON(Data(json.utf8)), as: UTF8.self)
        for secret in ["hunter2", "AAAAA", "my bank stuff", "/Users/someone"] {
            XCTAssertFalse(cleaned.contains(secret), "\(secret) must not appear: \(cleaned)")
        }
        XCTAssertTrue(cleaned.contains("…\\/Taxes") || cleaned.contains("…/Taxes"), cleaned)
        XCTAssertTrue(cleaned.contains("tester"), "the account name stays: it helps and is not a secret")
        XCTAssertTrue(cleaned.contains("disk0.qcow2"))
    }

    func testErrorsReadAsSentences() {
        XCTAssertEqual(VMError("It broke.", detail: "Do this.").userFacingText, "It broke.\nDo this.")
        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSFilePathErrorKey: "/x/disk0.qcow2"])
        XCTAssertEqual(full.userFacingText, "The Mac's disk is full (/x/disk0.qcow2). Free up space and try again.")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertTrue(wrapped.userFacingText.hasPrefix("macOS did not allow access"))
    }

    func testBundleHoldsLogsCleanedSettingsAndFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tdg-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try VMLibrary(rootDirectory: root)
        var config = VMConfig(name: "Diag VM", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        config.notes = "private note"
        let bundle = try library.create(config)
        try FileManager.default.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        try "qemu says hello\n".write(to: bundle.logsDirectory.appendingPathComponent("qemu.log"), atomically: true, encoding: .utf8)

        let zip = root.appendingPathComponent("d.zip")
        try Diagnostics.collect(library: library, extraInfo: ["QEMU": "11.1.3"], to: zip)
        let out = root.appendingPathComponent("out")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, out.path]
        try unzip.run()
        XCTAssertTrue(unzip.waitForExit(timeout: 30))

        let top = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first)
        let system = try String(contentsOf: top.appendingPathComponent("system.txt"), encoding: .utf8)
        XCTAssertTrue(system.contains("QEMU: 11.1.3"))
        XCTAssertTrue(system.contains("macOS"))
        let vmFolder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: top.appendingPathComponent("VMs"), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Diag VM") })
        XCTAssertEqual(try String(contentsOf: vmFolder.appendingPathComponent("qemu.log"), encoding: .utf8), "qemu says hello\n")
        let settings = try String(contentsOf: vmFolder.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(settings.contains("private note"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: top.appendingPathComponent("README.txt").path))
        // Never the disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: vmFolder.appendingPathComponent("disk0.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vmFolder.appendingPathComponent("disk0.qcow2").path))
    }

    func testLogsLoseTheUsersNameAndCommandText() {
        let log = """
        2026-11-16 qemu -drive file=/Users/somebody/Library/Application Support/Tandem/VMs/x/disk0.qcow2
        2026-11-16 command from the Mac (AI tool): net user admin S3cret! /add
        2026-11-16 command from the Mac (command line): echo hi
        2026-11-16 started
        """
        let cleaned = Diagnostics.scrubbedLog(log, home: "/Users/somebody")
        XCTAssertFalse(cleaned.contains("somebody"))
        XCTAssertTrue(cleaned.contains("file=~/Library/Application Support"))
        XCTAssertFalse(cleaned.contains("S3cret"))
        XCTAssertFalse(cleaned.contains("echo hi"))
        XCTAssertTrue(cleaned.contains("command from the Mac (AI tool): [command not included]"))
        XCTAssertTrue(cleaned.hasSuffix("2026-11-16 started"))
    }
}
