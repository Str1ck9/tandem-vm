import XCTest
import VMCore
@testable import Provisioning

final class AutounattendTests: XCTestCase {
    let options = WindowsUnattendOptions(computerName: "WIN-TEST", userName: "demo", password: "p<&>\"'w", timeZone: "Eastern Standard Time")

    func parse(_ xml: String) throws -> XMLDocument { try XMLDocument(xmlString: xml) }

    func values(_ doc: XMLDocument, _ name: String) throws -> [String] {
        try doc.nodes(forXPath: "//*[local-name()='\(name)']").compactMap(\.stringValue)
    }

    func testXMLIsWellFormedAndHasFourPasses() throws {
        let doc = try parse(try AutounattendBuilder.xml(options))
        XCTAssertEqual(doc.rootElement()?.name, "unattend")
        let passes = try doc.nodes(forXPath: "//*[local-name()='settings']/@pass").compactMap(\.stringValue)
        XCTAssertEqual(passes, ["windowsPE", "offlineServicing", "specialize", "oobeSystem"])
    }

    func testEveryComponentTargetsARM64() throws {
        let doc = try parse(try AutounattendBuilder.xml(options))
        let archs = try doc.nodes(forXPath: "//*[local-name()='component']/@processorArchitecture").compactMap(\.stringValue)
        XCTAssertEqual(archs.count, 8)
        XCTAssertTrue(archs.allSatisfy { $0 == "arm64" })
    }

    func testAnswersAppearAndSpecialCharactersSurvive() throws {
        let doc = try parse(try AutounattendBuilder.xml(options))
        XCTAssertEqual(try values(doc, "ComputerName"), ["WIN-TEST"])
        XCTAssertEqual(try values(doc, "TimeZone"), ["Eastern Standard Time"])
        XCTAssertEqual(try values(doc, "Name"), ["demo"])
        XCTAssertEqual(try values(doc, "Username"), ["demo"])
        XCTAssertEqual(try values(doc, "Value").filter { $0 == "p<&>\"'w" }.count, 2, "password must round-trip through XML escaping")
        XCTAssertEqual(try values(doc, "AcceptEula"), ["true"])
        XCTAssertTrue(try values(doc, "Value").contains("Windows 11 Pro"))
    }

