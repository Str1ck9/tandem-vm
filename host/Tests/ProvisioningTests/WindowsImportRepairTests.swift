import XCTest
@testable import Provisioning

final class WindowsImportRepairTests: XCTestCase {
    func testAnswerFileRunsTheScriptInWindowsPE() throws {
        let doc = try XMLDocument(xmlString: WindowsImportRepair.answerFile)
        let settings = try doc.nodes(forXPath: "//*[local-name()='settings']/@pass").compactMap(\.stringValue)
        XCTAssertEqual(settings, ["windowsPE"])
        let arch = try doc.nodes(forXPath: "//*[local-name()='component']/@processorArchitecture").compactMap(\.stringValue)
        XCTAssertEqual(arch, ["arm64"])
        let path = try XCTUnwrap(try doc.nodes(forXPath: "//*[local-name()='Path']").first?.stringValue)
        XCTAssertTrue(path.contains("call %i:\\tandem-repair.cmd"), path)
    }

    func testScriptCoversTheThreeFixes() {
        let script = WindowsImportRepair.script
        XCTAssertTrue(script.contains("Services\\stornvme /v Start /t REG_DWORD /d 0"))
        XCTAssertTrue(script.contains("Services\\stornvme\\StartOverride /f"))
        XCTAssertTrue(script.contains("{4d36e967-e325-11ce-bfc1-08002be10318}"), "disk class filters")
        for driver in WindowsImportRepair.parallelsDrivers { XCTAssertTrue(script.contains(driver)) }
        XCTAssertTrue(script.contains("/t REG_DWORD /d 4"))
        XCTAssertTrue(script.contains("dism /image:%WIN%\\ /add-driver"))
    }

    func testScriptOnlyPowersOffOnSuccess() throws {
        let script = WindowsImportRepair.script
        let shutdown = try XCTUnwrap(script.range(of: "wpeutil shutdown"))
        let failure = try XCTUnwrap(script.range(of: "if defined FAILED"))
        XCTAssertTrue(failure.lowerBound < shutdown.lowerBound, "the failure check comes before the power-off")
        XCTAssertEqual(script.components(separatedBy: "wpeutil").count, 2, "exactly one power-off")
        XCTAssertFalse(script.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF line endings throughout")
    }

    func testStageWritesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let drivers = dir.appendingPathComponent("src/NetKVM")
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: drivers.appendingPathComponent("netkvm.inf"))
        let out = dir.appendingPathComponent("out")
        try WindowsImportRepair.stage(in: out, driversDirectory: dir.appendingPathComponent("src"))
        for file in ["autounattend.xml", "tandem-repair.cmd", "drivers/NetKVM/netkvm.inf"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(file).path), file)
        }
    }

    func testAgentIsInstalledAsAnElevatedLogonTask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agent = dir.appendingPathComponent("agent.exe")
        try Data("MZ".utf8).write(to: agent)
        let out = dir.appendingPathComponent("out")
        try WindowsImportRepair.stage(in: out, agentExecutable: agent)
        for file in ["tandem-agent.exe", "tandem-setup.cmd", "tandem-agent-task.xml"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(file).path), file)
        }
        // Task Scheduler needs UTF-16 with a byte-order mark.
        let xmlData = try Data(contentsOf: out.appendingPathComponent("tandem-agent-task.xml"))
        XCTAssertEqual(Array(xmlData.prefix(2)), [0xFF, 0xFE])
        let task = try XMLDocument(xmlString: WindowsImportRepair.taskDefinition.replacingOccurrences(of: "encoding=\"UTF-16\"", with: "encoding=\"UTF-8\""))
        func value(_ name: String) throws -> String? { try task.nodes(forXPath: "//*[local-name()='\(name)']").first?.stringValue }
        XCTAssertEqual(try value("RunLevel"), "HighestAvailable", "the virtio-serial port needs an elevated process")
        XCTAssertEqual(try value("GroupId"), "S-1-5-32-545", "runs in the session of whoever signs in")
        XCTAssertEqual(try value("ExecutionTimeLimit"), "PT0S", "no three-day limit")
        XCTAssertNotNil(try task.nodes(forXPath: "//*[local-name()='LogonTrigger']").first)
        // The repair registers a one-shot SYSTEM service, and that service's script registers the task and removes itself.
        XCTAssertTrue(WindowsImportRepair.script.contains("Services\\TandemSetup /v ImagePath"))
        XCTAssertTrue(WindowsImportRepair.setupScript.contains("schtasks /create /tn \"Tandem Guest Agent\" /xml"))
        XCTAssertTrue(WindowsImportRepair.setupScript.contains("sc delete TandemSetup"))
    }
}
