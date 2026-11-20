import XCTest
@testable import VMCore

final class GuestToolsMacOSTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-macos-tools-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func fakeAgent() throws -> URL {
        let agent = dir.appendingPathComponent("agent-source")
        try Data("binary".utf8).write(to: agent)
        return agent
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func parses(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let check = try ToolRun.run(URL(fileURLWithPath: "/bin/sh"), ["-n", url.path], timeout: 30)
        XCTAssertEqual(check.status, 0, "\(url.lastPathComponent) must parse", file: file, line: line)
    }

    func testPackagePayloadAndScripts() throws {
        let root = dir.appendingPathComponent("root"), scripts = dir.appendingPathComponent("scripts")
        try GuestTools.stageMacOSPackage(agent: try fakeAgent(), root: root, scripts: scripts)
        let agent = root.appendingPathComponent("Library/Application Support/Tandem Agent/tandem-agent")
        XCTAssertEqual(try Data(contentsOf: agent), Data("binary".utf8))
        XCTAssertEqual(try mode(agent), 0o755)
        // The LaunchDaemon starts the installed agent, as root, again whenever it ends.
        let plistURL = root.appendingPathComponent("Library/LaunchDaemons/\(TandemIdentity.guestAgent).plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, GuestTools.macOSDaemonLabel)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [GuestTools.macOSAgentInstallPath])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertNil(plist["UserName"], "the agent runs as root, so it can set the clock and shut down")
        let post = scripts.appendingPathComponent("postinstall")
        XCTAssertEqual(try mode(post), 0o755)
        try parses(post)
        let text = try String(contentsOf: post, encoding: .utf8)
        XCTAssertTrue(text.contains("launchctl bootstrap system \"$plist\""))
    }

    func testDiscLayout() throws {
        let package = dir.appendingPathComponent("p.pkg")
        try Data("pkg".utf8).write(to: package)
        let disc = dir.appendingPathComponent("disc")
        try GuestTools.stageMacOSDisc(agent: try fakeAgent(), package: package, in: disc)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: disc.path))
        XCTAssertEqual(names, [GuestTools.macOSPackageName, "install.sh", "uninstall.sh", "postinstall", "\(TandemIdentity.guestAgent).plist", "README.txt", "tandem-agent"])
        for script in ["install.sh", "uninstall.sh", "postinstall"] {
            try parses(disc.appendingPathComponent(script))
            XCTAssertEqual(try mode(disc.appendingPathComponent(script)), 0o755)
        }
        // Without a package (pkgbuild failed) the Terminal route is still there.
        let bare = dir.appendingPathComponent("bare")
        try GuestTools.stageMacOSDisc(agent: try fakeAgent(), package: nil, in: bare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent(GuestTools.macOSPackageName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bare.appendingPathComponent("install.sh").path))
    }

    /// Builds the real disc with pkgbuild and hdiutil, then reads it back.
    func testDiscBuildsWithInstallerPackage() throws {
        let output = dir.appendingPathComponent("tools.iso")
        let built = try XCTUnwrap(try GuestTools.macOSDisc(agent: try fakeAgent(), output: output))
        XCTAssertEqual(built, output)
        let mount = dir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, output.path], timeout: 120)
        XCTAssertEqual(attach.status, 0)
        defer { _ = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-force", mount.path], timeout: 60) }
        let package = mount.appendingPathComponent(GuestTools.macOSPackageName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path), "the HFS side keeps the package's full name")
        let files = try ToolRun.run(URL(fileURLWithPath: "/usr/sbin/pkgutil"), ["--payload-files", package.path], timeout: 60)
        XCTAssertTrue(String(decoding: files.output, as: UTF8.self).contains("./Library/Application Support/Tandem Agent/tandem-agent"), String(decoding: files.output, as: UTF8.self))
        XCTAssertTrue(String(decoding: files.output, as: UTF8.self).contains("./Library/LaunchDaemons/\(TandemIdentity.guestAgent).plist"), String(decoding: files.output, as: UTF8.self))
        XCTAssertEqual(try mode(mount.appendingPathComponent("install.sh")) & 0o111, 0o111, "scripts stay executable")
        // Up to date: not built again.
        let stamp = try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try GuestTools.macOSDisc(agent: dir.appendingPathComponent("agent-source"), output: output)
        XCTAssertEqual(try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
        XCTAssertNil(try GuestTools.macOSDisc(agent: nil, output: output))
    }

    func testDiscRequestIsSettledAtColdStartsOnly() {
        let asked = Date(timeIntervalSince1970: 1_000)
        // Asked for, never answered: attached at every cold start.
        var info = GuestToolsInfo(toolsDiscRequested: asked)
        XCTAssertTrue(GuestTools.settleMacOSDiscRequest(&info, resuming: false))
        XCTAssertEqual(info.toolsDiscAttached, true)
        XCTAssertFalse(GuestTools.settleMacOSDiscRequest(&info, resuming: false))
        // The tools answered (while running): a resume still gets the disc it was saved with.
        info.lastSeen = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(GuestTools.settleMacOSDiscRequest(&info, resuming: true))
        XCTAssertEqual(info.toolsDiscAttached, true)
        XCTAssertNotNil(info.toolsDiscRequested)
        // The next cold start lets it go.
        XCTAssertTrue(GuestTools.settleMacOSDiscRequest(&info, resuming: false))
        XCTAssertNil(info.toolsDiscRequested)
        XCTAssertNil(info.toolsDiscAttached)
        // Asked for again (reinstall) after the tools were seen: attached again.
        info.toolsDiscRequested = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(GuestTools.settleMacOSDiscRequest(&info, resuming: false))
        XCTAssertEqual(info.toolsDiscAttached, true)
    }

    func testAttachedOnlyForMacOSGuests() {
        var mac = VMConfig(name: "m", guestOS: .macos)
        XCTAssertFalse(GuestTools.attachesMacOSDisc(mac))
        mac.guestTools.toolsDiscAttached = true
        XCTAssertTrue(GuestTools.attachesMacOSDisc(mac))
        var linux = VMConfig(name: "l", guestOS: .linux)
        linux.guestTools.toolsDiscAttached = true
        XCTAssertFalse(GuestTools.attachesMacOSDisc(linux))
    }

    /// Configurations written before the request existed still load, and the fields round-trip.
    func testGuestToolsRecordDecodesOldAndNew() throws {
        let old = try JSONDecoder().decode(GuestToolsInfo.self, from: Data(#"{"installedVersion":"0.1.0"}"#.utf8))
        XCTAssertNil(old.toolsDiscRequested)
        XCTAssertNil(old.toolsDiscAttached)
        let new = GuestToolsInfo(installedVersion: "1", lastSeen: nil, toolsDiscRequested: Date(timeIntervalSince1970: 5), toolsDiscAttached: true)
        XCTAssertEqual(try JSONDecoder().decode(GuestToolsInfo.self, from: JSONEncoder().encode(new)), new)
    }
}