    func testDiskLayoutIsEFIThenMSRThenWindows() throws {
        let doc = try parse(try AutounattendBuilder.xml(options))
        XCTAssertEqual(try values(doc, "Type"), ["EFI", "MSR", "Primary"])
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='InstallTo']/*[local-name()='PartitionID']").first?.stringValue, "3")
    }

    func testSecureBootBypassAndProductKeyAreOptional() throws {
        let with = try AutounattendBuilder.xml(options)
        XCTAssertTrue(with.contains("BypassSecureBootCheck"))
        XCTAssertFalse(with.contains("BypassTPMCheck"), "the VM has a real virtual TPM; that check must stay on")
        XCTAssertTrue(with.contains("<Key>VK7JG-"), "without a key of the user's, the edition's generic key selects it")
        var other = options; other.edition = "Windows 11 Enterprise"
        XCTAssertFalse(try AutounattendBuilder.xml(other).contains("<ProductKey>"), "no generic key is known for this edition")
        var o = options; o.bypassSecureBootCheck = false; o.productKey = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
        let without = try AutounattendBuilder.xml(o)
        XCTAssertFalse(without.contains("BypassSecureBootCheck"))
        XCTAssertEqual(try values(try parse(without), "Key").last, "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE")
    }

    func testDriverPathsAndFirstLogonCommand() throws {
        let doc = try parse(try AutounattendBuilder.xml(options))
        XCTAssertEqual(try values(doc, "Path").filter { $0.hasSuffix(":\\drivers") }.count, 12,
                       "six probed drive letters, for Setup itself and again for the installed Windows")
        let command = try XCTUnwrap(try values(doc, "CommandLine").first)
        XCTAssertTrue(command.contains("if exist %i:"), "the media is found by probing drive letters")
        XCTAssertTrue(command.contains("firstlogon.ps1"))
    }

    func testInvalidAnswersAreRejected() {
        XCTAssertThrowsError(try AutounattendBuilder.xml(WindowsUnattendOptions(computerName: "has space", userName: "a", password: "")))
        XCTAssertThrowsError(try AutounattendBuilder.xml(WindowsUnattendOptions(computerName: "THIS-NAME-IS-TOO-LONG", userName: "a", password: "")))
        XCTAssertThrowsError(try AutounattendBuilder.xml(WindowsUnattendOptions(userName: "Administrator", password: "")))
        XCTAssertThrowsError(try AutounattendBuilder.xml(WindowsUnattendOptions(userName: "a/b", password: "")))
        XCTAssertThrowsError(try AutounattendBuilder.xml(WindowsUnattendOptions(userName: "", password: "")))
    }
}

final class UnattendMediaTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-prov-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testStageLaysOutFiles() throws {
        let drivers = root.appendingPathComponent("src-drivers/netkvm")
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)
        try Data("inf".utf8).write(to: drivers.appendingPathComponent("netkvm.inf"))
        let agent = root.appendingPathComponent("agent.exe")
        try Data("MZ".utf8).write(to: agent)
        let staging = root.appendingPathComponent("staging")
        try UnattendMediaBuilder.stage(.init(options: WindowsUnattendOptions(userName: "u", password: "p"),
                                             driversDirectory: drivers.deletingLastPathComponent(), agentExecutable: agent), in: staging)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("autounattend.xml").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("drivers/netkvm/netkvm.inf").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("tandem-agent.exe").path))
        let script = try Data(contentsOf: staging.appendingPathComponent("firstlogon.ps1"))
        XCTAssertEqual(Array(script.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(String(decoding: script, as: UTF8.self).contains("\r\n"))
    }

    func testVirtioDriverSelection() throws {
        let iso = root.appendingPathComponent("iso")
        for path in ["NetKVM/w11/ARM64/netkvm.inf", "NetKVM/w11/amd64/netkvm.inf", "vioserial/w11/ARM64/vioser.inf",
                     "viogpudo/w10/ARM64/viogpudo.inf", "qxl/w11/ARM64/qxl.inf"] {
            let url = iso.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let out = root.appendingPathComponent("drivers")
        XCTAssertEqual(try VirtioDrivers.collect(fromMountedISO: iso, to: out), ["NetKVM", "vioserial"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("NetKVM/netkvm.inf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("qxl").path), "unwanted drivers are left out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("viogpudo").path), "only w11 builds are taken")

        try FileManager.default.removeItem(at: iso.appendingPathComponent("vioserial"))
        XCTAssertThrowsError(try VirtioDrivers.collect(fromMountedISO: iso, to: root.appendingPathComponent("drivers2")))
    }

    func testMissingDriverFolderIsAnError() {
        XCTAssertThrowsError(try UnattendMediaBuilder.stage(
            .init(options: WindowsUnattendOptions(userName: "u", password: "p"), driversDirectory: root.appendingPathComponent("nope")),
            in: root.appendingPathComponent("s")))
    }

    /// Builds a real ISO and mounts it to confirm the label and the root files.
    func testBuildProducesMountableISOWithLabel() throws {
        let bundle = try VMBundle.create(config: VMConfig(name: "win", guestOS: .windows11arm), in: root)
        let iso = try UnattendMediaBuilder.build(.init(options: WindowsUnattendOptions(userName: "u", password: "p")), for: bundle)
        XCTAssertEqual(iso.lastPathComponent, "unattend.iso")
        let mode = (try FileManager.default.attributesOfItem(atPath: iso.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "the disc holds the password: this user only")
        let mount = root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func hdiutil(_ args: [String]) throws -> Int32 {
            try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), args, timeout: 120, output: .discard, errors: .discard).status
        }
        XCTAssertEqual(try hdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, iso.path]), 0)
        defer { _ = try? hdiutil(["detach", mount.path, "-force"]) }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: mount.path).map { $0.lowercased() })
        XCTAssertTrue(names.contains("autounattend.xml"))
        XCTAssertTrue(names.contains("firstlogon.ps1"))
        let label = try mount.resourceValues(forKeys: [.volumeNameKey]).volumeName
        XCTAssertEqual(label, AutounattendBuilder.mediaLabel)
    }
}
