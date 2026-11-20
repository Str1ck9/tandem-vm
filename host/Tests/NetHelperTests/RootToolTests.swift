import IdentityCore
import XCTest
@testable import TandemNetHelper

/// The checks that decide whether the helper runs a tool as root (security review 2026-11-16).
final class RootToolTests: XCTestCase {
    private var directory = ""
    /// A packaged, Developer ID–signed Tandem.app whose tools carry this run's identifiers (set
    /// `TANDEM_BUNDLE_PREFIX` and `TANDEM_APP_ID` to the app's), used read-only (copied, never changed), for
    /// real signatures: `TANDEM_TEST_APP`, this checkout's build/package, or /Applications.
    private static let signedApp: String = {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/package/Tandem.app").path
        let candidates = [ProcessInfo.processInfo.environment["TANDEM_TEST_APP"], checkout, "/Applications/Tandem.app"].compactMap { $0 }
        return candidates.first { app in
            (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) == TandemIdentity.app
        } ?? "/nonexistent/Tandem.app"
    }()
    private var installedTools: String { Self.signedApp + "/Contents/Helpers/tools" }
    private var installedCLI: String { Self.signedApp + "/Contents/Helpers/tandem" }
    /// The signing team of the app under test: `TANDEM_TEST_TEAM` (tests that need a real signed app skip without it).
    private var team: String { ProcessInfo.processInfo.environment["TANDEM_TEST_TEAM"] ?? "" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tandem-roottool-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: directory) }

    func testRequirementPinsTheToolsIdentifierAndTeam() {
        TandemIdentity.overrideForTesting(.standard)
        defer { TandemIdentity.overrideForTesting(nil) }
        XCTAssertEqual(expectedIdentifier(forTool: "/x/Tandem.app/Contents/Helpers/qemu/bin/qemu-nbd"), "local.tandem.qemu-nbd")
        let text = toolRequirement(identifier: "local.tandem.qemu-nbd", team: "ABCDE12345")
        XCTAssertEqual(text, "identifier \"local.tandem.qemu-nbd\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertNil(toolRequirement(identifier: "local.tandem.qemu-nbd", team: "abc\" or true"), "a malformed team is refused")
        XCTAssertNil(toolRequirement(identifier: "x\" or anchor apple", team: "ABCDE12345"), "a malformed identifier is refused")
    }

    func testRootNeedsTheHardenedRuntimeAndNoLoopholes() {
        XCTAssertNotNil(rootToolRefusal(flags: 0, entitlements: [:]), "no hardened runtime: other libraries could be loaded")
        XCTAssertNil(rootToolRefusal(flags: codeSignatureRuntimeFlag, entitlements: [:]))
        XCTAssertNil(rootToolRefusal(flags: codeSignatureRuntimeFlag, entitlements: ["com.apple.security.hypervisor": true]))
        for key in unsafeRootEntitlements {
            XCTAssertNotNil(rootToolRefusal(flags: codeSignatureRuntimeFlag, entitlements: [key: true]), key)
        }
    }

    /// A copy of an installed tool in a folder of its own, its libraries reached through a link.
    private func copyTool(_ source: String, as name: String) throws -> String {
        let folder = directory + "/" + UUID().uuidString.prefix(6)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = folder + "/" + name
        try FileManager.default.copyItem(atPath: source, toPath: target)
        try FileManager.default.createSymbolicLink(atPath: folder + "/lib", withDestinationPath: installedTools + "/lib")
        return target
    }

    func testTheRightToolOfTheTeamRuns() throws {
        guard FileManager.default.isExecutableFile(atPath: installedTools + "/zstd"), !team.isEmpty else { throw XCTSkip("no installed Tandem.app (and TANDEM_TEST_TEAM) to take a signed tool from") }
        let tool = try copyTool(installedTools + "/zstd", as: "zstd")
        XCTAssertTrue(signedByTeam(tool, team: team))
        let process = try ToolProcess(path: tool, arguments: ["--version"], team: team)
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(process.exitCode, 0, "the verified tool ran: \(process.errorText())")
    }

    func testAnotherProgramOfTheSameTeamIsRefused() throws {
        guard FileManager.default.isExecutableFile(atPath: installedCLI), !team.isEmpty else { throw XCTSkip("no installed Tandem.app (and TANDEM_TEST_TEAM) to take a signed program from") }
        // Tandem's command-line tool put where qemu-nbd should be: right team, wrong program.
        let impostor = try copyTool(installedCLI, as: "qemu-nbd")
        XCTAssertFalse(signedByTeam(impostor, team: team), "the file check pins the identifier")
        XCTAssertThrowsError(try ToolProcess(path: impostor, arguments: ["--help"], team: team)) { error in
            XCTAssertTrue("\(error)".contains("refused to run qemu-nbd as root"), "\(error)")
        }
    }

    func testAProgramOfAnotherSignerIsRefusedBeforeItRuns() throws {
        // /usr/bin/touch would create the file if it ran for a single instruction past the check.
        let impostor = try copyTool("/usr/bin/touch", as: "usbredirect")
        let marker = directory + "/ran"
        XCTAssertThrowsError(try ToolProcess(path: impostor, arguments: [marker], team: team))
        usleep(200_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the refused program never ran")
    }

    func testWithoutATeamTheToolRunsUnchecked() throws {
        // Unprivileged runs (tests, fake mode) and the script-installed helper (root-owned tools) do not check.
        let process = try ToolProcess(path: "/bin/sh", arguments: ["-c", "echo complaint >&2; exit 3"], team: nil)
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(process.exitCode, 3)
        XCTAssertEqual(process.errorText(), "complaint")
    }

    func testAChattyToolNeverBlocksOnItsErrorOutput() throws {
        // 1 MB on stderr: far more than a pipe holds. It must still finish.
        let process = try ToolProcess(path: "/bin/sh", arguments: ["-c", "head -c 1048576 /dev/zero | tr '\\0' x >&2; exit 0"], team: nil)
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(process.exitCode, 0)
    }
}
